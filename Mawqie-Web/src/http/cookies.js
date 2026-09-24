// @ts-check
/** Cookie parsing and serialization with safe defaults. */

/**
 * @param {string | undefined | null} header
 * @returns {Record<string, string>}
 */
export function parseCookies(header) {
  /** @type {Record<string, string>} */
  const cookies = {};
  if (!header) return cookies;
  for (const part of header.split(';')) {
    const index = part.indexOf('=');
    if (index === -1) continue;
    const name = part.slice(0, index).trim();
    const value = part.slice(index + 1).trim();
    if (!name) continue;
    try {
      cookies[name] = decodeURIComponent(value);
    } catch {
      cookies[name] = value;
    }
  }
  return cookies;
}

/**
 * @param {string} name
 * @param {string} value
 * @param {{maxAgeSeconds?: number, httpOnly?: boolean, secure?: boolean, sameSite?: 'Strict'|'Lax'|'None', path?: string}} [options]
 */
export function serializeCookie(name, value, options = {}) {
  const {
    maxAgeSeconds,
    httpOnly = true,
    secure = true,
    sameSite = 'Lax',
    path = '/',
  } = options;
  const parts = [`${name}=${encodeURIComponent(value)}`, `Path=${path}`, `SameSite=${sameSite}`];
  if (httpOnly) parts.push('HttpOnly');
  if (secure) parts.push('Secure');
  if (typeof maxAgeSeconds === 'number') {
    parts.push(`Max-Age=${Math.floor(maxAgeSeconds)}`);
  }
  return parts.join('; ');
}

/** Build a Set-Cookie header value that clears a cookie. */
export function clearCookie(name, options = {}) {
  return serializeCookie(name, '', { ...options, maxAgeSeconds: 0 });
}
