import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client } from './helpers.js';

test('a state-changing request without a CSRF token is rejected', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const response = await client.request('POST', '/api/tickets', {
      form: { category: 'general', name: 'A', email: 'a@example.com', subject: 's', message: 'm' },
    });
    assert.equal(response.status, 403);
    assert.equal(response.body.code, 'csrf_failed');
  } finally {
    await server.close();
  }
});

test('a mismatched CSRF token is rejected', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.csrf();
    const response = await client.request('POST', '/api/tickets', {
      form: { category: 'general', name: 'A', email: 'a@example.com', subject: 's', message: 'm', _csrf: 'not-the-token' },
    });
    assert.equal(response.status, 403);
  } finally {
    await server.close();
  }
});

test('a matching CSRF token in the header is accepted', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const token = await client.csrf();
    const response = await client.request('POST', '/api/tickets', {
      json: { category: 'general', name: 'A', email: 'a@example.com', subject: 's', message: 'm' },
      headers: { 'x-csrf-token': token },
    });
    assert.equal(response.status, 201);
  } finally {
    await server.close();
  }
});

test('the CSRF cookie is readable by the page (not HttpOnly)', async () => {
  const server = await startServer();
  try {
    const response = await new Client(server.baseUrl).get('/api/csrf');
    const cookie = response.setCookies.find((value) => value.startsWith('mawqie_csrf='));
    assert.ok(cookie);
    assert.equal(/HttpOnly/i.test(cookie), false);
  } finally {
    await server.close();
  }
});

test('webhooks do not require a CSRF token (signature auth instead)', async () => {
  const server = await startServer();
  try {
    const response = await new Client(server.baseUrl).request('POST', '/webhooks/payment', { raw: '{}' });
    // Reaches the signature check (401), not the CSRF check (403).
    assert.equal(response.status, 401);
  } finally {
    await server.close();
  }
});
