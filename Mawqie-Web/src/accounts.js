// @ts-check
/**
 * Customer accounts, password auth and server-side sessions.
 *
 * Sessions are opaque random tokens; only their SHA-256 hash is stored. Every
 * account-scoped read/write goes through `requireOwnership` so one customer can
 * never see or mutate another customer's data.
 */
import { newId, newToken, sha256Hex, timingSafeEqualStrings } from './core/ids.js';
import { normalizeEmail } from './core/email.js';
import { hashPassword, verifyPassword } from './core/password.js';

const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const MIN_PASSWORD_LENGTH = 8;

export class AccountError extends Error {
  /** @param {string} message @param {number} [status] @param {string} [code] */
  constructor(message, status = 400, code = 'account_error') {
    super(message);
    this.name = 'AccountError';
    this.status = status;
    this.code = code;
  }
}

export class AccountService {
  /** @param {{store: import('./store/store.js').Store, now: () => number}} deps */
  constructor({ store, now }) {
    this.store = store;
    this.now = now;
  }

  /**
   * @param {{email: string, password: string, displayName?: string}} input
   */
  signup({ email, password, displayName = '' }) {
    const normalized = normalizeEmail(email);
    if (!normalized) throw new AccountError('a valid email is required', 400, 'invalid_email');
    if (typeof password !== 'string' || password.length < MIN_PASSWORD_LENGTH) {
      throw new AccountError(`password must be at least ${MIN_PASSWORD_LENGTH} characters`, 400, 'weak_password');
    }
    if (this.store.customersByEmail.has(normalized)) {
      throw new AccountError('an account with this email already exists', 409, 'email_taken');
    }
    const nowMs = this.now();
    const customer = {
      id: newId(),
      emailNormalized: normalized,
      displayName: String(displayName || '').trim().slice(0, 120),
      passwordHash: hashPassword(password),
      status: 'active',
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
    };
    this.store.customers.set(customer.id, customer);
    this.store.customersByEmail.set(normalized, customer.id);
    this.store.touch();
    return customer;
  }

  /**
   * @param {{email: string, password: string}} input
   */
  login({ email, password }) {
    const normalized = normalizeEmail(email);
    const customerId = normalized ? this.store.customersByEmail.get(normalized) : undefined;
    const customer = customerId ? this.store.customers.get(customerId) : undefined;
    // Always run a hash comparison to avoid a trivial user-enumeration timing gap.
    const storedHash = customer?.passwordHash ?? 'scrypt$16384$8$1$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==';
    const ok = verifyPassword(typeof password === 'string' ? password : '', storedHash);
    if (!customer || customer.status !== 'active' || !ok) {
      throw new AccountError('invalid email or password', 401, 'invalid_credentials');
    }
    return customer;
  }

  /** @param {string} customerId */
  createSession(customerId) {
    const token = newToken(32);
    const nowMs = this.now();
    const session = {
      id: newId(),
      customerId,
      createdAtMs: nowMs,
      expiresAtMs: nowMs + SESSION_TTL_MS,
    };
    this.store.sessions.set(sha256Hex(token), session);
    this.store.touch();
    return { token, session };
  }

  /** @param {string | null | undefined} token */
  resolveSession(token) {
    if (!token) return null;
    const session = this.store.sessions.get(sha256Hex(token));
    if (!session) return null;
    if (session.expiresAtMs <= this.now()) {
      this.store.sessions.delete(sha256Hex(token));
      this.store.touch();
      return null;
    }
    const customer = this.store.customers.get(session.customerId);
    if (!customer || customer.status !== 'active') return null;
    return { session, customer };
  }

  /** @param {string | null | undefined} token */
  destroySession(token) {
    if (!token) return false;
    const removed = this.store.sessions.delete(sha256Hex(token));
    if (removed) this.store.touch();
    return removed;
  }

  /** @param {string} customerId */
  getCustomer(customerId) {
    return this.store.customers.get(customerId) ?? null;
  }

  /** @param {string} customerId */
  listSessions(customerId) {
    return [...this.store.sessions.values()].filter((session) => session.customerId === customerId);
  }

  /** @param {string} customerId */
  destroyAllSessions(customerId) {
    let count = 0;
    for (const [key, session] of this.store.sessions) {
      if (session.customerId === customerId) {
        this.store.sessions.delete(key);
        count += 1;
      }
    }
    if (count > 0) this.store.touch();
    return count;
  }

  listCustomers() {
    return [...this.store.customers.values()].sort((a, b) => b.createdAtMs - a.createdAtMs);
  }

  /**
   * Enforce cross-customer isolation: the authenticated customer must own the
   * resource. Returns the resource or throws 404 (not 403) to avoid leaking
   * existence.
   * @param {{customerId: string} | null} principal
   * @param {{customerId?: string | null} | null | undefined} resource
   * @param {string} [label]
   */
  requireOwnership(principal, resource, label = 'resource') {
    if (!principal) throw new AccountError('authentication required', 401, 'unauthenticated');
    if (!resource || resource.customerId !== principal.customerId) {
      throw new AccountError(`${label} not found`, 404, 'not_found');
    }
    return resource;
  }

  /** Constant-time compare helper for tokens (used by admin/csrf layers too). */
  static safeEqual(a, b) {
    return timingSafeEqualStrings(a, b);
  }
}

export { SESSION_TTL_MS, MIN_PASSWORD_LENGTH };
