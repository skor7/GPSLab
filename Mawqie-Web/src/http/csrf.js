// @ts-check
/**
 * CSRF protection via double-submit cookie.
 *
 * Every HTML page ensures a random `mawqie_csrf` cookie exists (readable by the
 * page, not HttpOnly) and embeds the same value in forms / `X-CSRF-Token`. Every
 * state-changing same-site request must present a matching token (header or
 * `_csrf` field), compared in constant time.
 *
 * Webhook and machine-to-machine license endpoints are exempt because they
 * authenticate with a signature/refresh token and do not rely on cookies.
 */
import { newToken, timingSafeEqualStrings } from '../core/ids.js';
import { parseCookies, serializeCookie } from './cookies.js';

export const CSRF_COOKIE = 'mawqie_csrf';
export const CSRF_HEADER = 'x-csrf-token';

export class CsrfError extends Error {
  constructor(message = 'CSRF token missing or invalid', status = 403, code = 'csrf_failed') {
    super(message);
    this.name = 'CsrfError';
    this.status = status;
    this.code = code;
  }
}

/**
 * Ensure a CSRF cookie exists and return its value. Sets a new cookie when
 * absent. The cookie is intentionally NOT HttpOnly (the page must read it).
 * @param {import('node:http').IncomingMessage} req
 * @param {import('node:http').ServerResponse} res
 * @param {import('../config.js').MawqieConfig} config
 */
export function ensureCsrfToken(req, res, config) {
  const cookies = parseCookies(req.headers.cookie);
  const existing = cookies[CSRF_COOKIE];
  if (existing) return existing;
  const token = newToken(24);
  const header = serializeCookie(CSRF_COOKIE, token, {
    httpOnly: false,
    secure: config.cookieSecure,
    sameSite: 'Lax',
    maxAgeSeconds: 60 * 60 * 12,
  });
  const current = res.getHeader('set-cookie');
  const list = Array.isArray(current) ? current : current ? [String(current)] : [];
  list.push(header);
  res.setHeader('set-cookie', list);
  return token;
}

/**
 * Validate a state-changing request against the CSRF cookie.
 * @param {import('node:http').IncomingMessage} req
 * @param {{form?: Record<string, string>}} [parsed]
 */
export function assertCsrf(req, parsed = {}) {
  const cookies = parseCookies(req.headers.cookie);
  const cookieToken = cookies[CSRF_COOKIE];
  const headerValue = req.headers[CSRF_HEADER];
  const headerToken = Array.isArray(headerValue) ? headerValue[0] : headerValue;
  const formToken = parsed.form?._csrf;
  const presented = headerToken || formToken || '';
  if (!cookieToken || !presented || !timingSafeEqualStrings(String(presented), String(cookieToken))) {
    throw new CsrfError();
  }
}
