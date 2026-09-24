// @ts-check
/** Bounded request-body reading (raw, for signature verification, and parsed). */

export class BodyError extends Error {
  /** @param {string} message @param {number} [status] @param {string} [code] */
  constructor(message, status = 400, code = 'bad_body') {
    super(message);
    this.name = 'BodyError';
    this.status = status;
    this.code = code;
  }
}

const DEFAULT_LIMIT = 64 * 1024;

/**
 * Read the raw request body as a UTF-8 string, enforcing a byte cap while
 * streaming. The raw text is what webhook signatures are computed over.
 * @param {import('node:http').IncomingMessage} req
 * @param {number} [limit]
 * @returns {Promise<string>}
 */
export function readRawBody(req, limit = DEFAULT_LIMIT) {
  return new Promise((resolve, reject) => {
    /** @type {Buffer[]} */
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new BodyError('request body too large', 413, 'body_too_large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', () => reject(new BodyError('could not read request body', 400, 'body_read_error')));
  });
}

/** @param {string} raw */
export function parseJsonBody(raw) {
  if (!raw || !raw.trim()) return {};
  try {
    const parsed = JSON.parse(raw);
    if (parsed === null || typeof parsed !== 'object') {
      throw new BodyError('JSON body must be an object', 400, 'invalid_json');
    }
    return parsed;
  } catch (error) {
    if (error instanceof BodyError) throw error;
    throw new BodyError('request body is not valid JSON', 400, 'invalid_json');
  }
}

/** @param {string} raw */
export function parseFormBody(raw) {
  const params = new URLSearchParams(raw || '');
  /** @type {Record<string, string>} */
  const out = {};
  for (const [key, value] of params.entries()) {
    out[key] = value;
  }
  return out;
}
