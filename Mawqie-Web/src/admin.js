// @ts-check
/**
 * Admin authentication (separate from customer sessions) and dashboard queries.
 *
 * Admin credentials come from configuration (`ADMIN_EMAIL` +
 * `ADMIN_PASSWORD_HASH`). There is no default admin and no hardcoded password:
 * if they are not configured, admin login is disabled and returns 503.
 */
import { newId, newToken, sha256Hex } from './core/ids.js';
import { verifyPassword } from './core/password.js';
import { normalizeEmail } from './core/email.js';

const ADMIN_SESSION_TTL_MS = 12 * 60 * 60 * 1000;

export class AdminError extends Error {
  /** @param {string} message @param {number} [status] @param {string} [code] */
  constructor(message, status = 400, code = 'admin_error') {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export class AdminService {
  /** @param {{store: import('./store/store.js').Store, config: import('./config.js').MawqieConfig, now: () => number, audit: import('./audit.js').AuditLog}} deps */
  constructor({ store, config, now, audit }) {
    this.store = store;
    this.config = config;
    this.now = now;
    this.audit = audit;
  }

  isConfigured() {
    return this.config.adminConfigured;
  }

  /**
   * @param {{email: string, password: string, ip?: string}} input
   */
  login({ email, password, ip = '' }) {
    if (!this.isConfigured()) {
      throw new AdminError('admin access is not configured', 503, 'admin_disabled');
    }
    const emailMatches = normalizeEmail(email) === this.config.adminEmail;
    const passwordMatches = verifyPassword(typeof password === 'string' ? password : '', this.config.adminPasswordHash);
    if (!emailMatches || !passwordMatches) {
      this.audit.record({ action: 'admin.login_failed', actorType: 'anonymous', targetType: 'admin', ip });
      throw new AdminError('invalid admin credentials', 401, 'invalid_credentials');
    }
    const token = newToken(32);
    const nowMs = this.now();
    const session = { id: newId(), adminEmail: this.config.adminEmail, createdAtMs: nowMs, expiresAtMs: nowMs + ADMIN_SESSION_TTL_MS };
    this.store.adminSessions.set(sha256Hex(token), session);
    this.audit.record({ action: 'admin.login', actorType: 'admin', actorId: this.config.adminEmail, targetType: 'admin', ip });
    this.store.touch();
    return { token, session };
  }

  /** @param {string | null | undefined} token */
  resolveSession(token) {
    if (!token) return null;
    const key = sha256Hex(token);
    const session = this.store.adminSessions.get(key);
    if (!session) return null;
    if (session.expiresAtMs <= this.now()) {
      this.store.adminSessions.delete(key);
      this.store.touch();
      return null;
    }
    return { session, admin: { email: session.adminEmail } };
  }

  /** @param {string | null | undefined} token */
  logout(token) {
    if (!token) return false;
    const removed = this.store.adminSessions.delete(sha256Hex(token));
    if (removed) this.store.touch();
    return removed;
  }

  /** Aggregated dashboard data (no secrets, no password hashes). */
  summary() {
    const customers = [...this.store.customers.values()];
    const licenses = [...this.store.licenses.values()];
    const orders = [...this.store.orders.values()];
    const tickets = [...this.store.tickets.values()];
    return {
      counts: {
        customers: customers.length,
        licenses: licenses.length,
        activeLicenses: licenses.filter((license) => license.status === 'active').length,
        revokedLicenses: licenses.filter((license) => license.status === 'revoked').length,
        orders: orders.length,
        paidOrders: orders.filter((order) => order.status === 'paid').length,
        openTickets: tickets.filter((ticket) => ticket.status === 'new').length,
        redemptions: this.store.redemptions.size,
      },
      customers: customers.map((customer) => ({
        id: customer.id,
        email: customer.emailNormalized,
        displayName: customer.displayName,
        createdAtMs: customer.createdAtMs,
      })),
      licenses: licenses.map((license) => ({
        id: license.id,
        customerId: license.customerId,
        planId: license.planId,
        status: license.status,
        source: license.source,
        installations: license.installations,
        expiresAtMs: license.expiresAtMs,
        revokedAtMs: license.revokedAtMs,
        revokeReason: license.revokeReason,
      })),
      orders: orders.map((order) => ({
        id: order.id,
        customerId: order.customerId,
        planId: order.planId,
        amount: order.amount,
        currency: order.currency,
        status: order.status,
        licenseId: order.licenseId,
        createdAtMs: order.createdAtMs,
      })),
      tickets: tickets.map((ticket) => ({
        id: ticket.id,
        category: ticket.category,
        email: ticket.emailNormalized,
        subject: ticket.subject,
        status: ticket.status,
        createdAtMs: ticket.createdAtMs,
      })),
    };
  }
}
