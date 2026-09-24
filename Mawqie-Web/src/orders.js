// @ts-check
/**
 * Orders and the paid -> license pipeline.
 *
 * A license is issued ONLY from `markPaid`, and only after the webhook event's
 * amount/currency have been re-checked against the server-held order. The
 * browser never marks an order paid.
 */
import { newId } from './core/ids.js';

export class OrderError extends Error {
  /** @param {string} message @param {number} [status] @param {string} [code] */
  constructor(message, status = 400, code = 'order_error') {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export class OrderService {
  /**
   * @param {object} deps
   * @param {import('./store/store.js').Store} deps.store
   * @param {import('./plans.js').PlanCatalog} deps.plans
   * @param {() => number} deps.now
   * @param {import('./payments/mock-provider.js').MockPaymentProvider} deps.provider
   * @param {import('./licensing/service.js').LicensingService} deps.licensing
   * @param {import('./audit.js').AuditLog} deps.audit
   * @param {import('./notifications/channels.js').Notifier} deps.notifier
   */
  constructor({ store, plans, now, provider, licensing, audit, notifier }) {
    this.store = store;
    this.plans = plans;
    this.now = now;
    this.provider = provider;
    this.licensing = licensing;
    this.audit = audit;
    this.notifier = notifier;
  }

  /**
   * @param {{customerId: string, planId: string, ip?: string}} input
   */
  createOrder({ customerId, planId, ip = '' }) {
    const plan = this.plans.get(planId);
    if (!plan) throw new OrderError('unknown plan', 404, 'unknown_plan');
    if (!plan.active) throw new OrderError('this plan is not available', 409, 'plan_inactive');
    const nowMs = this.now();
    const order = {
      id: newId(),
      customerId,
      planId: plan.id,
      amount: plan.price.amount,
      currency: plan.price.currency,
      status: 'created',
      provider: this.provider.name,
      providerRef: null,
      licenseId: null,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
      paidAtMs: null,
      events: [],
      ip,
    };
    this.store.orders.set(order.id, order);
    const intent = this.provider.createIntent({
      orderId: order.id,
      amount: order.amount,
      currency: order.currency,
    });
    order.providerRef = intent.id;
    order.status = 'pending';
    order.updatedAtMs = this.now();
    this.audit.record({
      action: 'order.created',
      actorType: 'customer',
      actorId: customerId,
      targetType: 'order',
      targetId: order.id,
      details: { planId: plan.id, amount: order.amount, currency: order.currency },
      ip,
    });
    this.store.touch();
    return { order, intent };
  }

  /** @param {string} orderId */
  getOrder(orderId) {
    return this.store.orders.get(orderId) ?? null;
  }

  /** @param {string} customerId */
  listForCustomer(customerId) {
    return [...this.store.orders.values()]
      .filter((order) => order.customerId === customerId)
      .sort((a, b) => b.createdAtMs - a.createdAtMs);
  }

  /**
   * @param {{customerId: string}} principal
   * @param {string} orderId
   */
  getForCustomer(principal, orderId) {
    const order = this.store.orders.get(orderId);
    if (!order || order.customerId !== principal.customerId) {
      throw new OrderError('order not found', 404, 'not_found');
    }
    return order;
  }

  /**
   * Apply an authoritative paid event. Idempotent: a duplicate event does not
   * issue a second license.
   * @param {any} order
   * @param {any} event
   */
  markPaid(order, event) {
    this.assertEventMatchesOrder(order, event);
    if (order.status === 'paid') {
      return { order, license: order.licenseId ? this.store.licenses.get(order.licenseId) : null, duplicate: true };
    }
    order.status = 'paid';
    order.paidAtMs = this.now();
    order.updatedAtMs = this.now();
    order.events.push({ type: event.type, atMs: this.now(), eventId: event.id });
    const { license, activationCode } = this.licensing.createLicenseForPaidOrder(order);
    this.audit.record({
      action: 'order.paid',
      actorType: 'provider',
      actorId: event.data?.provider ?? 'mock',
      targetType: 'order',
      targetId: order.id,
      details: { licenseId: license.id, amount: order.amount, currency: order.currency },
    });
    const customer = this.store.customers.get(order.customerId);
    if (customer) {
      void this.notifier.notify({
        to: customer.emailNormalized,
        subject: 'تم تأكيد اشتراكك في موقع',
        body: `تم تأكيد الدفع وإصدار رخصتك. رمز التفعيل: ${activationCode}`,
        template: 'order-paid',
        meta: { orderId: order.id, licenseId: license.id },
      });
    }
    this.store.touch();
    return { order, license, activationCode, duplicate: false };
  }

  /** @param {any} order @param {any} event */
  markFailed(order, event) {
    this.assertEventMatchesOrder(order, event);
    if (order.status !== 'paid') {
      order.status = 'failed';
      order.updatedAtMs = this.now();
      order.events.push({ type: event.type, atMs: this.now(), eventId: event.id });
      this.audit.record({
        action: 'order.failed',
        actorType: 'provider',
        actorId: event.data?.provider ?? 'mock',
        targetType: 'order',
        targetId: order.id,
        details: { reason: event.data?.reason ?? null },
      });
      this.store.touch();
    }
    return order;
  }

  /** @param {any} order @param {any} event */
  markRefunded(order, event) {
    this.assertEventMatchesOrder(order, event);
    order.status = 'refunded';
    order.updatedAtMs = this.now();
    order.events.push({ type: event.type, atMs: this.now(), eventId: event.id });
    if (order.licenseId) {
      this.licensing.revoke(order.licenseId, {
        actorType: 'provider',
        actorId: event.data?.provider ?? 'mock',
        reason: 'refunded',
      });
    }
    this.audit.record({
      action: 'order.refunded',
      actorType: 'provider',
      actorId: event.data?.provider ?? 'mock',
      targetType: 'order',
      targetId: order.id,
      details: { licenseId: order.licenseId },
    });
    this.store.touch();
    return order;
  }

  /** @param {any} order @param {any} event */
  assertEventMatchesOrder(order, event) {
    const data = event?.data ?? {};
    if (data.orderId !== order.id) {
      throw new OrderError('webhook order does not match', 409, 'order_mismatch');
    }
    if (data.amount !== order.amount || data.currency !== order.currency) {
      throw new OrderError('webhook amount/currency does not match the order', 409, 'amount_mismatch');
    }
  }
}
