// @ts-check
/**
 * Mock PaymentProvider (local/staging only).
 *
 * This is a deterministic state machine that stands in for a real PSP. It never
 * talks to a real card network and never charges anything. It is disabled in
 * production by config validation and its routes are not registered in
 * production (see server.js), so a customer-facing production build has no mock
 * payment surface at all.
 *
 * The provider "reports" outcomes as webhook events. The server treats those
 * events as authoritative only after verifying their HMAC signature, exactly as
 * it would for a real provider.
 */
import { newId } from '../core/ids.js';

/** @typedef {'created'|'pending'|'processing'|'paid'|'failed'|'expired'|'refunded'|'cancelled'} PaymentState */

export const PAYMENT_STATES = /** @type {const} */ ([
  'created',
  'pending',
  'processing',
  'paid',
  'failed',
  'expired',
  'refunded',
  'cancelled',
]);

/** @type {Record<PaymentState, PaymentState[]>} */
const TRANSITIONS = {
  created: ['pending', 'cancelled', 'expired'],
  pending: ['processing', 'failed', 'expired', 'cancelled'],
  processing: ['paid', 'failed'],
  paid: ['refunded'],
  failed: [],
  expired: [],
  refunded: [],
  cancelled: [],
};

export class PaymentError extends Error {
  /** @param {string} message @param {number} [status] @param {string} [code] */
  constructor(message, status = 400, code = 'payment_error') {
    super(message);
    this.name = 'PaymentError';
    this.status = status;
    this.code = code;
  }
}

export class MockPaymentProvider {
  name = 'mock';
  /** @param {{store: import('../store/store.js').Store, now: () => number}} deps */
  constructor({ store, now }) {
    this.store = store;
    this.now = now;
  }

  /**
   * @param {{orderId: string, amount: number, currency: string}} input
   */
  createIntent({ orderId, amount, currency }) {
    if (!Number.isInteger(amount) || amount < 0) {
      throw new PaymentError('amount must be a non-negative integer (minor units)', 400, 'invalid_amount');
    }
    const intent = {
      id: newId(),
      provider: this.name,
      orderId,
      amount,
      currency,
      state: /** @type {PaymentState} */ ('created'),
      createdAtMs: this.now(),
      updatedAtMs: this.now(),
      history: [{ state: 'created', atMs: this.now() }],
      failureReason: null,
    };
    this.store.payments.set(intent.id, intent);
    this.transition(intent.id, 'pending');
    return intent;
  }

  /** @param {string} intentId */
  getIntent(intentId) {
    return this.store.payments.get(intentId) ?? null;
  }

  /**
   * @param {string} intentId
   * @param {PaymentState} next
   */
  transition(intentId, next) {
    const intent = this.store.payments.get(intentId);
    if (!intent) throw new PaymentError('payment intent not found', 404, 'not_found');
    if (!PAYMENT_STATES.includes(next)) {
      throw new PaymentError(`unknown payment state: ${next}`, 400, 'invalid_state');
    }
    const allowed = TRANSITIONS[/** @type {PaymentState} */ (intent.state)];
    if (!allowed.includes(next)) {
      throw new PaymentError(`illegal transition ${intent.state} -> ${next}`, 409, 'illegal_transition');
    }
    intent.state = next;
    intent.updatedAtMs = this.now();
    intent.history.push({ state: next, atMs: this.now() });
    this.store.touch();
    return intent;
  }

  /** Simulate a successful payment (dev/staging only). */
  simulatePay(intentId) {
    this.transition(intentId, 'processing');
    const intent = this.transition(intentId, 'paid');
    return this.buildEvent('payment.succeeded', intent);
  }

  /** @param {string} intentId @param {string} [reason] */
  simulateFailure(intentId, reason = 'declined') {
    const intent = this.getIntent(intentId);
    if (!intent) throw new PaymentError('payment intent not found', 404, 'not_found');
    intent.failureReason = reason;
    this.transition(intentId, 'failed');
    return this.buildEvent('payment.failed', intent);
  }

  /** @param {string} intentId */
  refund(intentId) {
    const intent = this.transition(intentId, 'refunded');
    return this.buildEvent('payment.refunded', intent);
  }

  /**
   * Build the provider webhook event payload for an intent.
   * @param {string} type
   * @param {any} intent
   */
  buildEvent(type, intent) {
    return {
      id: newId(),
      type,
      createdAtMs: this.now(),
      data: {
        intentId: intent.id,
        orderId: intent.orderId,
        amount: intent.amount,
        currency: intent.currency,
        provider: this.name,
        state: intent.state,
        reason: intent.failureReason ?? null,
      },
    };
  }

  /** @param {string} intentId @param {string} type */
  eventPayload(intentId, type) {
    const intent = this.getIntent(intentId);
    if (!intent) throw new PaymentError('payment intent not found', 404, 'not_found');
    return this.buildEvent(type, intent);
  }
}
