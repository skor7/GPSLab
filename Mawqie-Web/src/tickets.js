// @ts-check
/**
 * Contact / feedback tickets with a server-enforced status workflow.
 * Rate limiting and CSRF are applied by the HTTP layer before this service runs.
 *
 * Categories are the six customer-facing options; statuses are exactly
 * `new → reviewing → answered → closed` (with the deliberate reopen edges below).
 */
import { newId } from './core/ids.js';
import { normalizeEmail } from './core/email.js';

/** The six ticket category options (stable ids; labels live in the views). */
export const TICKET_CATEGORIES = /** @type {const} */ ([
  'general',
  'technical',
  'billing',
  'activation',
  'suggestion',
  'other',
]);
export const TICKET_STATUSES = /** @type {const} */ (['new', 'reviewing', 'answered', 'closed']);

/** @type {Record<string, string[]>} */
const STATUS_TRANSITIONS = {
  new: ['reviewing', 'answered', 'closed'],
  reviewing: ['new', 'answered', 'closed'],
  answered: ['new', 'reviewing', 'closed'],
  closed: ['new'],
};

export class TicketError extends Error {
  /** @param {string} message @param {number} [status] @param {string} [code] */
  constructor(message, status = 400, code = 'ticket_error') {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export class TicketService {
  /**
   * @param {object} deps
   * @param {import('./store/store.js').Store} deps.store
   * @param {() => number} deps.now
   * @param {import('./audit.js').AuditLog} deps.audit
   * @param {import('./notifications/channels.js').Notifier} deps.notifier
   */
  constructor({ store, now, audit, notifier }) {
    this.store = store;
    this.now = now;
    this.audit = audit;
    this.notifier = notifier;
  }

  /**
   * @param {{category: string, name: string, email: string, subject: string, message: string, customerId?: string | null, ip?: string}} input
   */
  create({ category, name, email, subject, message, customerId = null, ip = '' }) {
    if (!TICKET_CATEGORIES.includes(/** @type {any} */ (category))) {
      throw new TicketError(`category must be one of: ${TICKET_CATEGORIES.join(', ')}`, 400, 'invalid_category');
    }
    const nowMs = this.now();
    const ticket = {
      id: newId(),
      category,
      customerId: customerId ?? null,
      name,
      emailNormalized: normalizeEmail(email),
      subject,
      message,
      status: 'new',
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
      replies: [],
    };
    this.store.tickets.set(ticket.id, ticket);
    this.audit.record({
      action: 'ticket.created',
      actorType: customerId ? 'customer' : 'guest',
      actorId: customerId ?? null,
      targetType: 'ticket',
      targetId: ticket.id,
      details: { category, subject },
      ip,
    });
    void this.notifier.notify({
      to: ticket.emailNormalized,
      subject: 'تم استلام رسالتك — موقع',
      body: `رقم التذكرة ${ticket.id}. سنعاود التواصل معك قريبًا.`,
      template: 'ticket-ack',
      meta: { ticketId: ticket.id, category },
    });
    this.store.touch();
    return ticket;
  }

  /** @param {string} customerId */
  listForCustomer(customerId) {
    return [...this.store.tickets.values()]
      .filter((ticket) => ticket.customerId === customerId)
      .sort((a, b) => b.createdAtMs - a.createdAtMs);
  }

  /**
   * @param {{customerId: string}} principal
   * @param {string} ticketId
   */
  getForCustomer(principal, ticketId) {
    const ticket = this.store.tickets.get(ticketId);
    if (!ticket || ticket.customerId !== principal.customerId) {
      throw new TicketError('ticket not found', 404, 'not_found');
    }
    return ticket;
  }

  /** @param {{status?: string, category?: string}} [filter] */
  list(filter = {}) {
    let tickets = [...this.store.tickets.values()];
    if (filter.status) tickets = tickets.filter((ticket) => ticket.status === filter.status);
    if (filter.category) tickets = tickets.filter((ticket) => ticket.category === filter.category);
    return tickets.sort((a, b) => b.createdAtMs - a.createdAtMs);
  }

  /**
   * @param {string} ticketId
   * @param {string} status
   * @param {{actorType?: string, actorId?: string | null}} [actor]
   */
  updateStatus(ticketId, status, actor = {}) {
    const ticket = this.store.tickets.get(ticketId);
    if (!ticket) throw new TicketError('ticket not found', 404, 'not_found');
    if (!TICKET_STATUSES.includes(/** @type {any} */ (status))) {
      throw new TicketError(`status must be one of: ${TICKET_STATUSES.join(', ')}`, 400, 'invalid_status');
    }
    if (status === ticket.status) return ticket;
    const allowed = STATUS_TRANSITIONS[ticket.status] ?? [];
    if (!allowed.includes(status)) {
      throw new TicketError(`cannot move a ${ticket.status} ticket to ${status}`, 409, 'illegal_transition');
    }
    ticket.status = status;
    ticket.updatedAtMs = this.now();
    this.audit.record({
      action: 'ticket.status_changed',
      actorType: actor.actorType ?? 'admin',
      actorId: actor.actorId ?? null,
      targetType: 'ticket',
      targetId: ticket.id,
      details: { status },
    });
    this.store.touch();
    return ticket;
  }
}
