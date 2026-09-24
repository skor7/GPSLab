// @ts-check
/**
 * In-memory fixed-window rate limiter. Suitable for a single local/staging
 * process; a multi-instance production deployment would use a shared store.
 */
export class RateLimiter {
  /** @param {{windowMs: number, max: number, now?: () => number}} options */
  constructor({ windowMs, max, now = Date.now }) {
    this.windowMs = windowMs;
    this.max = max;
    this.now = now;
    /** @type {Map<string, {count: number, resetAtMs: number}>} */
    this.buckets = new Map();
  }

  /**
   * @param {string} key
   * @param {{windowMs?: number, max?: number}} [override]
   * @returns {{allowed: boolean, remaining: number, retryAfterMs: number}}
   */
  hit(key, override = {}) {
    const windowMs = override.windowMs ?? this.windowMs;
    const max = override.max ?? this.max;
    const nowMs = this.now();
    const bucket = this.buckets.get(key);
    if (!bucket || bucket.resetAtMs <= nowMs) {
      this.buckets.set(key, { count: 1, resetAtMs: nowMs + windowMs });
      return { allowed: true, remaining: Math.max(0, max - 1), retryAfterMs: 0 };
    }
    bucket.count += 1;
    if (bucket.count > max) {
      return { allowed: false, remaining: 0, retryAfterMs: Math.max(0, bucket.resetAtMs - nowMs) };
    }
    return { allowed: true, remaining: Math.max(0, max - bucket.count), retryAfterMs: 0 };
  }

  /** Drop expired buckets (best-effort housekeeping). */
  sweep() {
    const nowMs = this.now();
    for (const [key, bucket] of this.buckets) {
      if (bucket.resetAtMs <= nowMs) this.buckets.delete(key);
    }
  }
}

/** @param {import('node:http').IncomingMessage} req */
export function clientIp(req) {
  const forwarded = req.headers['x-forwarded-for'];
  const value = Array.isArray(forwarded) ? forwarded[0] : forwarded;
  if (typeof value === 'string' && value.length > 0) {
    return value.split(',')[0].trim();
  }
  return req.socket?.remoteAddress ?? 'unknown';
}
