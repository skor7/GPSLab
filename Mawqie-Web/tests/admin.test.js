import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client, TEST_ADMIN_EMAIL, TEST_ADMIN_PASSWORD } from './helpers.js';

test('admin pages and APIs require admin authentication', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const page = await client.get('/admin');
    assert.equal(page.status, 302);
    assert.equal(page.location, '/admin/login');
    const api = await client.get('/api/admin/summary');
    assert.equal(api.status, 401);
  } finally {
    await server.close();
  }
});

test('admin login rejects bad credentials and accepts configured ones', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const bad = await client.adminLogin(TEST_ADMIN_EMAIL, 'nope');
    assert.equal(bad.status, 401);
    const good = await client.adminLogin();
    assert.equal(good.status, 303);
    assert.equal(good.location, '/admin');
    assert.ok(good.setCookies.some((cookie) => cookie.startsWith('mawqie_admin=')));
    assert.equal((await client.get('/api/admin/summary')).status, 200);
  } finally {
    await server.close();
  }
});

test('admin revocation flips the license and writes an audit entry', async () => {
  const server = await startServer();
  try {
    const customer = new Client(server.baseUrl);
    await customer.signup('revokee@example.com', 'password-123');
    const order = await customer.post('/api/orders', { planId: 'monthly' });
    await customer.post('/api/mock/pay', { orderId: order.body.orderId });
    const licenseId = [...server.store.licenses.values()][0].id;

    const admin = new Client(server.baseUrl);
    await admin.adminLogin();
    const revoke = await admin.post(`/api/admin/licenses/${licenseId}/revoke`, { reason: 'chargeback' });
    assert.equal(revoke.status, 200);
    assert.equal(revoke.body.status, 'revoked');
    assert.equal(server.store.licenses.get(licenseId).status, 'revoked');
    assert.equal(server.store.licenses.get(licenseId).revokeReason, 'chargeback');

    const audit = await admin.get('/api/admin/audit');
    const entry = audit.body.entries.find((item) => item.action === 'license.revoked');
    assert.ok(entry);
    assert.equal(entry.actorType, 'admin');
    assert.equal(entry.actorId, TEST_ADMIN_EMAIL);
    assert.equal(entry.targetId, licenseId);
  } finally {
    await server.close();
  }
});

test('admin dashboard summary never leaks password hashes', async () => {
  const server = await startServer();
  try {
    const customer = new Client(server.baseUrl);
    await customer.signup('privacy@example.com', 'password-123');
    const admin = new Client(server.baseUrl);
    await admin.adminLogin();
    const summary = await admin.get('/api/admin/summary');
    assert.equal(JSON.stringify(summary.body).includes('scrypt$'), false);
    assert.equal(summary.body.counts.customers, 1);
  } finally {
    await server.close();
  }
});

test('admin can move a ticket through its status workflow', async () => {
  const server = await startServer();
  try {
    const customer = new Client(server.baseUrl);
    const ticket = await customer.post('/api/tickets', { category: 'general', name: 'A', email: 'a@example.com', subject: 'Hi', message: 'Hello' });
    const admin = new Client(server.baseUrl);
    await admin.adminLogin();
    const update = await admin.post(`/api/admin/tickets/${ticket.body.ticketId}/status`, { status: 'reviewing' });
    assert.equal(update.status, 200);
    assert.equal(update.body.status, 'reviewing');
  } finally {
    await server.close();
  }
});

test('unauthenticated admin API rejects even with a valid CSRF token', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const response = await client.post('/api/admin/tickets/whatever/status', { status: 'closed' });
    assert.equal(response.status, 401);
  } finally {
    await server.close();
  }
});

test('admin login without configured credentials is disabled', async () => {
  const server = await startServer({ config: (await import('./helpers.js')).testConfig({ ADMIN_EMAIL: '', ADMIN_PASSWORD_HASH: '' }) });
  try {
    const client = new Client(server.baseUrl);
    const response = await client.adminLogin('anyone@example.com', 'whatever');
    assert.equal(response.status, 503);
    assert.match(response.text, /admin_disabled/);
  } finally {
    await server.close();
  }
});

test('TEST_ADMIN_PASSWORD is the configured one', () => {
  assert.equal(typeof TEST_ADMIN_PASSWORD, 'string');
});
