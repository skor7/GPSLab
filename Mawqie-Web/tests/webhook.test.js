import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client, sendWebhook } from './helpers.js';

async function setup() {
  const server = await startServer();
  const client = new Client(server.baseUrl);
  await client.signup('buyer@example.com', 'password-123');
  const order = await client.post('/api/orders', { planId: 'monthly' });
  const intentId = order.body.checkout.intentId;
  return { server, client, orderId: order.body.orderId, intentId };
}

test('a correctly signed webhook marks the order paid', async () => {
  const { server, client, orderId, intentId } = await setup();
  try {
    const event = server.services.provider.eventPayload(intentId, 'payment.succeeded');
    const response = await sendWebhook(client, event, server.config.webhookSecret);
    assert.equal(response.status, 200);
    assert.equal(server.services.orders.getOrder(orderId).status, 'paid');
  } finally {
    await server.close();
  }
});

test('a webhook with an invalid signature is rejected and changes nothing', async () => {
  const { server, client, orderId, intentId } = await setup();
  try {
    const event = server.services.provider.eventPayload(intentId, 'payment.succeeded');
    const response = await sendWebhook(client, event, 'wrong-secret');
    assert.equal(response.status, 401);
    assert.equal(response.body.code, 'invalid_signature');
    assert.equal(server.services.orders.getOrder(orderId).status, 'pending');
  } finally {
    await server.close();
  }
});

test('a signature over a different body does not validate', async () => {
  const { server, client, intentId } = await setup();
  try {
    const event = server.services.provider.eventPayload(intentId, 'payment.succeeded');
    const raw = JSON.stringify({ ...event, extra: 'tampered' });
    const signature = (await import('../src/payments/webhook.js')).signWebhook(JSON.stringify(event), server.config.webhookSecret);
    const response = await client.request('POST', '/webhooks/payment/mock', {
      raw,
      headers: { 'x-mawqie-signature': signature },
    });
    assert.equal(response.status, 401);
  } finally {
    await server.close();
  }
});

test('an amount mismatch is refused even with a valid signature', async () => {
  const { server, client, orderId, intentId } = await setup();
  try {
    const event = server.services.provider.eventPayload(intentId, 'payment.succeeded');
    event.data.amount = 1; // attacker-supplied mismatch
    const response = await sendWebhook(client, event, server.config.webhookSecret);
    assert.equal(response.status, 409);
    assert.equal(response.body.code, 'amount_mismatch');
    assert.equal(server.services.orders.getOrder(orderId).status, 'pending');
  } finally {
    await server.close();
  }
});

test('unknown orders and unknown event types are refused', async () => {
  const { server, client, intentId } = await setup();
  try {
    const unknown = server.services.provider.eventPayload(intentId, 'payment.succeeded');
    unknown.data.orderId = 'does-not-exist';
    assert.equal((await sendWebhook(client, unknown, server.config.webhookSecret)).status, 404);

    const unhandled = server.services.provider.eventPayload(intentId, 'payment.succeeded');
    unhandled.type = 'payment.disputed';
    assert.equal((await sendWebhook(client, unhandled, server.config.webhookSecret)).status, 400);
  } finally {
    await server.close();
  }
});

test('missing signature is rejected', async () => {
  const { server, client, intentId } = await setup();
  try {
    const event = server.services.provider.eventPayload(intentId, 'payment.succeeded');
    const response = await client.request('POST', '/webhooks/payment/mock', { raw: JSON.stringify(event) });
    assert.equal(response.status, 401);
  } finally {
    await server.close();
  }
});
