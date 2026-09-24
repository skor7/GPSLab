// @ts-check
/**
 * Append-only audit log for administrative and security-relevant actions
 * (license issuance/activation/revocation, admin logins, ticket status changes).
 */
import { newId } from './core/ids.js';

export class AuditLog {
  /** @param {{store: import('./store/store.js').Store, now: () => number}} deps */
  constructor({ store, now }) {
    this.store = store;
    this.now = now;
  }

  /**
   * @param {object} entry
   * @param {string} entry.action
   * @param {string} [entry.actorType]
   * @param {string | null} [entry.actorId]
   * @param {string} [entry.targetType]
   * @param {string | null} [entry.targetId]
   * @param {Record<string, unknown>} [entry.details]
   * @param {string} [entry.ip]
   */
  record(entry) {
    const record = {
      id: newId(),
      atMs: this.now(),
      action: entry.action,
      actorType: entry.actorType ?? 'system',
      actorId: entry.actorId ?? null,
      targetType: entry.targetType ?? null,
      targetId: entry.targetId ?? null,
      details: entry.details ?? {},
      ip: entry.ip ?? '',
    };
    this.store.audit.push(record);
    this.store.touch();
    return record;
  }

  /** @param {{limit?: number, action?: string}} [options] */
  list(options = {}) {
    const limit = options.limit ?? 200;
    let entries = [...this.store.audit];
    if (options.action) entries = entries.filter((entry) => entry.action === options.action);
    return entries.sort((a, b) => b.atMs - a.atMs).slice(0, limit);
  }
}
