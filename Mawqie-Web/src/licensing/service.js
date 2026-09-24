// @ts-check
/**
 * Licensing service. Server-side only: the signing key never leaves this process
 * and no client can mint an entitlement.
 *
 * Invariant: a paid license is created ONLY from an order whose status is
 * `paid`. `createLicenseForPaidOrder` refuses anything else.
 */
import { newId, newToken, sha256Hex } from '../core/ids.js';
import { recordRedemption } from '../redemptions.js';
import { licenseStatusAt } from './issuer.js';

const DAY_MS = 24 * 60 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;

export class LicenseError extends Error {
  /** @param {string} message @param {number} [status] @param {string} [code] */
  constructor(message, status = 400, code = 'license_error') {
    super(message);
    this.name = 'LicenseError';
    this.status = status;
    this.code = code;
  }
}

export class LicensingService {
  /**
   * @param {object} deps
   * @param {import('../config.js').MawqieConfig} deps.config
   * @param {import('../store/store.js').Store} deps.store
   * @param {import('../plans.js').PlanCatalog} deps.plans
   * @param {import('./issuer.js').LocalLicenseIssuer | import('./adapter.js').RemoteLicenseIssuer} deps.issuer
   * @param {() => number} deps.now
   * @param {{record: (entry: Record<string, unknown>) => any}} [deps.audit]
   */
  constructor({ config, store, plans, issuer, now, audit }) {
    this.config = config;
    this.store = store;
    this.plans = plans;
    this.issuer = issuer;
    this.now = now;
    this.audit = audit;
  }

  isRemote() {
    return this.config.licenseMode === 'remote';
  }

  publicKeyBase64() {
    return this.issuer.publicKeyBase64();
  }

  isEphemeralKey() {
    return typeof this.issuer.isEphemeral === 'function' ? this.issuer.isEphemeral() : false;
  }

  /** Forward a raw license request to the configured remote backend seam. */
  async forwardRemote(request) {
    if (!this.isRemote()) throw new LicenseError('remote license mode is not enabled', 500, 'not_remote');
    return this.issuer.issue(request);
  }

  /**
   * Verify a remote-issued envelope against the pinned remote key. Returns the
   * claims, or null when the integration has no pinned key / cannot verify
   * (fail closed: an unverifiable envelope is never treated as valid).
   * @param {Record<string, unknown>} envelope
   */
  verifyRemoteEnvelope(envelope) {
    if (!this.isRemote()) throw new LicenseError('remote license mode is not enabled', 500, 'not_remote');
    if (typeof this.issuer.verify !== 'function') return null;
    return this.issuer.verify(envelope);
  }

  /**
   * Revoke a license at the remote backend.
   * @param {string} licenseId
   * @param {{reason?: string, actorId?: string | null}} [options]
   */
  async revokeRemote(licenseId, options = {}) {
    if (!this.isRemote()) throw new LicenseError('remote license mode is not enabled', 500, 'not_remote');
    return this.issuer.revoke({ licenseId, reason: options.reason, actorId: options.actorId });
  }

  /**
   * Mode-aware revocation used by the admin API so the same route works for the
   * local signer and a future remote backend without a frontend/API rewrite.
   * @param {string} licenseId
   * @param {{actorType?: string, actorId?: string | null, reason?: string}} [options]
   */
  async revokeLicense(licenseId, options = {}) {
    if (this.isRemote()) return this.revokeRemote(licenseId, options);
    return this.revoke(licenseId, options);
  }

  /**
   * Create a license for a PAID order. This is the only purchase path that
   * creates a license. Throws when the order is not paid.
   * @param {any} order
   * @returns {{license: any, activationCode: string}}
   */
  createLicenseForPaidOrder(order) {
    if (!order || order.status !== 'paid') {
      throw new LicenseError('a license can only be issued for a paid order', 402, 'payment_required');
    }
    if (order.licenseId) {
      // Idempotent: the order already produced a license.
      const existing = this.store.licenses.get(order.licenseId);
      if (existing) {
        const record = [...this.store.activationCodes.values()].find((code) => code.licenseId === existing.id);
        return { license: existing, activationCode: record?.code ?? '' };
      }
    }
    const plan = this.plans.require(order.planId);
    const nowMs = this.now();
    const license = {
      id: newId(),
      customerId: order.customerId,
      planId: order.planId,
      installations: [],
      status: 'active',
      issuedAtMs: nowMs,
      expiresAtMs: nowMs + plan.durationDays * DAY_MS,
      graceUntilMs: nowMs + (plan.durationDays + plan.graceDays) * DAY_MS,
      refreshTokenHash: null,
      source: 'purchase',
      orderId: order.id,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
      revokedAtMs: null,
      revokedBy: null,
      revokeReason: null,
    };
    this.store.licenses.set(license.id, license);
    const activationCode = this.createActivationCode(license, order);
    order.licenseId = license.id;
    order.updatedAtMs = nowMs;
    this.audit?.record({
      action: 'license.issued',
      actorType: 'system',
      actorId: null,
      targetType: 'license',
      targetId: license.id,
      details: { orderId: order.id, planId: order.planId },
    });
    this.store.touch();
    return { license, activationCode };
  }

  /**
   * Create a trial license bound immediately to one installation.
   * @param {{customerId: string | null, plan: any, installationId: string, email: string}} input
   */
  createTrialLicense({ customerId, plan, installationId, email }) {
    const nowMs = this.now();
    const license = {
      id: newId(),
      customerId: customerId ?? null,
      planId: plan.id,
      installations: [String(installationId).toLowerCase()],
      status: 'active',
      issuedAtMs: nowMs,
      expiresAtMs: nowMs + plan.trial.durationHours * HOUR_MS,
      graceUntilMs: nowMs + plan.trial.durationHours * HOUR_MS,
      refreshTokenHash: null,
      source: 'trial',
      orderId: null,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
      revokedAtMs: null,
      revokedBy: null,
      revokeReason: null,
      emailNormalized: email,
    };
    this.store.licenses.set(license.id, license);
    this.audit?.record({
      action: 'license.trial_issued',
      actorType: 'customer',
      actorId: customerId ?? null,
      targetType: 'license',
      targetId: license.id,
      details: { planId: plan.id, installationId: license.installations[0] },
    });
    this.store.touch();
    return license;
  }

  /**
   * @param {any} license
   * @param {any} order
   */
  createActivationCode(license, order) {
    const code = newToken(16);
    const nowMs = this.now();
    const record = {
      id: newId(),
      codeHash: sha256Hex(code),
      code,
      licenseId: license.id,
      customerId: license.customerId,
      orderId: order?.id ?? null,
      createdAtMs: nowMs,
      usedAtMs: null,
      installations: [],
    };
    this.store.activationCodes.set(record.codeHash, record);
    return code;
  }

  /**
   * Issue a signed envelope and rotate the refresh token. The installation id is
   * echoed EXACTLY as supplied (GPSLab compares it case-sensitively against the
   * device's installation UUID).
   * @param {any} license
   * @param {string} installationId
   */
  issueEnvelopeFor(license, installationId) {
    const token = newToken(32);
    license.refreshTokenHash = sha256Hex(token);
    license.updatedAtMs = this.now();
    const envelope = this.issuer.issue(license, String(installationId), token);
    this.store.touch();
    return envelope;
  }

  /**
   * Redeem an activation code for an installation.
   * @param {{code: string, installationId: string, ip?: string}} input
   */
  redeemActivation({ code, installationId, ip = '' }) {
    const normalizedCode = String(code || '').trim();
    if (!normalizedCode) throw new LicenseError('activation code is required', 400, 'missing_code');
    const record = this.store.activationCodes.get(sha256Hex(normalizedCode));
    if (!record) throw new LicenseError('activation code is not recognised', 404, 'unknown_code');
    const license = this.store.licenses.get(record.licenseId);
    if (!license) throw new LicenseError('activation code has no license', 409, 'orphan_code');
    if (license.status === 'revoked') throw new LicenseError('this license was revoked', 403, 'revoked');

    const installation = String(installationId).toLowerCase();
    const plan = this.plans.require(license.planId);
    if (!license.installations.includes(installation)) {
      if (license.installations.length >= plan.maxInstallations) {
        throw new LicenseError('installation limit reached for this license', 409, 'installation_limit');
      }
      license.installations.push(installation);
      license.updatedAtMs = this.now();
      record.installations.push(installation);
      if (!record.usedAtMs) record.usedAtMs = this.now();
      recordRedemption(this.store, {
        kind: 'activation',
        email: license.emailNormalized || this.emailForCustomer(license.customerId),
        installationId: installation,
        planId: license.planId,
        customerId: license.customerId,
        licenseId: license.id,
        orderId: license.orderId,
        ip,
      });
      this.audit?.record({
        action: 'license.activated',
        actorType: 'customer',
        actorId: license.customerId,
        targetType: 'license',
        targetId: license.id,
        details: { installationId: installation },
      });
    }
    const envelope = this.issueEnvelopeFor(license, installationId);
    return { license, envelope };
  }

  /**
   * Refresh a license by its opaque refresh token.
   * @param {{refreshToken: string, installationId: string}} input
   */
  refreshByToken({ refreshToken, installationId }) {
    if (!refreshToken) throw new LicenseError('refresh token is required', 400, 'missing_refresh_token');
    const hash = sha256Hex(refreshToken);
    let license = null;
    for (const candidate of this.store.licenses.values()) {
      if (candidate.refreshTokenHash && candidate.refreshTokenHash === hash) {
        license = candidate;
        break;
      }
    }
    if (!license) throw new LicenseError('refresh token is not valid', 401, 'invalid_refresh_token');
    const installation = String(installationId).toLowerCase();
    if (!license.installations.includes(installation)) {
      throw new LicenseError('this license is not bound to this installation', 403, 'binding_mismatch');
    }
    const envelope = this.issueEnvelopeFor(license, installationId);
    return { license, envelope };
  }

  /**
   * Find the most recent license bound to an installation and issue an envelope.
   * @param {string} installationId
   */
  lookupByInstallation(installationId) {
    const installation = String(installationId).toLowerCase();
    let found = null;
    for (const license of this.store.licenses.values()) {
      if (license.installations.includes(installation)) {
        if (!found || license.updatedAtMs > found.updatedAtMs) found = license;
      }
    }
    if (!found) return null;
    return { license: found, envelope: this.issueEnvelopeFor(found, installationId) };
  }

  /** @param {string} licenseId */
  getLicense(licenseId) {
    return this.store.licenses.get(licenseId) ?? null;
  }

  /** @param {string} customerId */
  listForCustomer(customerId) {
    return [...this.store.licenses.values()]
      .filter((license) => license.customerId === customerId)
      .sort((a, b) => b.createdAtMs - a.createdAtMs);
  }

  /** @param {string} licenseId */
  listActivationCodes(licenseId) {
    return [...this.store.activationCodes.values()].filter((record) => record.licenseId === licenseId);
  }

  /**
   * Revoke a license. Writes an audit entry with the actor and reason.
   * @param {string} licenseId
   * @param {{actorType?: string, actorId?: string | null, reason?: string}} [options]
   */
  revoke(licenseId, options = {}) {
    const license = this.store.licenses.get(licenseId);
    if (!license) throw new LicenseError('license not found', 404, 'not_found');
    license.status = 'revoked';
    license.revokedAtMs = this.now();
    license.revokedBy = options.actorId ?? null;
    license.revokeReason = options.reason ?? null;
    license.updatedAtMs = this.now();
    this.audit?.record({
      action: 'license.revoked',
      actorType: options.actorType ?? 'admin',
      actorId: options.actorId ?? null,
      targetType: 'license',
      targetId: license.id,
      details: { reason: license.revokeReason, customerId: license.customerId },
    });
    this.store.touch();
    return license;
  }

  /** @param {string | null} customerId */
  emailForCustomer(customerId) {
    if (!customerId) return '';
    const customer = this.store.customers.get(customerId);
    return customer?.emailNormalized ?? '';
  }
}

export { licenseStatusAt };
