// @ts-check
/** Response helpers. JSON is the API default; HTML is served for pages. */

/**
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {unknown} body
 * @param {Record<string, string | string[]>} [headers]
 */
export function sendJson(res, status, body, headers = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    ...headers,
  });
  res.end(payload);
}

/**
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {string} html
 * @param {Record<string, string | string[]>} [headers]
 */
export function sendHtml(res, status, html, headers = {}) {
  res.writeHead(status, {
    'content-type': 'text/html; charset=utf-8',
    'content-length': Buffer.byteLength(html),
    ...headers,
  });
  res.end(html);
}

/**
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {string} text
 * @param {Record<string, string | string[]>} [headers]
 */
export function sendText(res, status, text, headers = {}) {
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'content-length': Buffer.byteLength(text),
    ...headers,
  });
  res.end(text);
}

/** @param {import('node:http').ServerResponse} res @param {string} location @param {number} [status] */
export function redirect(res, location, status = 303) {
  res.writeHead(status, { location });
  res.end();
}

/** @param {import('node:http').ServerResponse} res @param {number} status */
export function sendEmpty(res, status) {
  res.writeHead(status);
  res.end();
}
