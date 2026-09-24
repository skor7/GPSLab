// @ts-check
import fs from 'node:fs';
import path from 'node:path';

/** Collection names that are Map-backed and persisted as arrays. */
const MAP_COLLECTIONS = [
  'customers',
  'customersByEmail',
  'sessions',
  'adminSessions',
  'installations',
  'redemptions',
  'orders',
  'payments',
  'licenses',
  'activationCodes',
  'tickets',
];

/**
 * A small in-memory data store with optional JSON file persistence for
 * local/staging. It is intentionally simple: a single-process store with a
 * debounced atomic write. It is NOT a production database and the README says so.
 *
 * Tests use `new Store()` (no file). The server passes `config.dataFile`.
 */
export class Store {
  /** @param {{dataFile?: string | null}} [options] */
  constructor(options = {}) {
    /** @type {string | null} */
    this.dataFile = options.dataFile ? path.resolve(options.dataFile) : null;
    /** @type {Map<string, any>} */ this.customers = new Map();
    /** @type {Map<string, any>} */ this.customersByEmail = new Map();
    /** @type {Map<string, any>} */ this.sessions = new Map();
    /** @type {Map<string, any>} */ this.adminSessions = new Map();
    /** @type {Map<string, any>} */ this.installations = new Map();
    /** @type {Map<string, any>} */ this.redemptions = new Map();
    /** @type {Map<string, any>} */ this.orders = new Map();
    /** @type {Map<string, any>} */ this.payments = new Map();
    /** @type {Map<string, any>} */ this.licenses = new Map();
    /** @type {Map<string, any>} */ this.activationCodes = new Map();
    /** @type {Map<string, any>} */ this.tickets = new Map();
    /** @type {any[]} */ this.audit = [];
    /** @type {any[]} */ this.notifications = [];
    /** @type {NodeJS.Timeout | null} */ this._persistTimer = null;
  }

  /**
   * Serialize the store to a plain object (Maps become arrays).
   * @returns {Record<string, unknown>}
   */
  toJSON() {
    /** @type {Record<string, unknown>} */
    const out = { version: 1 };
    for (const name of MAP_COLLECTIONS) {
      const map = /** @type {Map<string, any>} */ (/** @type {any} */ (this)[name]);
      out[name] = [...map.entries()];
    }
    out.audit = this.audit;
    out.notifications = this.notifications;
    return out;
  }

  /**
   * @param {Record<string, unknown>} data
   */
  fromJSON(data) {
    if (!data || typeof data !== 'object') return;
    for (const name of MAP_COLLECTIONS) {
      const entries = data[name];
      if (!Array.isArray(entries)) continue;
      const map = /** @type {Map<string, any>} */ (/** @type {any} */ (this)[name]);
      map.clear();
      for (const entry of entries) {
        if (Array.isArray(entry) && entry.length === 2) {
          map.set(entry[0], entry[1]);
        }
      }
    }
    this.audit = Array.isArray(data.audit) ? /** @type {any[]} */ (data.audit) : [];
    this.notifications = Array.isArray(data.notifications) ? /** @type {any[]} */ (data.notifications) : [];
  }

  /** Load state from `dataFile` if configured and present. */
  load() {
    if (!this.dataFile) return;
    try {
      if (!fs.existsSync(this.dataFile)) return;
      const raw = fs.readFileSync(this.dataFile, 'utf8');
      if (!raw.trim()) return;
      this.fromJSON(JSON.parse(raw));
    } catch (error) {
      // A corrupt local state file must not crash the server; start empty and
      // leave the corrupt file in place for inspection.
      // eslint-disable-next-line no-console
      console.error(`[mawqie] could not load data file: ${/** @type {Error} */ (error).name}`);
    }
  }

  /** Persist immediately (atomic write via temp file + rename). */
  flush() {
    if (!this.dataFile) return;
    if (this._persistTimer) {
      clearTimeout(this._persistTimer);
      this._persistTimer = null;
    }
    const dir = path.dirname(this.dataFile);
    fs.mkdirSync(dir, { recursive: true });
    const tmp = `${this.dataFile}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, JSON.stringify(this.toJSON()), 'utf8');
    fs.renameSync(tmp, this.dataFile);
  }

  /** Schedule a debounced persist. No-op without a data file. */
  touch() {
    if (!this.dataFile) return;
    if (this._persistTimer) return;
    this._persistTimer = setTimeout(() => {
      this._persistTimer = null;
      try {
        this.flush();
      } catch (error) {
        // eslint-disable-next-line no-console
        console.error(`[mawqie] could not persist data file: ${/** @type {Error} */ (error).name}`);
      }
    }, 50);
    if (typeof this._persistTimer.unref === 'function') this._persistTimer.unref();
  }
}
