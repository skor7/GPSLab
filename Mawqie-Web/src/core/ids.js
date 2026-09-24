// @ts-check
import crypto from 'node:crypto';

/** @returns {string} a random UUID v4. */
export function newId() {
  return crypto.randomUUID();
}

/**
 * A URL-safe random token. Used for session tokens, CSRF tokens, activation
 * codes and refresh tokens.
 * @param {number} [bytes]
 */
export function newToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('base64url');
}

/** Stable SHA-256 hex digest, used to store tokens/codes hashed at rest. */
export function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

/**
 * Constant-time string comparison that never throws on length mismatch.
 * @param {string} a @param {string} b
 */
export function timingSafeEqualStrings(a, b) {
  const left = Buffer.from(String(a), 'utf8');
  const right = Buffer.from(String(b), 'utf8');
  if (left.length !== right.length) {
    // Still perform a comparison against a same-length buffer to avoid an
    // early-return timing oracle.
    const padded = Buffer.alloc(left.length);
    crypto.timingSafeEqual(left, padded);
    return false;
  }
  return crypto.timingSafeEqual(left, right);
}
