// @ts-check
/**
 * Mawqie-Web application: service wiring + HTTP routing.
 *
 * `createApp` is pure with respect to the network: it returns a `handle`
 * function that can be driven directly by tests or mounted on an http.Server.
 * Production-only routes (mock payments) are never registered in production.
 */
import { assertProductionReady, loadConfig } from './config.js';
import { Store } from './store/store.js';
import { AuditLog } from './audit.js';
import { AccountService } from './accounts.js';
import { AdminService } from './admin.js';
import { TicketService, TICKET_CATEGORIES, TICKET_STATUSES } from './tickets.js';
import { OrderService } from './orders.js';
import { PlanCatalog, defaultPlanCatalog } from './plans.js';
import { claimTrial, TRIAL_REASON_MESSAGES } from './trials.js';
import { LicensingService } from './licensing/service.js';
import { LocalLicenseIssuer } from './licensing/issuer.js';
import { RemoteLicenseIssuer } from './licensing/adapter.js';
import { loadKeyMaterial } from './licensing/signing.js';
import { MockPaymentProvider } from './payments/mock-provider.js';
import { parseWebhookEvent, signWebhook, SIGNATURE_HEADER, verifyWebhookSignature } from './payments/webhook.js';
import { Notifier, createChannels } from './notifications/channels.js';
import { assertCsrf, ensureCsrfToken } from './http/csrf.js';
import { parseCookies, serializeCookie, clearCookie } from './http/cookies.js';
import { parseFormBody, parseJsonBody, readRawBody } from './http/body.js';
import { enforceHttps, securityHeaders } from './http/security.js';
import { clientIp, RateLimiter } from './http/ratelimit.js';
import { redirect, sendHtml, sendJson } from './http/respond.js';
import { validateObject, ValidationError, field } from './core/validation.js';
import { LANGS, DEFAULT_LANG, escapeHtml, renderPage } from './views/layout.js';
import { adminDashboardBody, adminLoginBody } from './views/admin-views.js';
import * as pages from './views/pages.js';
import { APP_CSS, APP_JS } from './views/assets.js';

const SESSION_COOKIE = 'mawqie_session';
const ADMIN_COOKIE = 'mawqie_admin';
const MAX_BODY_BYTES = 64 * 1024;

export class HttpError extends Error {
  /** @param {string} message @param {number} [status] @param {string} [code] */
  constructor(message, status = 400, code = 'http_error') {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
  }
}

/**
 * @param {object} [options]
 * @param {import('./config.js').MawqieConfig} [options.config]
 * @param {Store} [options.store]
 * @param {() => number} [options.now]
 * @param {PlanCatalog} [options.plans]
 * @param {(entry: any) => void} [options.notifySink]
 */
export function createApp(options = {}) {
  const config = options.config ?? loadConfig(process.env);
  // Fail closed even when a config object is supplied directly: production must
  // not start on the staging-only store/provider/license components.
  assertProductionReady(config);
  const store = options.store ?? new Store({ dataFile: config.dataFile });
  const now = options.now ?? (() => Date.now());
  const plans = options.plans ?? defaultPlanCatalog();

  const audit = new AuditLog({ store, now });
  const accounts = new AccountService({ store, now });
  const admin = new AdminService({ store, config, now, audit });
  const channels = createChannels({ config, sink: options.notifySink });
  const notifier = new Notifier({ store, now, channels });

  /** @type {LocalLicenseIssuer | RemoteLicenseIssuer} */
  let issuer;
  if (config.licenseMode === 'remote') {
    const remote = new RemoteLicenseIssuer({ config });
    // When the host app's embedded key is pinned, verify remote envelopes against
    // it before they are returned (bad signature = hard failure). A malformed pin
    // throws here so startup fails closed.
    if (config.licenseExpectedPublicKey) remote.setPublicKeyBase64(config.licenseExpectedPublicKey);
    issuer = remote;
  } else {
    issuer = new LocalLicenseIssuer({ config, keyMaterial: loadKeyMaterial(config), now });
  }
  const licensing = new LicensingService({ config, store, plans, issuer, now, audit });
  const provider = new MockPaymentProvider({ store, now });
  const orders = new OrderService({ store, plans, now, provider, licensing, audit, notifier });
  const tickets = new TicketService({ store, now, audit, notifier });

  const limiter = new RateLimiter({ windowMs: config.rateLimitWindowMs, max: config.rateLimitMax, now });

  const services = { audit, accounts, admin, tickets, orders, licensing, provider, notifier, plans, store, config };

  /** @type {Array<{method: string, path: string | RegExp, handler: (ctx: any) => Promise<void> | void}>} */
  const routes = [];
  /** @param {string} method @param {string | RegExp} path @param {(ctx: any) => any} handler */
  const route = (method, path, handler) => routes.push({ method, path, handler });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /** @param {import('node:http').ServerResponse} res @param {string} header */
  function appendCookie(res, header) {
    const current = res.getHeader('set-cookie');
    const list = Array.isArray(current) ? current : current ? [String(current)] : [];
    list.push(header);
    res.setHeader('set-cookie', list);
  }

  /** @param {import('node:http').IncomingMessage} req @param {string} name */
  function cookieValue(req, name) {
    return parseCookies(req.headers.cookie)[name] ?? null;
  }

  /** @param {import('node:http').ServerResponse} res @param {string} token @param {import('./config.js').MawqieConfig} config */
  function setSessionCookie(res, token, maxAgeSeconds = 30 * 24 * 60 * 60) {
    appendCookie(res, serializeCookie(SESSION_COOKIE, token, { secure: config.cookieSecure, sameSite: 'Lax', maxAgeSeconds }));
  }

  /** @param {any} ctx */
  function currentCustomer(ctx) {
    const token = cookieValue(ctx.req, SESSION_COOKIE);
    return accounts.resolveSession(token);
  }

  /** @param {any} ctx */
  function currentAdmin(ctx) {
    const token = cookieValue(ctx.req, ADMIN_COOKIE);
    return admin.resolveSession(token);
  }

  /** @param {any} ctx */
  function requireCustomer(ctx) {
    const resolved = currentCustomer(ctx);
    if (!resolved) throw new HttpError('authentication required', 401, 'unauthenticated');
    return resolved;
  }

  /** @param {any} ctx */
  function requireAdmin(ctx) {
    const resolved = currentAdmin(ctx);
    if (!resolved) throw new HttpError('admin authentication required', 401, 'unauthenticated');
    return resolved;
  }

  /**
   * @param {any} ctx
   * @param {{max?: number, windowMs?: number, bucket?: string, byEmail?: string}} [options]
   */
  function rateLimit(ctx, options = {}) {
    const bucket = options.bucket ?? ctx.pathname;
    const key = `${bucket}:${clientIp(ctx.req)}${options.byEmail ? `:${options.byEmail}` : ''}`;
    const result = limiter.hit(key, { max: options.max, windowMs: options.windowMs });
    if (!result.allowed) {
      ctx.res.setHeader('retry-after', Math.ceil(result.retryAfterMs / 1000));
      throw new HttpError('too many requests', 429, 'rate_limited');
    }
  }

  /**
   * Parse a request body into an object, accepting JSON or form-encoded input.
   * @param {any} ctx
   */
  async function readInput(ctx) {
    if (ctx.input !== undefined) return ctx.input;
    const raw = await readRawBody(ctx.req, MAX_BODY_BYTES);
    ctx.rawBody = raw;
    const contentType = String(ctx.req.headers['content-type'] || '');
    let data;
    if (contentType.includes('application/json')) {
      data = parseJsonBody(raw);
    } else if (contentType.includes('application/x-www-form-urlencoded') || contentType.includes('multipart/form-data')) {
      data = parseFormBody(raw);
    } else if (raw.trim().startsWith('{')) {
      data = parseJsonBody(raw);
    } else {
      data = parseFormBody(raw);
    }
    ctx.input = data;
    return data;
  }

  /** @param {any} ctx */
  async function readAndCheckCsrf(ctx) {
    const data = await readInput(ctx);
    assertCsrf(ctx.req, { form: data });
    return data;
  }

  /** @param {string} template @param {any} options */
  function render(template, options) {
    return renderPage({ lang: options.lang, isProduction: config.isProduction, ...template, ...options });
  }

  /**
   * @param {any} ctx
   * @param {{title: string, active: string, body: string}} page
   * @param {number} [status]
   */
  function html(ctx, page, status = 200) {
    const csrfToken = ensureCsrfToken(ctx.req, ctx.res, config);
    const customer = currentCustomer(ctx);
    sendHtml(ctx.res, status, renderPage({
      lang: ctx.lang,
      title: page.title,
      active: page.active,
      body: page.body,
      csrfToken,
      user: customer ? { email: customer.customer.emailNormalized } : null,
      isProduction: config.isProduction,
      currentPath: ctx.pathname,
      notice: ctx.notice ?? '',
      error: ctx.error ?? '',
    }));
  }

  // ---------------------------------------------------------------------------
  // Page routes
  // ---------------------------------------------------------------------------

  route('GET', '/', (ctx) => html(ctx, pages.homePage({ lang: ctx.lang, user: currentCustomer(ctx) })));
  route('GET', '/pricing', (ctx) => html(ctx, pages.pricingPage({ lang: ctx.lang, plans: plans.active() })));
  route('GET', '/purchase', (ctx) => {
    const customer = currentCustomer(ctx);
    html(ctx, pages.purchasePage({
      lang: ctx.lang,
      plans: plans.active(),
      user: customer ? { email: customer.customer.emailNormalized } : null,
      csrfToken: ensureCsrfToken(ctx.req, ctx.res, config),
      isProduction: config.isProduction,
    }));
  });
  route('GET', '/trial', (ctx) => html(ctx, pages.trialPage({ lang: ctx.lang, csrfToken: ensureCsrfToken(ctx.req, ctx.res, config) })));
  route('GET', '/activation', (ctx) => html(ctx, pages.activationPage({
    lang: ctx.lang,
    csrfToken: ensureCsrfToken(ctx.req, ctx.res, config),
    publicKey: licensing.publicKeyBase64(),
  })));
  route('GET', '/how-to-use', (ctx) => html(ctx, pages.howToPage({ lang: ctx.lang })));
  route('GET', '/faq', (ctx) => html(ctx, pages.faqPage({ lang: ctx.lang })));
  route('GET', '/contact', (ctx) => html(ctx, pages.contactPage({ lang: ctx.lang, csrfToken: ensureCsrfToken(ctx.req, ctx.res, config), user: currentCustomer(ctx)?.customer ?? null })));
  route('GET', '/feedback', (ctx) => html(ctx, pages.feedbackPage({ lang: ctx.lang, csrfToken: ensureCsrfToken(ctx.req, ctx.res, config), user: currentCustomer(ctx)?.customer ?? null })));
  route('GET', '/privacy', (ctx) => html(ctx, pages.privacyPage({ lang: ctx.lang })));
  route('GET', '/terms', (ctx) => html(ctx, pages.termsPage({ lang: ctx.lang })));
  route('GET', '/login', (ctx) => html(ctx, pages.loginPage({ lang: ctx.lang, csrfToken: ensureCsrfToken(ctx.req, ctx.res, config), mode: 'login' })));
  route('GET', '/signup', (ctx) => html(ctx, pages.loginPage({ lang: ctx.lang, csrfToken: ensureCsrfToken(ctx.req, ctx.res, config), mode: 'signup' })));

  route('GET', '/account', (ctx) => {
    const resolved = currentCustomer(ctx);
    if (!resolved) {
      redirect(ctx.res, `/login?lang=${ctx.lang}`, 302);
      return;
    }
    const customer = resolved.customer;
    const customerOrders = orders.listForCustomer(customer.id);
    const customerLicenses = licensing.listForCustomer(customer.id).map((license) => ({
      ...license,
      activationCodes: licensing.listActivationCodes(license.id).map((record) => record.code),
    }));
    const customerTickets = tickets.listForCustomer(customer.id);
    html(ctx, pages.accountPage({
      lang: ctx.lang,
      csrfToken: ensureCsrfToken(ctx.req, ctx.res, config),
      user: { email: customer.emailNormalized },
      orders: customerOrders,
      licenses: customerLicenses,
      tickets: customerTickets,
      isProduction: config.isProduction,
    }));
  });

  route('GET', '/admin/login', (ctx) => {
    if (currentAdmin(ctx)) {
      redirect(ctx.res, '/admin', 302);
      return;
    }
    html(ctx, {
      title: ctx.lang === 'en' ? 'Admin sign in' : 'دخول الإدارة',
      active: '',
      body: adminLoginBody({ lang: ctx.lang, csrfToken: ensureCsrfToken(ctx.req, ctx.res, config) }),
    });
  });

  route('GET', '/admin', (ctx) => {
    if (!currentAdmin(ctx)) {
      redirect(ctx.res, '/admin/login', 302);
      return;
    }
    html(ctx, {
      title: ctx.lang === 'en' ? 'Admin dashboard' : 'لوحة الإدارة',
      active: '',
      body: adminDashboardBody({ lang: ctx.lang, csrfToken: ensureCsrfToken(ctx.req, ctx.res, config), summary: admin.summary(), audit: audit.list({ limit: 100 }) }),
    });
  });

  // ---------------------------------------------------------------------------
  // Static assets + health + csrf
  // ---------------------------------------------------------------------------

  route('GET', '/assets/app.css', (ctx) => {
    ctx.res.writeHead(200, { 'content-type': 'text/css; charset=utf-8', 'cache-control': 'public, max-age=300' });
    ctx.res.end(APP_CSS);
  });
  route('GET', '/assets/app.js', (ctx) => {
    ctx.res.writeHead(200, { 'content-type': 'application/javascript; charset=utf-8', 'cache-control': 'public, max-age=300' });
    ctx.res.end(APP_JS);
  });
  route('GET', '/healthz', (ctx) => sendJson(ctx.res, 200, { status: 'ok' }));
  route('GET', '/api/csrf', (ctx) => {
    const token = ensureCsrfToken(ctx.req, ctx.res, config);
    sendJson(ctx.res, 200, { token });
  });
  route('GET', '/api/license/public-key', (ctx) => sendJson(ctx.res, 200, {
    alg: 'ES256',
    publicKey: licensing.publicKeyBase64(),
    issuer: config.licenseIssuer,
    audience: config.licenseAudience,
    ephemeral: licensing.isEphemeralKey(),
  }));

  // ---------------------------------------------------------------------------
  // Auth API
  // ---------------------------------------------------------------------------

  route('POST', '/api/auth/signup', async (ctx) => {
    rateLimit(ctx, { bucket: 'auth', max: 10, windowMs: 60_000 });
    const data = await readAndCheckCsrf(ctx);
    const input = validateObject({
      email: field.email(),
      password: field.string({ min: 8, max: 200, label: 'password' }),
      displayName: field.optionalString({ max: 120, label: 'name' }),
    }, data);
    const customer = accounts.signup(input);
    const { token } = accounts.createSession(customer.id);
    setSessionCookie(ctx.res, token);
    audit.record({ action: 'customer.signup', actorType: 'customer', actorId: customer.id, targetType: 'customer', targetId: customer.id, ip: clientIp(ctx.req) });
    sendJson(ctx.res, 201, { message: 'account created', customerId: customer.id });
  });

  route('POST', '/api/auth/login', async (ctx) => {
    rateLimit(ctx, { bucket: 'auth', max: 10, windowMs: 60_000 });
    const data = await readAndCheckCsrf(ctx);
    const input = validateObject({ email: field.email(), password: field.string({ min: 1, max: 200, label: 'password' }) }, data);
    const customer = accounts.login(input);
    const { token } = accounts.createSession(customer.id);
    setSessionCookie(ctx.res, token);
    audit.record({ action: 'customer.login', actorType: 'customer', actorId: customer.id, targetType: 'customer', targetId: customer.id, ip: clientIp(ctx.req) });
    sendJson(ctx.res, 200, { message: 'signed in', customerId: customer.id });
  });

  route('POST', '/api/auth/logout', async (ctx) => {
    await readAndCheckCsrf(ctx);
    accounts.destroySession(cookieValue(ctx.req, SESSION_COOKIE));
    appendCookie(ctx.res, clearCookie(SESSION_COOKIE, { secure: config.cookieSecure }));
    sendJson(ctx.res, 200, { message: 'signed out' });
  });

  route('GET', '/api/account/summary', (ctx) => {
    const { customer } = requireCustomer(ctx);
    sendJson(ctx.res, 200, {
      customer: { id: customer.id, email: customer.emailNormalized, displayName: customer.displayName },
      orders: orders.listForCustomer(customer.id).map((order) => ({ id: order.id, planId: order.planId, amount: order.amount, currency: order.currency, status: order.status, licenseId: order.licenseId })),
      licenses: licensing.listForCustomer(customer.id).map((license) => ({ id: license.id, planId: license.planId, status: license.status, expiresAtMs: license.expiresAtMs, installations: license.installations })),
      tickets: tickets.listForCustomer(customer.id).map((ticket) => ({ id: ticket.id, type: ticket.type, subject: ticket.subject, status: ticket.status })),
    });
  });

  // ---------------------------------------------------------------------------
  // Trial + orders + tickets + license
  // ---------------------------------------------------------------------------

  route('POST', '/api/trial', async (ctx) => {
    const data = await readAndCheckCsrf(ctx);
    const input = validateObject({
      email: field.email(),
      installationId: field.uuid({ label: 'installation id' }),
      planId: field.optionalString({ max: 64, label: 'plan' }),
    }, data);
    // Bind the trial to the authenticated account: a signed-in customer may only
    // claim against their own email. This stops account A from starting a trial
    // against an arbitrary email B.
    const resolved = currentCustomer(ctx);
    let email = input.email;
    if (resolved) {
      const accountEmail = resolved.customer.emailNormalized;
      if (email !== accountEmail) {
        throw new HttpError(TRIAL_REASON_MESSAGES.email_mismatch, 403, 'email_mismatch');
      }
      email = accountEmail;
    }
    rateLimit(ctx, { bucket: 'trial', max: 5, windowMs: 3_600_000, byEmail: email });
    const planId = input.planId || (plans.trialEligible()[0]?.id ?? 'trial');
    const result = claimTrial({
      store,
      plans,
      licensing,
      planId,
      email,
      installationId: input.installationId,
      customerId: resolved?.customer.id ?? null,
      ip: clientIp(ctx.req),
    });
    sendJson(ctx.res, 201, {
      // Arabic-first result. The activation code is returned as its own field
      // (the page's progressive-enhancement JS appends it), and the account page
      // lists it too, so a signed-in customer always has a usable result.
      message: 'تم تفعيل التجربة المجانية.',
      licenseId: result.license.id,
      activationCode: result.activationCode,
      envelope: result.envelope,
    });
  });

  route('POST', '/api/orders', async (ctx) => {
    const { customer } = requireCustomer(ctx);
    const data = await readAndCheckCsrf(ctx);
    rateLimit(ctx, { bucket: 'orders', max: 20, windowMs: 60_000 });
    const input = validateObject({ planId: field.string({ min: 1, max: 64, label: 'plan' }) }, data);
    const { order, intent } = orders.createOrder({ customerId: customer.id, planId: input.planId, ip: clientIp(ctx.req) });
    sendJson(ctx.res, 201, {
      message: 'order created',
      orderId: order.id,
      status: order.status,
      checkout: { provider: provider.name, intentId: intent.id, amount: order.amount, currency: order.currency },
    });
  });

  route('POST', '/api/tickets', async (ctx) => {
    const data = await readAndCheckCsrf(ctx);
    const input = validateObject({
      category: field.enum(TICKET_CATEGORIES, { label: 'category' }),
      name: field.string({ min: 1, max: 120, label: 'name' }),
      email: field.email(),
      subject: field.string({ min: 1, max: 160, label: 'subject' }),
      message: field.string({ min: 1, max: 4000, label: 'message' }),
    }, data);
    rateLimit(ctx, { bucket: 'tickets', max: 5, windowMs: 60_000, byEmail: input.email });
    const resolved = currentCustomer(ctx);
    const ticket = tickets.create({
      category: input.category,
      name: input.name,
      email: input.email,
      subject: input.subject,
      message: input.message,
      customerId: resolved?.customer.id ?? null,
      ip: clientIp(ctx.req),
    });
    sendJson(ctx.res, 201, { message: 'ticket created', ticketId: ticket.id, status: ticket.status });
  });

  /**
   * GPSLab license endpoint. The Objective-C client POSTs
   * `{ installationId, refreshToken?, activationCode? }` and expects the signed
   * envelope back (see `Source/GPSLabLicenseManager.m`). The same handler is
   * mounted at the portal path and at the client's built-in path so a build
   * pointed at this portal works without changing client semantics.
   * @param {any} ctx
   */
  async function handleLicenseRequest(ctx) {
    rateLimit(ctx, { bucket: 'license', max: 30, windowMs: 60_000 });
    const data = await readInput(ctx);
    const input = validateObject({
      installationId: field.uuid({ label: 'installation id', lowercase: false }),
      activationCode: field.optionalString({ max: 200, label: 'activation code' }),
      refreshToken: field.optionalString({ max: 500, label: 'refresh token' }),
    }, data);
    const ip = clientIp(ctx.req);

    if (licensing.isRemote()) {
      const envelope = await licensing.forwardRemote({
        installationId: input.installationId,
        activationCode: input.activationCode || undefined,
        refreshToken: input.refreshToken || undefined,
      });
      sendJson(ctx.res, 200, envelope);
      return;
    }

    let result = null;
    if (input.activationCode) {
      result = licensing.redeemActivation({ code: input.activationCode, installationId: input.installationId, ip });
    } else if (input.refreshToken) {
      result = licensing.refreshByToken({ refreshToken: input.refreshToken, installationId: input.installationId });
    } else {
      result = licensing.lookupByInstallation(input.installationId);
    }
    if (!result) {
      sendJson(ctx.res, 404, { error: 'no license for this installation', code: 'not_found' });
      return;
    }
    // Return the exact signed envelope GPSLab expects.
    sendJson(ctx.res, 200, result.envelope);
  }

  route('POST', '/api/license', handleLicenseRequest);
  // Compatibility alias for `GPSLAB_LICENSE_BUILD_ENDPOINT`
  // (`/api/v1/license/check` in Source/GPSLabLicenseBuildConfig.h).
  route('POST', '/api/v1/license/check', handleLicenseRequest);

  // ---------------------------------------------------------------------------
  // Payment webhook (authoritative) + dev-only mock payment route
  // ---------------------------------------------------------------------------

  /**
   * @param {string} rawBody
   * @param {string} signature
   */
  function processWebhook(rawBody, signature) {
    if (!verifyWebhookSignature(rawBody, signature, config.webhookSecret)) {
      audit.record({ action: 'webhook.signature_rejected', actorType: 'provider', targetType: 'webhook' });
      throw new HttpError('invalid webhook signature', 401, 'invalid_signature');
    }
    const event = parseWebhookEvent(rawBody);
    if (!event) throw new HttpError('invalid webhook payload', 400, 'invalid_payload');
    const orderId = event.data?.orderId;
    const order = typeof orderId === 'string' ? orders.getOrder(orderId) : null;
    if (!order) throw new HttpError('unknown order', 404, 'unknown_order');
    switch (event.type) {
      case 'payment.succeeded':
        return orders.markPaid(order, event);
      case 'payment.failed':
        return orders.markFailed(order, event);
      case 'payment.refunded':
        return orders.markRefunded(order, event);
      default:
        throw new HttpError(`unhandled event type: ${event.type}`, 400, 'unhandled_event');
    }
  }

  /**
   * Provider-neutral payment webhook. Signature-verified in every environment.
   * @param {any} ctx
   */
  async function handlePaymentWebhook(ctx) {
    rateLimit(ctx, { bucket: 'webhook', max: 120, windowMs: 60_000 });
    const raw = await readRawBody(ctx.req, MAX_BODY_BYTES);
    ctx.rawBody = raw;
    const signatureHeader = ctx.req.headers[SIGNATURE_HEADER];
    const signature = Array.isArray(signatureHeader) ? signatureHeader[0] : signatureHeader;
    const result = processWebhook(raw, signature || '');
    sendJson(ctx.res, 200, { received: true, duplicate: Boolean(result?.duplicate) });
  }

  // Canonical webhook path (all environments). A real provider can post here.
  route('POST', '/webhooks/payment', handlePaymentWebhook);

  if (!config.isProduction && config.allowMockPayments) {
    // Dev/staging-only alias for the mock provider. It is deliberately NOT
    // registered in production, so production has no "mock" payment surface.
    route('POST', '/webhooks/payment/mock', handlePaymentWebhook);

    route('POST', '/api/mock/pay', async (ctx) => {
      const { customer } = requireCustomer(ctx);
      const data = await readAndCheckCsrf(ctx);
      rateLimit(ctx, { bucket: 'mock-pay', max: 30, windowMs: 60_000 });
      const input = validateObject({ orderId: field.string({ min: 1, max: 64, label: 'order' }) }, data);
      const order = orders.getForCustomer({ customerId: customer.id }, input.orderId);
      if (!order.providerRef) throw new HttpError('order has no payment intent', 409, 'no_intent');
      const event = provider.simulatePay(order.providerRef);
      const raw = JSON.stringify(event);
      // Route the mock outcome through the SAME signature-verified webhook path.
      const signature = signWebhook(raw, config.webhookSecret);
      processWebhook(raw, signature);
      sendJson(ctx.res, 200, { message: 'mock payment completed', orderId: order.id });
    });
  }

  // ---------------------------------------------------------------------------
  // Admin API
  // ---------------------------------------------------------------------------

  route('POST', '/admin/login', async (ctx) => {
    rateLimit(ctx, { bucket: 'admin-login', max: 10, windowMs: 60_000 });
    const data = await readAndCheckCsrf(ctx);
    const input = validateObject({ email: field.email(), password: field.string({ min: 1, max: 200, label: 'password' }) }, data);
    const { token } = admin.login({ email: input.email, password: input.password, ip: clientIp(ctx.req) });
    appendCookie(ctx.res, serializeCookie(ADMIN_COOKIE, token, { secure: config.cookieSecure, sameSite: 'Strict', maxAgeSeconds: 12 * 60 * 60 }));
    redirect(ctx.res, '/admin', 303);
  });

  route('POST', '/admin/logout', async (ctx) => {
    await readAndCheckCsrf(ctx);
    admin.logout(cookieValue(ctx.req, ADMIN_COOKIE));
    appendCookie(ctx.res, clearCookie(ADMIN_COOKIE, { secure: config.cookieSecure }));
    redirect(ctx.res, '/admin/login', 303);
  });

  route('GET', '/api/admin/summary', (ctx) => {
    requireAdmin(ctx);
    sendJson(ctx.res, 200, admin.summary());
  });

  route('GET', '/api/admin/audit', (ctx) => {
    requireAdmin(ctx);
    sendJson(ctx.res, 200, { entries: audit.list({ limit: 200 }) });
  });

  route('POST', /^\/api\/admin\/licenses\/([^/]+)\/revoke$/, async (ctx) => {
    const { admin: adminPrincipal } = requireAdmin(ctx);
    const data = await readAndCheckCsrf(ctx);
    const input = validateObject({ reason: field.optionalString({ max: 300, label: 'reason' }) }, data);
    const license = await licensing.revokeLicense(ctx.params[0], { actorType: 'admin', actorId: adminPrincipal.email, reason: input.reason || 'admin action' });
    // Local mode returns the license record; a remote backend returns its own JSON
    // acknowledgement, which may not carry `id`/`status` fields.
    sendJson(ctx.res, 200, {
      message: 'license revoked',
      licenseId: license.id ?? ctx.params[0],
      status: license.status ?? 'revoked',
    });
  });

  route('POST', /^\/api\/admin\/tickets\/([^/]+)\/status$/, async (ctx) => {
    const { admin: adminPrincipal } = requireAdmin(ctx);
    const data = await readAndCheckCsrf(ctx);
    const input = validateObject({ status: field.enum(TICKET_STATUSES, { label: 'status' }) }, data);
    const ticket = tickets.updateStatus(ctx.params[0], input.status, { actorType: 'admin', actorId: adminPrincipal.email });
    sendJson(ctx.res, 200, { message: 'ticket updated', ticketId: ticket.id, status: ticket.status });
  });

  // ---------------------------------------------------------------------------
  // Request dispatch
  // ---------------------------------------------------------------------------

  /** @param {import('node:http').IncomingMessage} req */
  function resolveLang(req, url) {
    const requested = url.searchParams.get('lang');
    if (requested && LANGS.includes(/** @type {any} */ (requested))) return requested;
    return DEFAULT_LANG;
  }

  /**
   * @param {import('node:http').IncomingMessage} req
   * @param {import('node:http').ServerResponse} res
   */
  async function handle(req, res) {
    for (const [name, value] of Object.entries(securityHeaders(config))) {
      res.setHeader(name, value);
    }
    if (enforceHttps(req, res, config)) return;

    const url = new URL(req.url || '/', config.baseUrl);
    const pathname = url.pathname;
    const lang = resolveLang(req, url);
    const acceptsHtml = !pathname.startsWith('/api') && !pathname.startsWith('/webhooks');

    try {
      for (const candidate of routes) {
        if (candidate.method !== req.method) continue;
        let params = null;
        if (typeof candidate.path === 'string') {
          if (candidate.path !== pathname) continue;
        } else {
          const match = candidate.path.exec(pathname);
          if (!match) continue;
          params = match.slice(1);
        }
        /** @type {any} */
        const ctx = { req, res, url, pathname, lang, params: params ?? [], notice: '', error: '' };
        await candidate.handler(ctx);
        return;
      }
      // No route matched.
      if (acceptsHtml) {
        const page = pages.notFoundPage({ lang });
        const csrfToken = ensureCsrfToken(req, res, config);
        const customer = currentCustomer({ req, res });
        sendHtml(res, 404, renderPage({
          lang,
          title: page.title,
          active: page.active,
          body: page.body,
          csrfToken,
          user: customer ? { email: customer.customer.emailNormalized } : null,
          isProduction: config.isProduction,
        }));
      } else {
        sendJson(res, 404, { error: 'not found', code: 'not_found' });
      }
    } catch (error) {
      handleError(res, error, acceptsHtml, lang);
    }
  }

  /**
   * @param {import('node:http').ServerResponse} res
   * @param {unknown} error
   * @param {boolean} acceptsHtml
   * @param {string} lang
   */
  function handleError(res, error, acceptsHtml, lang) {
    if (res.headersSent || res.writableEnded) return;
    const err = /** @type {any} */ (error);
    const status = typeof err?.status === 'number' ? err.status : 500;
    const code = typeof err?.code === 'string' ? err.code : 'internal_error';
    const message = status >= 500 ? 'internal server error' : (err?.message || 'request failed');
    const payload = { error: message, code };
    if (error instanceof ValidationError) {
      payload.fields = error.errors;
      payload.error = 'validation failed';
    }
    if (status >= 500) {
      // Log the error type only; never echo internals to the client.
      // eslint-disable-next-line no-console
      console.error(`[mawqie] request error: ${err?.name || 'Error'}`);
    }
    if (acceptsHtml) {
      sendHtml(res, status, `<!DOCTYPE html><html lang="${lang}" dir="${lang === 'en' ? 'ltr' : 'rtl'}"><meta charset="utf-8"><title>Error</title><body data-code="${escapeHtml(code)}" style="background:#111116;color:#f5f5f7;font-family:system-ui;padding:40px"><h1>${status}</h1><p>${escapeHtml(message)}</p><p><a style="color:#c9b4ff" href="/?lang=${lang}">${lang === 'en' ? 'Home' : 'الرئيسية'}</a></p></body></html>`);
    } else {
      sendJson(res, status, payload);
    }
  }

  return {
    handle,
    config,
    store,
    plans,
    services,
    /** Flush any pending persistence (used on shutdown/tests). */
    flush: () => store.flush(),
  };
}
