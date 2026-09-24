// @ts-check
/**
 * Configuration loading and production strictness.
 *
 * Reads configuration exclusively from the supplied environment object
 * (`process.env` by default). No `.env` file is auto-loaded and no credential is
 * ever hardcoded. In production the server refuses to start unless every required
 * secret and an HTTPS base URL are present, and mock payments are disabled.
 *
 * In addition, production is FAIL CLOSED: while the store, payment provider and
 * license integration are staging-only, `productionReadinessProblems` makes a
 * production load throw (see its doc comment). Local/staging is unaffected.
 *
 * Error messages never include secret values.
 */

import crypto from 'node:crypto';

export class ConfigError extends Error {
  /** @param {string[]} problems */
  constructor(problems) {
    super(`Invalid Mawqie-Web configuration:\n- ${problems.join('\n- ')}`);
    this.name = 'ConfigError';
    /** @type {string[]} */
    this.problems = problems;
  }
}

/**
 * Fail-closed production readiness gate.
 *
 * This portal currently ships ONLY staging components:
 *   * an in-memory / single-process JSON store (not a database),
 *   * a mock payment provider (no real PSP), and
 *   * an unverified remote license adapter (or local signing that must be pinned
 *     to the host app's embedded public key).
 *
 * A production deployment must not silently run on any of those, so production
 * startup is refused until real infrastructure exists. Non-production
 * (local/staging) environments are unaffected.
 *
 * @param {{isProduction?: boolean, licenseMode?: string, licenseExpectedPublicKey?: string}} config
 * @returns {string[]} human-readable problems (never secret values)
 */
export function productionReadinessProblems(config) {
  if (!config.isProduction) return [];
  /** @type {string[]} */
  const problems = [
    'production is not deployable: the staging JSON/in-memory store is the only store implementation; a persistent database backend is required',
    'production is not deployable: the mock payment provider is the only payment implementation; a real payment provider integration is required',
  ];
  if (config.licenseMode === 'remote') {
    problems.push('production is not deployable: LICENSE_MODE=remote uses an unverified adapter; a verified license-backend integration is required');
  } else if (!config.licenseExpectedPublicKey) {
    problems.push('LICENSE_EXPECTED_PUBLIC_KEY is required in production when LICENSE_MODE=local so the signing key provably matches the host app embedded key');
  }
  return problems;
}

/**
 * Throw a {@link ConfigError} when a config (possibly hand-built) is not
 * production-ready. `createApp` calls this so a production config cannot be
 * constructed in code and started around `loadConfig`.
 * @param {{isProduction?: boolean, licenseMode?: string, licenseExpectedPublicKey?: string}} config
 */
export function assertProductionReady(config) {
  const problems = productionReadinessProblems(config);
  if (problems.length > 0) throw new ConfigError(problems);
}

/** @param {string | undefined} value @param {boolean} fallback */
function parseBool(value, fallback) {
  if (value === undefined || value === '') return fallback;
  const normalized = String(value).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  return fallback;
}

/** @param {string | undefined} value @param {number} fallback */
function parseIntOr(value, fallback) {
  if (value === undefined || value === '') return fallback;
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

/**
 * @typedef {object} MawqieConfig
 * @property {string} nodeEnv
 * @property {boolean} isProduction
 * @property {boolean} isTest
 * @property {number} port
 * @property {string} baseUrl
 * @property {boolean} trustProxy
 * @property {boolean} cookieSecure
 * @property {string} sessionSecret
 * @property {string} webhookSecret
 * @property {string} adminEmail
 * @property {string} adminPasswordHash
 * @property {boolean} adminConfigured
 * @property {'local' | 'remote'} licenseMode
 * @property {string} licenseBackendUrl
 * @property {string} licensePrivateKeyPem
 * @property {string} licenseExpectedPublicKey
 * @property {string} licenseIssuer
 * @property {string} licenseAudience
 * @property {number} licenseGraceSeconds
 * @property {boolean} allowMockPayments
 * @property {string[]} notifyChannels
 * @property {string} notifyEmailFrom
 * @property {string} notifyEmailEndpoint
 * @property {string} notifyFilePath
 * @property {string} dataFile
 * @property {number} rateLimitWindowMs
 * @property {number} rateLimitMax
 * @property {string[]} ephemeralSecrets
 */

/**
 * @param {Record<string, string | undefined>} [env]
 * @returns {MawqieConfig}
 */
export function loadConfig(env = process.env) {
  const nodeEnv = (env.NODE_ENV || 'development').trim().toLowerCase();
  const isProduction = nodeEnv === 'production';
  const isTest = nodeEnv === 'test';
  const port = parseIntOr(env.PORT, 3000);

  /** @type {string[]} */
  const ephemeralSecrets = [];
  /** @type {string[]} */
  const problems = [];

  let sessionSecret = (env.SESSION_SECRET || '').trim();
  if (!sessionSecret) {
    if (isProduction) {
      problems.push('SESSION_SECRET is required in production');
    } else {
      sessionSecret = cryptoRandomHex(32);
      ephemeralSecrets.push('SESSION_SECRET');
    }
  }

  let webhookSecret = (env.WEBHOOK_SECRET || '').trim();
  if (!webhookSecret) {
    if (isProduction) {
      problems.push('WEBHOOK_SECRET is required in production');
    } else {
      webhookSecret = cryptoRandomHex(32);
      ephemeralSecrets.push('WEBHOOK_SECRET');
    }
  }

  const adminEmail = (env.ADMIN_EMAIL || '').trim().toLowerCase();
  const adminPasswordHash = (env.ADMIN_PASSWORD_HASH || '').trim();
  const adminConfigured = Boolean(adminEmail && adminPasswordHash);
  if (isProduction && !adminConfigured) {
    problems.push('ADMIN_EMAIL and ADMIN_PASSWORD_HASH are required in production');
  }

  const licenseMode = (env.LICENSE_MODE || 'local').trim().toLowerCase() === 'remote' ? 'remote' : 'local';
  const licenseBackendUrl = (env.LICENSE_BACKEND_URL || '').trim();
  const licensePrivateKeyPem = env.LICENSE_PRIVATE_KEY_PEM || '';
  const licenseExpectedPublicKey = (env.LICENSE_EXPECTED_PUBLIC_KEY || '').replace(/\s+/g, '');
  if (isProduction && licenseMode === 'local' && !licensePrivateKeyPem.trim()) {
    problems.push('LICENSE_PRIVATE_KEY_PEM is required in production when LICENSE_MODE=local');
  }
  if (licenseMode === 'remote' && !licenseBackendUrl) {
    problems.push('LICENSE_BACKEND_URL is required when LICENSE_MODE=remote');
  }

  const baseUrl = (env.BASE_URL || `http://localhost:${port}`).trim().replace(/\/+$/, '');
  if (isProduction) {
    if (!/^https:\/\//i.test(baseUrl)) {
      problems.push('BASE_URL must be https:// in production');
    }
  }

  const cookieSecureDefault = isProduction;
  const cookieSecure = parseBool(env.COOKIE_SECURE, cookieSecureDefault);
  if (isProduction && !cookieSecure) {
    problems.push('COOKIE_SECURE must not be disabled in production');
  }

  const allowMockPaymentsDefault = !isProduction;
  const allowMockPayments = parseBool(env.ALLOW_MOCK_PAYMENTS, allowMockPaymentsDefault);
  if (isProduction && allowMockPayments) {
    problems.push('ALLOW_MOCK_PAYMENTS must be disabled in production');
  }

  const notifyChannels = (env.NOTIFY_CHANNELS || 'console')
    .split(',')
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);

  // Fail closed: production must not start on the staging-only components that
  // this build ships (see productionReadinessProblems).
  if (isProduction) {
    problems.push(...productionReadinessProblems({
      isProduction,
      licenseMode: /** @type {'local' | 'remote'} */ (licenseMode),
      licenseExpectedPublicKey,
    }));
  }

  if (problems.length > 0) {
    throw new ConfigError(problems);
  }

  return Object.freeze({
    nodeEnv,
    isProduction,
    isTest,
    port,
    baseUrl,
    trustProxy: parseBool(env.TRUST_PROXY, false),
    cookieSecure,
    sessionSecret,
    webhookSecret,
    adminEmail,
    adminPasswordHash,
    adminConfigured,
    licenseMode: /** @type {'local' | 'remote'} */ (licenseMode),
    licenseBackendUrl,
    licensePrivateKeyPem,
    // Pin: when set, the signing key's public key MUST match this value (base64
    // SPKI or base64url). This prevents deploying a signing key that the host
    // app's embedded `GPSLabLicensePublicKey` cannot verify. Production local
    // signing REQUIRES this pin (enforced by config + loadKeyMaterial).
    licenseExpectedPublicKey,
    // Defaults match Source/GPSLabLicenseBuildConfig.h (issuer `GPSLab`,
    // audience `GPSLab-iOS`) so a locally-issued envelope verifies on the app.
    licenseIssuer: (env.LICENSE_ISSUER || 'GPSLab').trim(),
    licenseAudience: (env.LICENSE_AUDIENCE || 'GPSLab-iOS').trim(),
    licenseGraceSeconds: parseIntOr(env.LICENSE_GRACE_SECONDS, 604800),
    allowMockPayments,
    notifyChannels: notifyChannels.length > 0 ? notifyChannels : ['console'],
    notifyEmailFrom: (env.NOTIFY_EMAIL_FROM || 'no-reply@mawqie.test').trim(),
    notifyEmailEndpoint: (env.NOTIFY_EMAIL_ENDPOINT || '').trim(),
    notifyFilePath: (env.NOTIFY_FILE_PATH || '').trim(),
    dataFile: (env.DATA_FILE || '').trim(),
    rateLimitWindowMs: parseIntOr(env.RATE_LIMIT_WINDOW_MS, 60000),
    rateLimitMax: parseIntOr(env.RATE_LIMIT_MAX, 60),
    ephemeralSecrets,
  });
}

/** @param {number} bytes */
function cryptoRandomHex(bytes) {
  return crypto.randomBytes(bytes).toString('hex');
}
