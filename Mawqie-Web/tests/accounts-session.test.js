import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client } from './helpers.js';

test('signup creates an account and an HttpOnly session cookie', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const response = await client.signup('owner@example.com', 'password-123', 'Owner');
    assert.equal(response.status, 201);
    const cookie = response.setCookies.find((value) => value.startsWith('mawqie_session='));
    assert.ok(cookie, 'session cookie must be set');
    assert.match(cookie, /HttpOnly/i);
    assert.match(cookie, /SameSite=Lax/i);

    const summary = await client.get('/api/account/summary');
    assert.equal(summary.status, 200);
    assert.equal(summary.body.customer.email, 'owner@example.com');
  } finally {
    await server.close();
  }
});

test('login rejects a wrong password and accepts the right one', async () => {
  const server = await startServer();
  try {
    await new Client(server.baseUrl).signup('login@example.com', 'password-123');
    const client = new Client(server.baseUrl);
    const bad = await client.login('login@example.com', 'wrong-password');
    assert.equal(bad.status, 401);
    assert.equal(bad.body.code, 'invalid_credentials');
    const good = await client.login('login@example.com', 'password-123');
    assert.equal(good.status, 200);
  } finally {
    await server.close();
  }
});

test('duplicate signup is rejected and weak passwords are validated', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    assert.equal((await client.signup('dup@example.com', 'password-123')).status, 201);
    const duplicate = await client.signup('DUP@example.com', 'password-456');
    assert.equal(duplicate.status, 409);
    assert.equal(duplicate.body.code, 'email_taken');

    const weak = await client.signup('weak@example.com', 'short');
    assert.equal(weak.status, 400);
    assert.ok(weak.body.fields.password);
  } finally {
    await server.close();
  }
});

test('logout destroys the session', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('bye@example.com', 'password-123');
    assert.equal((await client.get('/api/account/summary')).status, 200);
    const logout = await client.post('/api/auth/logout', {});
    assert.equal(logout.status, 200);
    assert.equal((await client.get('/api/account/summary')).status, 401);
  } finally {
    await server.close();
  }
});

test('unauthenticated account access is refused', async () => {
  const server = await startServer();
  try {
    const response = await new Client(server.baseUrl).get('/api/account/summary');
    assert.equal(response.status, 401);
    assert.equal(response.body.code, 'unauthenticated');
  } finally {
    await server.close();
  }
});

test('passwords are never returned by the API', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const response = await client.signup('secret@example.com', 'password-123');
    assert.equal(JSON.stringify(response.body).includes('passwordHash'), false);
    const summary = await client.get('/api/account/summary');
    assert.equal(JSON.stringify(summary.body).includes('scrypt$'), false);
  } finally {
    await server.close();
  }
});
