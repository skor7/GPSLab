import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { startServer, Client, testConfig } from './helpers.js';
import { loadConfig, ConfigError } from '../src/config.js';
import { enforceHttps } from '../src/http/security.js';
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
    TRUST_PROXY: '1',
    ...overrides,
  };
}

test('production configuration refuses to start while only staging components exist', () => {
  assert.throws(() => loadConfig(productionEnv()), ConfigError);
  assert.throws(() => loadConfig(productionEnv({ ALLOW_MOCK_PAYMENTS: '1' })), /ALLOW_MOCK_PAYMENTS/);
});

test('the mock payment route is absent when mock payments are disabled', async () => {
  const server = await startServer({ config: testConfig({ ALLOW_MOCK_PAYMENTS: '0' }) });
  try {
    const client = new Client(server.baseUrl);
    const signup = await client.post('/api/auth/signup', { email: 'prod@example.com', password: 'password-123' }, { json: true });
    assert.equal(signup.status, 201);
    const order = await client.post('/api/orders', { planId: 'monthly' }, { json: true });
    assert.equal(order.status, 201);

    const mockPay = await client.post('/api/mock/pay', { orderId: order.body.orderId }, { json: true });
    assert.equal(mockPay.status, 404);
    assert.equal(mockPay.body.code, 'not_found');
  } finally {
    await server.close();
  }
});

test('the canonical webhook remains available and signature-enforced', async () => {
  const server = await startServer({ config: testConfig({ ALLOW_MOCK_PAYMENTS: '0' }) });
  try {
    const client = new Client(server.baseUrl);
    const response = await client.request('POST', '/webhooks/payment', { raw: '{}' });
    assert.equal(response.status, 401);
    assert.equal(response.body.code, 'invalid_signature');
  } finally {
    await server.close();
  }
});

test('the mock webhook alias is absent when mock payments are disabled', async () => {
  const server = await startServer({ config: testConfig({ ALLOW_MOCK_PAYMENTS: '0' }) });
  try {
    const client = new Client(server.baseUrl);
    const response = await client.request('POST', '/webhooks/payment/mock', { raw: '{}' });
    assert.equal(response.status, 404);
    assert.equal(response.body.code, 'not_found');
  } finally {
    await server.close();
  }
});

test('enforceHttps redirects GET and refuses other methods in production', () => {
  const config = { isProduction: true, trustProxy: true };
  const getRes = fakeRes();
  const handledGet = enforceHttps({ method: 'GET', url: '/healthz', headers: { host: 'portal.example' }, socket: {} }, getRes, config);
  assert.equal(handledGet, true);
  assert.equal(getRes.statusCode, 308);
  assert.match(String(getRes.headers.location), /^https:\/\//);

  const postRes = fakeRes();
  const handledPost = enforceHttps({ method: 'POST', url: '/api/orders', headers: { host: 'portal.example' }, socket: {} }, postRes, config);
  assert.equal(handledPost, true);
  assert.equal(postRes.statusCode, 403);

  const secureRes = fakeRes();
  const handledSecure = enforceHttps({ method: 'GET', url: '/healthz', headers: { host: 'portal.example', 'x-forwarded-proto': 'https' }, socket: {} }, secureRes, config);
  assert.equal(handledSecure, false);
});

test('testConfig used by the suite is never production', () => {
  assert.equal(testConfig().isProduction, false);
});

function fakeRes() {
  return {
    statusCode: 0,
    headers: {},
    writeHead(code, headers) {
      this.statusCode = code;
      Object.assign(this.headers, headers || {});
    },
    end() {},
  };
}
