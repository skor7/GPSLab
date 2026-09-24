// @ts-check
/**
 * Email normalization used for trial eligibility and account identity.
 *
 * Normalization is deliberately conservative: NFKC unicode fold, trim and
 * lowercase. We intentionally do NOT strip dots or `+suffix` (provider-specific
 * rewriting) because that would create false positives and could deny a trial to
 * a legitimate different mailbox owner.
 */

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** @param {unknown} value */
export function normalizeEmail(value) {
  if (typeof value !== 'string') return '';
  return value.normalize('NFKC').trim().toLowerCase();
}

/** @param {unknown} value */
export function isValidEmail(value) {
  if (typeof value !== 'string') return false;
  const normalized = normalizeEmail(value);
  if (normalized.length < 3 || normalized.length > 254) return false;
  if (!EMAIL_PATTERN.test(normalized)) return false;
  const [local, domain] = normalized.split('@');
  if (!local || local.length > 64) return false;
  if (!domain || domain.length > 253) return false;
  return true;
}

/**
 * A stable, non-reversible key for an email. Used for uniqueness checks and
 * history lookups without exposing the raw address in keys.
 * @param {unknown} value
 */
export function emailKey(value) {
  const normalized = normalizeEmail(value);
  return normalized;
}
