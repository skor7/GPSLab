import test from 'node:test';
import assert from 'node:assert/strict';
import { MockPaymentProvider } from '../src/payments/mock-provider.js';
import { Store } from '../src/store/store.js';

function provider() {
  const store = new Store();
  return { store, provider: new MockPaymentProvider({ store, now: () => 1_700_000_000_000 }) };
}

test('a new intent starts pending', () => {
  const { provider: psp } = provider();
  const intent = psp.createIntent({ orderId: 'order-1', amount: 1900, currency: 'SAR' });
  assert.equal(intent.state, 'pending');
  assert.deepEqual(intent.history.map((entry) => entry.state), ['created', 'pending']);
});

test('the happy path reaches paid and can be refunded', () => {
  const { provider: psp } = provider();
  const intent = psp.createIntent({ orderId: 'order-1', amount: 1900, currency: 'SAR' });
  const event = psp.simulatePay(intent.id);
  assert.equal(event.type, 'payment.succeeded');
  assert.equal(psp.getIntent(intent.id).state, 'paid');
  const refund = psp.refund(intent.id);
  assert.equal(refund.type, 'payment.refunded');
  assert.equal(psp.getIntent(intent.id).state, 'refunded');
});

test('illegal transitions are rejected', () => {
  const { provider: psp } = provider();
  const intent = psp.createIntent({ orderId: 'order-1', amount: 1900, currency: 'SAR' });
  assert.throws(() => psp.transition(intent.id, 'paid'), /illegal transition/);
  psp.simulateFailure(intent.id, 'declined');
  assert.throws(() => psp.transition(intent.id, 'paid'), /illegal transition/);
});

test('failure records a reason', () => {
  const { provider: psp } = provider();
  const intent = psp.createIntent({ orderId: 'order-1', amount: 500, currency: 'SAR' });
  const event = psp.simulateFailure(intent.id, 'insufficient_funds');
  assert.equal(event.type, 'payment.failed');
  assert.equal(event.data.reason, 'insufficient_funds');
  assert.equal(psp.getIntent(intent.id).state, 'failed');
});

test('unknown intents and invalid amounts are rejected', () => {
  const { provider: psp } = provider();
  assert.equal(psp.getIntent('nope'), null);
  assert.throws(() => psp.createIntent({ orderId: 'o', amount: -1, currency: 'SAR' }), /non-negative integer/);
});
