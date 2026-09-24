// @ts-check
/**
 * Remote license-backend adapter seam.
 *
 * This is the ONLY place that talks to an existing, external licensing backend.
 * There is no such backend in the GPSLab repository and none is provisioned by
 * this deliverable, so this adapter is a documented seam, NOT a proven
 * integration. `LICENSE_MODE=remote` requires `LICENSE_BACKEND_URL`.
 *
 * The adapter speaks the same request/response contract GPSLab uses:
 *   issue  -> { installationId, refreshToken?, activationCode? }
 *   revoke -> { action: 'revoke', licenseId, reason?, actorId? }
 *   verify -> local ES256 verification of a returned envelope against a pinned key
 *
 * Boundaries (fail closed):
 *   * Every operation throws `RemoteBackendError` when `LICENSE_BACKEND_URL` is
 *     not configured; it never silently degrades to "allow".
 *   * The response is read with a byte cap, must be JSON, and (for issuance) must
 *     match the GPSLab envelope shape.
 *   * When a remote verification key is pinned (base64 SPKI, e.g. the host app's
 *     embedded `GPSLabLicensePublicKey`), the returned envelope's ES256 signature
 *     is verified BEFORE it is returned. A bad signature is a hard failure.
 *   * Without a pinned key the signature cannot be checked; the adapter returns
 *     the shape-validated envelope and this limitation is documented. Production
 *     is refused entirely in remote mode (see config.js productionReadinessProblems).
 *
 * If a real backend is ever provisioned, its response contract, error codes,
 * auth and signature semantics must be re-verified against
 * `Source/GPSLabTokenVerifier.m`.
 */
import crypto from 'node:crypto';
import { verifyEnvelope } from './signing.js';

export class RemoteBackendError extends Error {
  /**
   * @param {string} message
   * @param {number} [status]
   * @param {string} [code]
   */
  constructor(message, status = 502, code = 'remote_backend_error') {
    super(message);
    this.name = 'RemoteBackendError';
    this.status = status;
    this.code = code;
  }
}

const MAX_RESPONSE_BYTES = 256 * 1024;

/** Normalize base64/base64url to padded standard base64. */
function normalizeBase64(value) {
  let normalized = String(value).replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '');
  while (normalized.length % 4 !== 0) normalized += '=';
  return normalized;
}

export class RemoteLicenseIssuer {
  /**
   * @param {{config: {licenseBackendUrl: string, licenseIssuer: string, licenseAudience: string}, fetchImpl?: typeof fetch}} deps
   */
  constructor({ config, fetchImpl }) {
    this.config = config;
    /** Injectable for tests; defaults to global fetch. */
    this.fetchImpl = fetchImpl ?? fetch;
    /** @type {string | null} */
    this._publicKeyBase64 = null;
    /** @type {crypto.KeyObject | null} */
    this._publicKey = null;
  }

  publicKeyBase64() {
    return this._publicKeyBase64;
  }

  isEphemeral() {
    return false;
  }

  /** True only when a backend URL is configured; a required, fail-closed gate. */
  isConfigured() {
    return Boolean(this.config && String(this.config.licenseBackendUrl || '').trim());
  }

  /**
   * Record the public key the host app must trust (out of band). Passing an empty
   * value clears the pin. An unparseable key throws so a bad pin fails closed.
   * Accepts base64 or base64url SPKI.
   * @param {string | null | undefined} value
   */
  setPublicKeyBase64(value) {
    const trimmed = String(value || '').trim();
    if (!trimmed) {
      this._publicKeyBase64 = null;
      this._publicKey = null;
      return;
    }
    let key;
    try {
      key = crypto.createPublicKey({
        key: Buffer.from(normalizeBase64(trimmed), 'base64'),
        format: 'der',
        type: 'spki',
      });
    } catch {
      throw new RemoteBackendError('the pinned remote verification key is not a valid SPKI public key', 500, 'invalid_pin_key');
    }
    this._publicKey = key;
    this._publicKeyBase64 = trimmed;
  }

  /**
   * @param {{installationId: string, refreshToken?: string, activationCode?: string}} request
   * @returns {Promise<Record<string, unknown>>}
   */
  forward(request) {
    return this.issue(request);
  }

  /**
   * Activation issuance / refresh / lookup. Preserves the exact GPSLab request
   * contract (no extra fields) so a real backend can be dropped in later.
   * @param {{installationId: string, refreshToken?: string, activationCode?: string}} request
   * @returns {Promise<Record<string, unknown>>}
   */
  issue(request) {
    /** @type {Record<string, unknown>} */
    const body = { installationId: request.installationId };
    if (request.refreshToken) body.refreshToken = request.refreshToken;
    if (request.activationCode) body.activationCode = request.activationCode;
    return this._post(body, { requireEnvelope: true });
  }

  /**
   * Revoke a license at the remote backend. The action is explicit so a backend
   * can route it without a separate URL.
   * @param {{licenseId: string, reason?: string, actorId?: string | null}} request
   * @returns {Promise<Record<string, unknown>>}
   */
  revoke(request) {
    /** @type {Record<string, unknown>} */
    const body = { action: 'revoke', licenseId: request.licenseId };
    if (request.reason) body.reason = request.reason;
    if (request.actorId) body.actorId = request.actorId;
    return this._post(body, { requireEnvelope: false });
  }

  /**
   * Verify an envelope with the pinned key. Returns the claims, or null when no
   * pinned key is configured or the signature does not verify (fail closed).
   * @param {Record<string, unknown>} envelope
   */
  verify(envelope) {
    if (!this._publicKey) return null;
    return verifyEnvelope(envelope, this._publicKey);
  }

  /**
   * @param {Record<string, unknown>} body
   * @param {{requireEnvelope: boolean}} options
   * @returns {Promise<Record<string, unknown>>}
   */
  async _post(body, { requireEnvelope }) {
    if (!this.isConfigured()) {
      throw new RemoteBackendError(
        'LICENSE_BACKEND_URL is not configured; remote license operations are disabled (fail closed)',
        503,
        'not_configured'
      );
    }

    let response;
    try {
      response = await this.fetchImpl(this.config.licenseBackendUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify(body),
        redirect: 'error',
      });
    } catch (error) {
      // Never echo the underlying message (it may contain the backend URL/host).
      throw new RemoteBackendError(`license backend unreachable: ${/** @type {Error} */ (error).name}`, 502, 'unreachable');
    }
    if (!response.ok) {
      throw new RemoteBackendError(`license backend returned HTTP ${response.status}`, 502, 'bad_status');
    }
    const text = await response.text();
    if (Buffer.byteLength(text, 'utf8') > MAX_RESPONSE_BYTES) {
      throw new RemoteBackendError('license backend response exceeded the size cap', 502, 'oversized');
    }
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new RemoteBackendError('license backend returned invalid JSON', 502, 'invalid_json');
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new RemoteBackendError('license backend returned a non-object response', 502, 'invalid_json');
    }
    if (requireEnvelope && !isEnvelopeShape(parsed)) {
      throw new RemoteBackendError('license backend returned an unexpected envelope shape', 502, 'bad_envelope');
    }
    if (requireEnvelope && this._publicKey && !verifyEnvelope(parsed, this._publicKey)) {
      throw new RemoteBackendError('license backend envelope failed signature verification against the pinned key', 502, 'bad_signature');
    }
    return /** @type {Record<string, unknown>} */ (parsed);
  }
}

/**
 * Shape check for the GPSLab envelope. Exported so callers can distinguish a
 * shape failure from a signature failure.
 * @param {unknown} value
 */
export function isEnvelopeShape(value) {
  if (!value || typeof value !== 'object') return false;
  const envelope = /** @type {Record<string, unknown>} */ (value);
  return (
    envelope.version === 1 &&
    typeof envelope.alg === 'string' &&
    envelope.alg.toUpperCase() === 'ES256' &&
    typeof envelope.payload === 'string' &&
    typeof envelope.signature === 'string'
  );
}
