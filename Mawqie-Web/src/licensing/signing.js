// @ts-check
/**
 * Server-side entitlement signing.
 *
 * Produces the EXACT envelope GPSLab verifies (see
 * `Source/GPSLabTokenVerifier.h` / `.m`):
 *
 *   {
 *     "version": 1,
 *     "alg": "ES256",
 *     "payload":   "<base64url of the UTF-8 payload JSON>",
 *     "signature": "<base64url of the DER-encoded ECDSA P-256 SHA-256 signature>",
 *     "refreshToken": "<optional opaque string>"
 *   }
 *
 * The signature is computed over the raw payload JSON bytes (not the base64
 * text). Node's `crypto.sign('sha256', ..., {dsaEncoding:'der'})` emits the DER
 * ECDSA signature Security.framework's `kSecKeyAlgorithmECDSASignatureMessageX962SHA256`
 * expects.
 *
 * The signing private key is loaded from configuration and never leaves the
 * server. Only the SPKI public key is ever exposed (as public verification
 * material, exactly what a host app puts in `GPSLabLicensePublicKey`).
 */
import crypto from 'node:crypto';

export class SigningKeyError extends Error {}

/**
 * @typedef {object} KeyMaterial
 * @property {crypto.KeyObject} privateKey
 * @property {crypto.KeyObject} publicKey
 * @property {string} publicKeyBase64Spki
 * @property {boolean} ephemeral
 */

/**
 * Load the P-256 signing key. In production the PEM is required by config
 * validation; in local/staging an ephemeral key is generated when absent (tokens
 * issued before a restart become unverifiable, which is acceptable for local use).
 *
 * @param {{licensePrivateKeyPem?: string, isProduction?: boolean, licenseExpectedPublicKey?: string}} config
 * @returns {KeyMaterial}
 */
export function loadKeyMaterial(config) {
  const pem = (config.licensePrivateKeyPem || '').trim();
  let privateKey;
  let ephemeral = false;
  if (pem) {
    try {
      privateKey = crypto.createPrivateKey(pem);
    } catch {
      throw new SigningKeyError('LICENSE_PRIVATE_KEY_PEM is not a valid PEM private key');
    }
    const type = privateKey.asymmetricKeyType;
    if (type !== 'ec') {
      throw new SigningKeyError('LICENSE_PRIVATE_KEY_PEM must be an EC (P-256) key');
    }
  } else {
    if (config.isProduction) {
      throw new SigningKeyError('a signing key is required in production');
    }
    privateKey = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey;
    ephemeral = true;
  }

  // Production must not issue licenses with a key the host app cannot verify.
  // Without the embedded-key pin there is no way to prove the match, so refuse.
  if (config.isProduction && !String(config.licenseExpectedPublicKey || '').trim()) {
    throw new SigningKeyError(
      'LICENSE_EXPECTED_PUBLIC_KEY is required in production so the signing key provably matches the host app embedded key'
    );
  }

  const publicKey = crypto.createPublicKey(privateKey);
  const spki = publicKey.export({ type: 'spki', format: 'der' });
  if (spki.length !== 91 || spki[26] !== 0x04) {
    throw new SigningKeyError('signing key must be a P-256 EC key (unexpected SPKI shape)');
  }
  const expected = String(config.licenseExpectedPublicKey || '').trim();
  if (expected) {
    // Compare normalized base64: tolerate base64url and missing padding, but a
    // genuine mismatch is fatal so a wrong key never silently issues licenses.
    if (normalizeBase64(spki.toString('base64')) !== normalizeBase64(expected)) {
      throw new SigningKeyError(
        'LICENSE_EXPECTED_PUBLIC_KEY does not match the configured signing key; ' +
          'the host app would reject every issued license'
      );
    }
  }
  return {
    privateKey,
    publicKey,
    publicKeyBase64Spki: spki.toString('base64'),
    ephemeral,
  };
}

/** Normalize base64/base64url to padded standard base64 for comparison. */
function normalizeBase64(value) {
  let normalized = String(value).replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '');
  while (normalized.length % 4 !== 0) normalized += '=';
  return normalized;
}

/**
 * @typedef {object} EnvelopeClaims
 * @property {string} entitlementId
 * @property {string} installationId
 * @property {string} plan
 * @property {'active'|'grace'|'expired'|'revoked'} status
 * @property {number} issuedAt
 * @property {number} expiresAt
 * @property {number} graceUntil
 * @property {string} issuer
 * @property {string} audience
 */

/**
 * Sign an envelope over the exact payload bytes.
 * @param {EnvelopeClaims} claims
 * @param {crypto.KeyObject} privateKey
 * @param {string} [refreshToken]
 */
export function signEnvelope(claims, privateKey, refreshToken) {
  const payloadBytes = Buffer.from(JSON.stringify(claims), 'utf8');
  const signature = crypto.sign('sha256', payloadBytes, { key: privateKey, dsaEncoding: 'der' });
  /** @type {Record<string, unknown>} */
  const envelope = {
    version: 1,
    alg: 'ES256',
    payload: payloadBytes.toString('base64url'),
    signature: signature.toString('base64url'),
  };
  if (refreshToken) envelope.refreshToken = refreshToken;
  return envelope;
}

/**
 * Verify an envelope locally. Used by tests to prove the signing contract
 * independently of the Objective-C verifier.
 * @param {Record<string, any>} envelope
 * @param {crypto.KeyObject} publicKey
 * @returns {EnvelopeClaims | null}
 */
export function verifyEnvelope(envelope, publicKey) {
  if (!envelope || envelope.version !== 1 || String(envelope.alg).toUpperCase() !== 'ES256') return null;
  if (typeof envelope.payload !== 'string' || typeof envelope.signature !== 'string') return null;
  const payloadBytes = Buffer.from(envelope.payload, 'base64url');
  const signature = Buffer.from(envelope.signature, 'base64url');
  if (payloadBytes.length === 0 || signature.length === 0) return null;
  const ok = crypto.verify('sha256', payloadBytes, { key: publicKey, dsaEncoding: 'der' }, signature);
  if (!ok) return null;
  try {
    return JSON.parse(payloadBytes.toString('utf8'));
  } catch {
    return null;
  }
}
