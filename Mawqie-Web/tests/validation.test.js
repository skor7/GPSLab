import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client } from './helpers.js';

test('server-side validation rejects a malformed installation id', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const response = await client.post('/api/trial', { email: 'a@example.com', installationId: 'not-a-uuid' });
    assert.equal(response.status, 400);
    assert.equal(response.body.error, 'validation failed');
    assert.ok(response.body.fields.installationId);
  } finally {
    await server.close();
  }
});

test('server-side validation rejects a malformed email', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const response = await client.post('/api/trial', { email: 'nope', installationId: '11111111-1111-4111-8111-111111111111' });
    assert.equal(response.status, 400);
    assert.ok(response.body.fields.email);
  } finally {
    await server.close();
  }
});

test('the license endpoint validates its required fields', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const response = await client.request('POST', '/api/license', { json: {} });
    assert.equal(response.status, 400);
    assert.ok(response.body.fields.installationId);
  } finally {
    await server.close();
  }
});

test('orders reject unknown plans and inactive ones', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('orders@example.com', 'password-123');
    const unknown = await client.post('/api/orders', { planId: 'ghost' });
    assert.equal(unknown.status, 404);
    assert.equal(unknown.body.code, 'unknown_plan');
  } finally {
    await server.close();
  }
});

test('JSON bodies are accepted for API endpoints', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const token = await client.csrf();
    const response = await client.request('POST', '/api/trial', {
      json: { email: 'json@example.com', installationId: '55555555-5555-4555-8555-555555555555' },
      headers: { 'x-csrf-token': token },
    });
    assert.equal(response.status, 201);
  } finally {
    await server.close();
  }
});

test('a malformed JSON body is rejected', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const token = await client.csrf();
    const response = await client.request('POST', '/api/trial', {
      raw: '{not json',
      contentType: 'application/json',
      headers: { 'x-csrf-token': token },
    });
    assert.equal(response.status, 400);
    assert.equal(response.body.code, 'invalid_json');
  } finally {
    await server.close();
  }
});
