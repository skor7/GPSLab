import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { loadConfig, ConfigError, productionReadinessProblems, assertProductionReady } from '../src/config.js';
import { hashPassword } from '../src/core/password.js';

const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const PEM = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const SPKI = crypto.createPublicKey(privateKey).export({ type: 'spki', format: 'der' }).toString('base64');

function productionEnv(overrides = {}) {
  return {
    NODE_ENV: 'production',
    SESSION_SECRET: 's'.repeat(64),
    WEBHOOK_SECRET: 'w'.repeat(64),
    ADMIN_EMAIL: 'admin@mawqie.example',
    ADMIN_PASSWORD_HASH: hashPassword('admin-password-123'),
    BASE_URL: 'https://portal.mawqie.example',
    COOKIE_SECURE: '1',
    ALLOW_MOCK_PAYMENTS: '0',
    LICENSE_MODE: 'local',
    LICENSE_PRIVATE_KEY_PEM: PEM,
    LICENSE_EXPECTED_PUBLIC_KEY: SPKI,
    ...overrides,
  };
}

test('production is refused while only staging components exist', () => {
  assert.throws(() => loadConfig(productionEnv()), (error) => {
    assert.ok(error instanceof ConfigError);
    assert.match(error.message, /staging JSON\/in-memory store/);
    assert.match(error.message, /mock payment provider/);
    return true;
  });
});

test('production refuses the unverified remote license adapter', () => {
  assert.throws(
    () => loadConfig(productionEnv({ LICENSE_MODE: 'remote', LICENSE_PRIVATE_KEY_PEM: '', LICENSE_BACKEND_URL: 'https://backend.example' })),
    /unverified adapter/
  );
});

test('production local signing requires the embedded-key pin', () => {
  assert.throws(
    () => loadConfig(productionEnv({ LICENSE_EXPECTED_PUBLIC_KEY: '' })),
    /LICENSE_EXPECTED_PUBLIC_KEY/
  );
});

test('productionReadinessProblems is empty outside production', () => {
  assert.deepEqual(productionReadinessProblems({ isProduction: false, licenseMode: 'local' }), []);
});

test('assertProductionReady refuses a hand-built production config', () => {
  assert.throws(
    () => assertProductionReady({ isProduction: true, licenseMode: 'local', licenseExpectedPublicKey: SPKI }),
    /not deployable/
  );
  assert.doesNotThrow(() => assertProductionReady({ isProduction: false, licenseMode: 'local' }));
});

test('production still requires every secret and rejects unsafe settings', () => {
  assert.throws(() => loadConfig(productionEnv({ SESSION_SECRET: '' })), /SESSION_SECRET/);
  assert.throws(() => loadConfig(productionEnv({ WEBHOOK_SECRET: '' })), /WEBHOOK_SECRET/);
  assert.throws(() => loadConfig(productionEnv({ ADMIN_PASSWORD_HASH: '' })), /ADMIN_PASSWORD_HASH/);
  assert.throws(() => loadConfig(productionEnv({ LICENSE_PRIVATE_KEY_PEM: '' })), /LICENSE_PRIVATE_KEY_PEM/);
  assert.throws(() => loadConfig(productionEnv({ ALLOW_MOCK_PAYMENTS: '1' })), /ALLOW_MOCK_PAYMENTS/);
  assert.throws(() => loadConfig(productionEnv({ BASE_URL: 'http://portal.mawqie.example' })), /https/);
  assert.throws(() => loadConfig(productionEnv({ COOKIE_SECURE: '0' })), /COOKIE_SECURE/);
});

test('remote license mode still requires a backend URL', () => {
  assert.throws(
    () => loadConfig(productionEnv({ LICENSE_MODE: 'remote', LICENSE_PRIVATE_KEY_PEM: '', LICENSE_BACKEND_URL: '' })),
    /LICENSE_BACKEND_URL/
  );
});

test('configuration errors never echo secret values', () => {
  const secret = 'do-not-leak-this-secret-value';
  try {
    loadConfig(productionEnv({ SESSION_SECRET: secret, WEBHOOK_SECRET: '' }));
    assert.fail('expected a ConfigError');
  } catch (error) {
    assert.ok(error instanceof ConfigError);
    assert.equal(String(error.message).includes(secret), false);
  }
});

test('development and staging still load (staging behavior preserved)', () => {
  const dev = loadConfig({ NODE_ENV: 'development' });
  assert.ok(dev.ephemeralSecrets.includes('SESSION_SECRET'));
  assert.ok(dev.ephemeralSecrets.includes('WEBHOOK_SECRET'));
  assert.equal(dev.cookieSecure, false);
  assert.equal(dev.allowMockPayments, true);

  const staging = loadConfig({ NODE_ENV: 'staging', ALLOW_MOCK_PAYMENTS: '1' });
  assert.equal(staging.isProduction, false);
  assert.equal(staging.allowMockPayments, true);
});
