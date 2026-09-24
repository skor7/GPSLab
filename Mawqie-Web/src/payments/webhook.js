// @ts-check
/**
 * Authoritative server-side webhook signature verification.
 *
 * The server never trusts a payment outcome from the browser. It only acts on a
 * webhook whose raw body carries a valid HMAC-SHA256 signature computed with the
 * server-held `WEBHOOK_SECRET`. Comparison is constant-time.
 */
import crypto from 'node:crypto';
import { timingSafeEqualStrings } from '../core/ids.js';

export const SIGNATURE_HEADER = 'x-mawqie-signature';

/** @param {string} rawBody @param {string} secret */
export function signWebhook(rawBody, secret) {
  return crypto.createHmac('sha256', secret).update(rawBody, 'utf8').digest('hex');
}

/**
 * @param {string} rawBody
 * @param {string | undefined | null} signature
 * @param {string} secret
 */
export function verifyWebhookSignature(rawBody, signature, secret) {
  if (typeof signature !== 'string' || signature.length === 0 || !secret) return false;
  const expected = signWebhook(rawBody, secret);
  // Accept both bare hex and `sha256=<hex>` forms.
  const provided = signature.startsWith('sha256=') ? signature.slice('sha256='.length) : signature;
  return timingSafeEqualStrings(provided.toLowerCase(), expected.toLowerCase());
}

/**
 * Parse and shape-check a webhook event body.
 * @param {string} rawBody
 * @returns {{type: string, data: any} | null}
 */
export function parseWebhookEvent(rawBody) {
  let parsed;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== 'object') return null;
  if (typeof parsed.type !== 'string' || !parsed.data || typeof parsed.data !== 'object') return null;
  return { type: parsed.type, data: parsed.data };
}

export const HANDLED_EVENTS = /** @type {const} */ ([
  'payment.succeeded',
  'payment.failed',
  'payment.refunded',
]);
