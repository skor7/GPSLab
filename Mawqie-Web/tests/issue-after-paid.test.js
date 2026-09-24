import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client, sendWebhook } from './helpers.js';
import { verifyEnvelope } from '../src/licensing/signing.js';

const UUID = '44444444-4444-4444-8444-444444444444';

test('a license is never issued for an unpaid order', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('pipeline@example.com', 'password-123');
    const order = await client.post('/api/orders', { planId: 'monthly' });
    assert.equal(order.status, 201);

    // The browser cannot mint a license; the service refuses unpaid orders.
    assert.throws(
      () => server.services.licensing.createLicenseForPaidOrder({ id: 'x', status: 'pending', planId: 'monthly' }),
      /paid order/
    );
    assert.equal(server.store.licenses.size, 0);
    assert.equal(server.services.orders.getOrder(order.body.orderId).status, 'pending');
  } finally {
    await server.close();
  }
});

test('a paid order issues exactly one license and an activation code', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('pipeline@example.com', 'password-123');
    const order = await client.post('/api/orders', { planId: 'monthly' });
    const pay = await client.post('/api/mock/pay', { orderId: order.body.orderId });
    assert.equal(pay.status, 200);
    assert.equal(server.store.licenses.size, 1);
    assert.equal(server.services.orders.getOrder(order.body.orderId).status, 'paid');
  } finally {
    await server.close();
  }
});

test('a duplicate paid webhook does not issue a second license', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('idempotent@example.com', 'password-123');
    const order = await client.post('/api/orders', { planId: 'monthly' });
    const intentId = order.body.checkout.intentId;
    const event = server.services.provider.eventPayload(intentId, 'payment.succeeded');
    const first = await sendWebhook(client, event, server.config.webhookSecret);
    assert.equal(first.status, 200);
    const second = await sendWebhook(client, event, server.config.webhookSecret);
    assert.equal(second.status, 200);
    assert.equal(second.body.duplicate, true);
    assert.equal(server.store.licenses.size, 1);
  } finally {
    await server.close();
  }
});

test('activation returns a signed envelope bound to the installation', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('activate@example.com', 'password-123');
    const order = await client.post('/api/orders', { planId: 'monthly' });
    await client.post('/api/mock/pay', { orderId: order.body.orderId });

    const license = [...server.store.licenses.values()][0];
    const code = [...server.store.activationCodes.values()][0].code;

    const activation = await client.request('POST', '/api/license', {
      json: { installationId: UUID, activationCode: code },
    });
    assert.equal(activation.status, 200);
    const claims = verifyEnvelope(activation.body, server.services.licensing.issuer.keyMaterial.publicKey);
    assert.ok(claims, 'envelope must verify against the public key');
    assert.equal(claims.installationId, UUID);
    assert.equal(claims.status, 'active');
    assert.equal(claims.plan, 'monthly');
    assert.equal(claims.issuer, 'GPSLab');
    assert.equal(license.installations.includes(UUID), true);

    // A refresh token round-trips and rotates.
    const refreshToken = activation.body.refreshToken;
    assert.ok(refreshToken);
    const refreshed = await client.request('POST', '/api/license', {
      json: { installationId: UUID, refreshToken },
    });
    assert.equal(refreshed.status, 200);
    assert.notEqual(refreshed.body.refreshToken, refreshToken);
  } finally {
    await server.close();
  }
});

test('the envelope echoes the installation id exactly as sent (case-sensitive)', async () => {
  const server = await startServer();
  const UPPER = 'ABCDEF01-2345-4678-8ABC-DEF012345678';
  try {
    const client = new Client(server.baseUrl);
    await client.signup('case@example.com', 'password-123');
    const order = await client.post('/api/orders', { planId: 'monthly' });
    await client.post('/api/mock/pay', { orderId: order.body.orderId });
    const activationCode = [...server.store.activationCodes.values()][0].code;

    const activation = await client.request('POST', '/api/license', {
      json: { installationId: UPPER, activationCode },
    });
    assert.equal(activation.status, 200);
    const claims = verifyEnvelope(activation.body, server.services.licensing.issuer.keyMaterial.publicKey);
    // GPSLab compares this claim case-sensitively against the device UUID.
    assert.equal(claims.installationId, UPPER);
    const license = [...server.store.licenses.values()][0];
    assert.equal(license.installations.includes(UPPER.toLowerCase()), true);

    // A later lookup with the same uppercase id still verifies.
    const lookup = await client.request('POST', '/api/license', { json: { installationId: UPPER } });
    const lookupClaims = verifyEnvelope(lookup.body, server.services.licensing.issuer.keyMaterial.publicKey);
    assert.equal(lookupClaims.installationId, UPPER);
  } finally {
    await server.close();
  }
});

test('the client compatibility path /api/v1/license/check issues the same envelope', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('alias@example.com', 'password-123');
    const order = await client.post('/api/orders', { planId: 'monthly' });
    await client.post('/api/mock/pay', { orderId: order.body.orderId });
    const activationCode = [...server.store.activationCodes.values()][0].code;

    const viaPortal = await client.request('POST', '/api/license', { json: { installationId: UUID, activationCode } });
    assert.equal(viaPortal.status, 200);
    // The Objective-C client posts to the build-config path; the same envelope
    // must come back (lookup by installation, no code needed).
    const viaClientPath = await client.request('POST', '/api/v1/license/check', { json: { installationId: UUID } });
    assert.equal(viaClientPath.status, 200);
    const claims = verifyEnvelope(viaClientPath.body, server.services.licensing.issuer.keyMaterial.publicKey);
    assert.ok(claims);
    assert.equal(claims.installationId, UUID);
  } finally {
    await server.close();
  }
});

test('a refund revokes the license and the next envelope says revoked', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('refund@example.com', 'password-123');
    const order = await client.post('/api/orders', { planId: 'monthly' });
    const intentId = order.body.checkout.intentId;
    const paidEvent = server.services.provider.simulatePay(intentId);
    await sendWebhook(client, paidEvent, server.config.webhookSecret);
    const activationCode = [...server.store.activationCodes.values()][0].code;
    await client.request('POST', '/api/license', { json: { installationId: UUID, activationCode } });

    const refund = server.services.provider.refund(intentId);
    const refunded = await sendWebhook(client, refund, server.config.webhookSecret);
    assert.equal(refunded.status, 200);
    assert.equal(server.services.orders.getOrder(order.body.orderId).status, 'refunded');

    const lookup = await client.request('POST', '/api/license', { json: { installationId: UUID } });
    assert.equal(lookup.status, 200);
    const claims = verifyEnvelope(lookup.body, server.services.licensing.issuer.keyMaterial.publicKey);
    assert.equal(claims.status, 'revoked');
  } finally {
    await server.close();
  }
});
