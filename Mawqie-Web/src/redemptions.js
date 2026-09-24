// @ts-check
/**
 * Redemption history. Every trial claim and every activation/installation
 * binding is recorded here, keyed by normalized email and installation id, so
 * eligibility decisions and support/audit views have a single source of truth.
 */
import { newId } from './core/ids.js';
import { normalizeEmail } from './core/email.js';

/**
 * @typedef {object} Redemption
 * @property {string} id
 * @property {'trial'|'activation'|'purchase'} kind
 * @property {string} emailNormalized
 * @property {string} installationId
 * @property {string} planId
 * @property {string | null} customerId
 * @property {string | null} licenseId
 * @property {string | null} orderId
 * @property {number} createdAtMs
 * @property {string} ip
 */

/**
 * @param {import('./store/store.js').Store} store
 * @param {Omit<Redemption, 'id' | 'emailNormalized' | 'createdAtMs'> & {email?: string, createdAtMs?: number}} entry
 * @returns {Redemption}
 */
export function recordRedemption(store, entry) {
  const redemption = {
    id: newId(),
    kind: entry.kind,
    emailNormalized: normalizeEmail(entry.email),
    installationId: entry.installationId,
    planId: entry.planId,
    customerId: entry.customerId ?? null,
    licenseId: entry.licenseId ?? null,
    orderId: entry.orderId ?? null,
    createdAtMs: entry.createdAtMs ?? Date.now(),
    ip: entry.ip ?? '',
  };
  store.redemptions.set(redemption.id, redemption);
  store.touch();
  return redemption;
}

/**
 * @param {import('./store/store.js').Store} store
 * @param {{email?: string, installationId?: string}} query
 * @returns {Redemption[]}
 */
export function redemptionHistory(store, query) {
  const email = query.email ? normalizeEmail(query.email) : null;
  const installationId = query.installationId ? String(query.installationId).toLowerCase() : null;
  const results = [];
  for (const redemption of store.redemptions.values()) {
    if (email && redemption.emailNormalized !== email) continue;
    if (installationId && redemption.installationId !== installationId) continue;
    results.push(redemption);
  }
  return results.sort((a, b) => b.createdAtMs - a.createdAtMs);
}

/** @param {import('./store/store.js').Store} store */
export function allRedemptions(store) {
  return [...store.redemptions.values()].sort((a, b) => b.createdAtMs - a.createdAtMs);
}
