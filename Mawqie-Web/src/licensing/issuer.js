// @ts-check
/**
 * Entitlement envelope issuance (local signer).
 *
 * The time-derived status mirrors GPSLab's own policy
 * (`Source/GPSLabLicensePolicy.h`): revoked is authoritative; otherwise the
 * server truthfully signs active / grace / expired based on its clock.
 */
import { signEnvelope } from './signing.js';

/**
 * @typedef {object} LicenseRecord
 * @property {string} id
 * @property {string} customerId
 * @property {string} planId
 * @property {string[]} installations
 * @property {'active'|'revoked'} status
 * @property {number} issuedAtMs
 * @property {number} expiresAtMs
 * @property {number} graceUntilMs
 * @property {string | null} refreshTokenHash
 * @property {string} source
 * @property {string | null} orderId
 * @property {number} createdAtMs
 * @property {number} updatedAtMs
 * @property {number | null} revokedAtMs
 * @property {string | null} revokedBy
 * @property {string | null} revokeReason
 */

/**
 * Resolve the signed status for a license at a given time.
 * @param {LicenseRecord} license
 * @param {number} nowMs
 * @returns {'active'|'grace'|'expired'|'revoked'}
 */
export function licenseStatusAt(license, nowMs) {
  if (license.status === 'revoked') return 'revoked';
  if (nowMs < license.expiresAtMs) return 'active';
  if (license.graceUntilMs > license.expiresAtMs && nowMs < license.graceUntilMs) return 'grace';
  return 'expired';
}

export class LocalLicenseIssuer {
  /**
   * @param {{config: {licenseIssuer: string, licenseAudience: string}, keyMaterial: import('./signing.js').KeyMaterial, now: () => number}} deps
   */
  constructor({ config, keyMaterial, now }) {
    this.config = config;
    this.keyMaterial = keyMaterial;
    this.now = now;
  }

  /** Public verification material (safe to expose; never the private key). */
  publicKeyBase64() {
    return this.keyMaterial.publicKeyBase64Spki;
  }

  isEphemeral() {
    return this.keyMaterial.ephemeral;
  }

  /**
   * Build a signed envelope for a license bound to an installation.
   * @param {LicenseRecord} license
   * @param {string} installationId
   * @param {string} [refreshToken]
   */
  issue(license, installationId, refreshToken) {
    const nowMs = this.now();
    const status = licenseStatusAt(license, nowMs);
    const nowSec = Math.floor(nowMs / 1000);
    const expiresAt = Math.floor(license.expiresAtMs / 1000);
    const graceUntil = Math.max(0, Math.floor(license.graceUntilMs / 1000));
    const claims = {
      entitlementId: license.id,
      installationId,
      plan: license.planId,
      status,
      issuedAt: nowSec,
      expiresAt,
      graceUntil,
      issuer: this.config.licenseIssuer,
      audience: this.config.licenseAudience,
    };
    return signEnvelope(claims, this.keyMaterial.privateKey, refreshToken);
  }
}
