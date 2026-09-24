import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client } from './helpers.js';
import { trialEligibility } from '../src/trials.js';
import { defaultPlanCatalog } from '../src/plans.js';

const UUID_A = '11111111-1111-4111-8111-111111111111';
const UUID_B = '22222222-2222-4222-8222-222222222222';
const UUID_C = '33333333-3333-4333-8333-333333333333';

test('a trial is granted once per normalized email', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const first = await client.post('/api/trial', { email: 'User@Example.com ', installationId: UUID_A });
    assert.equal(first.status, 201);
    assert.ok(first.body.envelope?.signature);

    const second = await client.post('/api/trial', { email: 'user@example.com', installationId: UUID_B });
    assert.equal(second.status, 409);
    assert.equal(second.body.code, 'email_already_used');
  } finally {
    await server.close();
  }
});

test('a trial is granted once per installation id', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const first = await client.post('/api/trial', { email: 'one@example.com', installationId: UUID_A });
    assert.equal(first.status, 201);

    const second = await client.post('/api/trial', { email: 'two@example.com', installationId: UUID_A });
    assert.equal(second.status, 409);
    assert.equal(second.body.code, 'installation_already_used');
  } finally {
    await server.close();
  }
});

test('trialEligibility reports precise reasons and is server-side only', () => {
  const plans = defaultPlanCatalog();
  const store = { redemptions: new Map(), licenses: new Map() };
  const plan = plans.get('trial');
  assert.deepEqual(trialEligibility({ store, plan, email: 'a@b.com', installationId: UUID_A }), { eligible: true, reason: 'eligible' });
  assert.equal(trialEligibility({ store, plan: null, email: 'a@b.com', installationId: UUID_A }).reason, 'plan_not_trial');
  assert.equal(trialEligibility({ store, plan, email: 'bad', installationId: UUID_A }).reason, 'invalid_email');
});

test('a signed-in customer cannot claim a trial against another email', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('owner@example.com', 'password-123');
    const mismatch = await client.post('/api/trial', { email: 'someone-else@example.com', installationId: UUID_A });
    assert.equal(mismatch.status, 403);
    assert.equal(mismatch.body.code, 'email_mismatch');
    assert.match(String(mismatch.body.error), /لا يطابق/);
  } finally {
    await server.close();
  }
});

test('a signed-in trial is account-bound, returns a usable code, and appears on the account', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('bound@example.com', 'password-123');
    const trial = await client.post('/api/trial', { email: 'bound@example.com', installationId: UUID_A });
    assert.equal(trial.status, 201);
    assert.ok(trial.body.envelope?.signature);
    assert.ok(trial.body.activationCode, 'a trial must return a usable activation code');

    const summary = await client.get('/api/account/summary');
    assert.equal(summary.body.licenses.length, 1);
    assert.equal(summary.body.licenses[0].id, trial.body.licenseId);
    // The license is owned by the account (not orphaned).
    assert.equal(server.store.licenses.get(trial.body.licenseId).customerId !== null, true);
  } finally {
    await server.close();
  }
});

test('account history blocks a second trial even on a new installation', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('repeat@example.com', 'password-123');
    const first = await client.post('/api/trial', { email: 'repeat@example.com', installationId: UUID_A });
    assert.equal(first.status, 201);
    const second = await client.post('/api/trial', { email: 'repeat@example.com', installationId: UUID_B });
    assert.equal(second.status, 409);
    assert.equal(second.body.code, 'account_already_used');
  } finally {
    await server.close();
  }
});

test('redemption history records email and installation', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.post('/api/trial', { email: 'history@example.com', installationId: UUID_C });
    const redemptions = [...server.store.redemptions.values()];
    assert.equal(redemptions.length, 1);
    assert.equal(redemptions[0].kind, 'trial');
    assert.equal(redemptions[0].emailNormalized, 'history@example.com');
    assert.equal(redemptions[0].installationId, UUID_C);
  } finally {
    await server.close();
  }
});
