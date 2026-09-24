// @ts-check
/** Shared test harness: in-process server + cookie/CSRF-aware HTTP client. */
import http from 'node:http';
import { createApp } from '../src/app.js';
import { Store } from '../src/store/store.js';
import { loadConfig } from '../src/config.js';
import { hashPassword } from '../src/core/password.js';
import { signWebhook } from '../src/payments/webhook.js';

export const TEST_ADMIN_EMAIL = 'admin@mawqie.test';
export const TEST_ADMIN_PASSWORD = 'admin-password-123';

/**
 * Build a non-production config with deterministic secrets.
 * @param {Record<string, string | undefined>} [overrides]
 */
export function testConfig(overrides = {}) {
  return loadConfig({
    NODE_ENV: 'test',
    SESSION_SECRET: 'a'.repeat(64),
    WEBHOOK_SECRET: 'b'.repeat(64),
    ADMIN_EMAIL: TEST_ADMIN_EMAIL,
    ADMIN_PASSWORD_HASH: hashPassword(TEST_ADMIN_PASSWORD),
    ALLOW_MOCK_PAYMENTS: '1',
    ...overrides,
  });
}

/**
 * @param {{config?: any, store?: Store, now?: () => number, plans?: any, notifySink?: (entry:any)=>void}} [options]
 */
export async function startServer(options = {}) {
  const config = options.config ?? testConfig();
  const store = options.store ?? new Store();
  const now = options.now ?? (() => Date.now());
  const app = createApp({ config, store, now, plans: options.plans, notifySink: options.notifySink });
  const server = http.createServer((req, res) => {
    app.handle(req, res).catch((error) => {
      if (!res.headersSent) {
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: String(/** @type {Error} */ (error).name) }));
      }
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : 0;
  const baseUrl = `http://127.0.0.1:${port}`;
  return {
    baseUrl,
    store,
    app,
    config,
    services: app.services,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

export class Client {
  /** @param {string} baseUrl @param {{headers?: Record<string,string>}} [options] */
  constructor(baseUrl, options = {}) {
    this.baseUrl = baseUrl;
    this.defaultHeaders = options.headers ?? {};
    /** @type {Map<string, string>} */
    this.cookies = new Map();
  }

  cookieHeader() {
    return [...this.cookies.entries()].map(([name, value]) => `${name}=${value}`).join('; ');
  }

  /** @param {string} setCookie */
  storeCookie(setCookie) {
    const [pair] = setCookie.split(';');
    const index = pair.indexOf('=');
    if (index === -1) return;
    const name = pair.slice(0, index).trim();
    const value = pair.slice(index + 1).trim();
    if (!name) return;
    if (value === '' || /max-age=0/i.test(setCookie)) {
      this.cookies.delete(name);
    } else {
      this.cookies.set(name, value);
    }
  }

  /**
   * @param {string} method
   * @param {string} path
   * @param {{json?: any, form?: Record<string, string>, headers?: Record<string,string>, redirect?: RequestRedirect, raw?: string, contentType?: string}} [options]
   */
  async request(method, path, options = {}) {
    /** @type {Record<string,string>} */
    const headers = { ...this.defaultHeaders, ...(options.headers ?? {}) };
    const cookieHeader = this.cookieHeader();
    if (cookieHeader) headers.cookie = cookieHeader;
    let body;
    if (options.json !== undefined) {
      headers['content-type'] = 'application/json';
      body = JSON.stringify(options.json);
    } else if (options.form !== undefined) {
      headers['content-type'] = 'application/x-www-form-urlencoded';
      body = new URLSearchParams(options.form).toString();
    } else if (options.raw !== undefined) {
      headers['content-type'] = options.contentType ?? 'application/json';
      body = options.raw;
    }
    const response = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers,
      body,
      redirect: options.redirect ?? 'manual',
    });
    const setCookies = typeof response.headers.getSetCookie === 'function' ? response.headers.getSetCookie() : [];
    for (const setCookie of setCookies) this.storeCookie(setCookie);
    const text = await response.text();
    /** @type {any} */
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = text;
    }
    return {
      status: response.status,
      headers: response.headers,
      body: parsed,
      text,
      location: response.headers.get('location'),
      setCookies,
    };
  }

  get(path, options) {
    return this.request('GET', path, options);
  }

  /** Fetch a CSRF token and remember its cookie. */
  async csrf() {
    const response = await this.get('/api/csrf');
    return response.body?.token ?? '';
  }

  /** POST a form/JSON body with a valid CSRF token attached. */
  async post(path, data, options = {}) {
    const token = await this.csrf();
    if (options.json) {
      return this.request('POST', path, { json: { ...data, _csrf: token }, headers: { 'x-csrf-token': token }, redirect: options.redirect });
    }
    return this.request('POST', path, { form: { ...data, _csrf: token }, headers: { 'x-csrf-token': token }, redirect: options.redirect });
  }

  async signup(email, password = 'password-123', displayName = 'Test') {
    return this.post('/api/auth/signup', { email, password, displayName });
  }

  async login(email, password = 'password-123') {
    return this.post('/api/auth/login', { email, password });
  }

  async adminLogin(email = TEST_ADMIN_EMAIL, password = TEST_ADMIN_PASSWORD) {
    return this.post('/admin/login', { email, password });
  }
}

/**
 * Send a signed webhook event to the server.
 * @param {Client} client
 * @param {Record<string, unknown>} event
 * @param {string} secret
 * @param {{signature?: string}} [options]
 */
export async function sendWebhook(client, event, secret, options = {}) {
  const raw = JSON.stringify(event);
  const signature = options.signature ?? signWebhook(raw, secret);
  return client.request('POST', '/webhooks/payment', {
    raw,
    contentType: 'application/json',
    headers: { 'x-mawqie-signature': signature },
  });
}
