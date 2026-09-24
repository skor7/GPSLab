// @ts-check
/**
 * Security headers, HTTPS enforcement and request origin checks.
 *
 * In production the portal refuses to serve a request that is not HTTPS (as
 * observed directly or via a trusted proxy header) and sends HSTS. The CSP has
 * no `unsafe-inline`/`unsafe-eval`; all page assets are same-origin and inlined
 * only as static CSS/JS files under `/assets`.
 */

/** @param {import('../config.js').MawqieConfig} config */
export function securityHeaders(config) {
  /** @type {Record<string, string>} */
  const headers = {
    'content-security-policy': [
      "default-src 'self'",
      "base-uri 'self'",
      "form-action 'self'",
      "frame-ancestors 'none'",
      "img-src 'self' data:",
      "style-src 'self'",
      "script-src 'self'",
      "connect-src 'self'",
      "object-src 'none'",
    ].join('; '),
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'strict-origin-when-cross-origin',
    'cross-origin-opener-policy': 'same-origin',
    'cross-origin-resource-policy': 'same-origin',
    'permissions-policy': 'geolocation=(), microphone=(), camera=()',
    'cache-control': 'no-store',
  };
  if (config.isProduction) {
    headers['strict-transport-security'] = 'max-age=31536000; includeSubDomains';
  }
  return headers;
}

/**
 * @param {import('node:http').IncomingMessage} req
 * @param {import('../config.js').MawqieConfig} config
 */
export function isSecureRequest(req, config) {
  if (config.trustProxy) {
    const forwarded = req.headers['x-forwarded-proto'];
    const value = Array.isArray(forwarded) ? forwarded[0] : forwarded;
    if (typeof value === 'string' && value.split(',')[0].trim().toLowerCase() === 'https') return true;
  }
  // @ts-ignore - `encrypted` exists on TLS sockets.
  return Boolean(req.socket && req.socket.encrypted);
}

/**
 * @param {import('node:http').IncomingMessage} req
 * @param {import('node:http').ServerResponse} res
 * @param {import('../config.js').MawqieConfig} config
 * @returns {boolean} true when the request was rejected/redirected
 */
export function enforceHttps(req, res, config) {
  if (!config.isProduction) return false;
  if (isSecureRequest(req, config)) return false;
  const host = req.headers.host || '';
  const location = `https://${host}${req.url || '/'}`;
  if (req.method === 'GET' || req.method === 'HEAD') {
    res.writeHead(308, { location });
    res.end();
  } else {
    res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('HTTPS is required');
  }
  return true;
}

/**
 * Origin check for state-changing requests (defence in depth alongside CSRF).
 * @param {import('node:http').IncomingMessage} req
 * @param {import('../config.js').MawqieConfig} config
 */
export function isSameOrigin(req, config) {
  const origin = req.headers.origin;
  if (typeof origin !== 'string' || origin === '') return true; // same-origin form posts omit Origin
  try {
    return new URL(origin).host === new URL(config.baseUrl).host;
  } catch {
    return false;
  }
}
