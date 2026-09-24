import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client } from './helpers.js';
import { RateLimiter } from '../src/http/ratelimit.js';

test('the rate limiter resets after the window', () => {
  let now = 0;
  const limiter = new RateLimiter({ windowMs: 1000, max: 2, now: () => now });
  assert.equal(limiter.hit('k').allowed, true);
  assert.equal(limiter.hit('k').allowed, true);
  assert.equal(limiter.hit('k').allowed, false);
  now = 1001;
  assert.equal(limiter.hit('k').allowed, true);
});

test('repeated login attempts are rate limited with a 429', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    let last = null;
    for (let attempt = 0; attempt < 12; attempt += 1) {
      last = await client.post('/api/auth/login', { email: 'nobody@example.com', password: 'whatever-1' });
    }
    assert.equal(last.status, 429);
    assert.equal(last.body.code, 'rate_limited');
    assert.ok(last.headers.get('retry-after'));
  } finally {
    await server.close();
  }
});

test('trial claims are rate limited per email', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    let last = null;
    for (let attempt = 0; attempt < 7; attempt += 1) {
      const installationId = `0000000${attempt}-0000-4000-8000-000000000000`;
      last = await client.post('/api/trial', { email: 'limit@example.com', installationId });
    }
    assert.equal(last.status, 429);
  } finally {
    await server.close();
  }
});

test('ticket submissions are rate limited', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    let last = null;
    for (let attempt = 0; attempt < 7; attempt += 1) {
      last = await client.post('/api/tickets', { category: 'general', name: 'A', email: 'a@example.com', subject: 's', message: 'm' });
    }
    assert.equal(last.status, 429);
  } finally {
    await server.close();
  }
});
