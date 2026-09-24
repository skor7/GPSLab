import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client } from './helpers.js';

async function setup() {
  const server = await startServer();
  const alice = new Client(server.baseUrl);
  const bob = new Client(server.baseUrl);
  await alice.signup('alice@example.com', 'password-123');
  await bob.signup('bob@example.com', 'password-123');
  return { server, alice, bob };
}

test('one customer never sees another customer orders', async () => {
  const { server, alice, bob } = await setup();
  try {
    const order = await alice.post('/api/orders', { planId: 'monthly' });
    assert.equal(order.status, 201);

    const aliceSummary = await alice.get('/api/account/summary');
    assert.equal(aliceSummary.body.orders.length, 1);

    const bobSummary = await bob.get('/api/account/summary');
    assert.equal(bobSummary.body.orders.length, 0);
  } finally {
    await server.close();
  }
});

test('one customer cannot pay another customer order', async () => {
  const { server, alice, bob } = await setup();
  try {
    const order = await alice.post('/api/orders', { planId: 'monthly' });
    const orderId = order.body.orderId;
    const attempt = await bob.post('/api/mock/pay', { orderId });
    assert.equal(attempt.status, 404);
    assert.equal(attempt.body.code, 'not_found');
  } finally {
    await server.close();
  }
});

test('one customer cannot read another customer tickets', async () => {
  const { server, alice, bob } = await setup();
  try {
    await alice.post('/api/tickets', { category: 'general', name: 'Alice', email: 'alice@example.com', subject: 'Help', message: 'please' });
    const aliceSummary = await alice.get('/api/account/summary');
    assert.equal(aliceSummary.body.tickets.length, 1);
    const bobSummary = await bob.get('/api/account/summary');
    assert.equal(bobSummary.body.tickets.length, 0);
  } finally {
    await server.close();
  }
});

test('a license issued to one customer is not listed for another', async () => {
  const { server, alice, bob } = await setup();
  try {
    const order = await alice.post('/api/orders', { planId: 'monthly' });
    await alice.post('/api/mock/pay', { orderId: order.body.orderId });
    const aliceSummary = await alice.get('/api/account/summary');
    assert.equal(aliceSummary.body.licenses.length, 1);
    const bobSummary = await bob.get('/api/account/summary');
    assert.equal(bobSummary.body.licenses.length, 0);
  } finally {
    await server.close();
  }
});
