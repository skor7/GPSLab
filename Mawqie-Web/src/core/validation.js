// @ts-check
/**
 * Server-side validation. Every mutation validates on the server; the browser
 * `required`/`pattern` attributes are convenience only and are never trusted.
 */
import { isValidEmail, normalizeEmail } from './email.js';

export class ValidationError extends Error {
  /** @param {Record<string, string>} errors */
  constructor(errors) {
    super('validation failed');
    this.name = 'ValidationError';
    this.status = 400;
    this.code = 'validation_failed';
    /** @type {Record<string, string>} */
    this.errors = errors;
  }
}

/**
 * @param {Record<string, (value: unknown, field: string, input: Record<string, unknown>) => {value?: unknown, error?: string}>} rules
 * @param {unknown} input
 * @returns {Record<string, unknown>}
 */
export function validateObject(rules, input) {
  const source = input && typeof input === 'object' ? /** @type {Record<string, unknown>} */ (input) : {};
  /** @type {Record<string, string>} */
  const errors = {};
  /** @type {Record<string, unknown>} */
  const output = {};
  for (const [field, rule] of Object.entries(rules)) {
    const result = rule(source[field], field, source);
    if (result.error) {
      errors[field] = result.error;
    } else if (result.value !== undefined) {
      output[field] = result.value;
    }
  }
  if (Object.keys(errors).length > 0) {
    throw new ValidationError(errors);
  }
  return output;
}

export const field = {
  /**
   * @param {{min?: number, max?: number, label?: string}} [options]
   */
  string(options = {}) {
    const { min = 1, max = 5000, label = 'value' } = options;
    return (/** @type {unknown} */ value) => {
      if (typeof value !== 'string') return { error: `${label} is required` };
      const trimmed = value.trim();
      if (trimmed.length < min) return { error: `${label} must be at least ${min} characters` };
      if (trimmed.length > max) return { error: `${label} must be at most ${max} characters` };
      return { value: trimmed };
    };
  },

  /** @param {{max?: number, label?: string}} [options] */
  optionalString(options = {}) {
    const { max = 5000, label = 'value' } = options;
    return (/** @type {unknown} */ value) => {
      if (value === undefined || value === null || value === '') return { value: '' };
      if (typeof value !== 'string') return { error: `${label} is invalid` };
      const trimmed = value.trim();
      if (trimmed.length > max) return { error: `${label} must be at most ${max} characters` };
      return { value: trimmed };
    };
  },

  email() {
    return (/** @type {unknown} */ value) => {
      if (!isValidEmail(value)) return { error: 'a valid email address is required' };
      return { value: normalizeEmail(value) };
    };
  },

  uuid(/** @type {{label?: string, lowercase?: boolean}} */ options = {}) {
    const { label = 'installation id', lowercase = true } = options;
    return (/** @type {unknown} */ value) => {
      if (typeof value !== 'string') return { error: `${label} is required` };
      const trimmed = value.trim();
      if (!/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(trimmed)) {
        return { error: `${label} must be a valid UUID` };
      }
      return { value: lowercase ? trimmed.toLowerCase() : trimmed };
    };
  },

  /**
   * @param {readonly string[]} allowed
   * @param {{label?: string}} [options]
   */
  enum(allowed, options = {}) {
    const { label = 'value' } = options;
    return (/** @type {unknown} */ value) => {
      if (typeof value !== 'string' || !allowed.includes(value)) {
        return { error: `${label} must be one of: ${allowed.join(', ')}` };
      }
      return { value };
    };
  },

  /** @param {{min?: number, max?: number, label?: string}} [options] */
  integer(options = {}) {
    const { min = 0, max = Number.MAX_SAFE_INTEGER, label = 'value' } = options;
    return (/** @type {unknown} */ value) => {
      const parsed = typeof value === 'number' ? value : Number.parseInt(String(value), 10);
      if (!Number.isInteger(parsed)) return { error: `${label} must be an integer` };
      if (parsed < min || parsed > max) return { error: `${label} must be between ${min} and ${max}` };
      return { value: parsed };
    };
  },
};
