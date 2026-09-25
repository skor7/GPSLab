import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { startServer, Client } from './helpers.js';
import { sha256Hex } from '../src/core/ids.js';

const DAY_MS = 24 * 60 * 60 * 1000;

/** Build a lower-case UUID v4. */
function uuid() {
  return crypto.randomUUID().toLowerCase();
}

/**
 * Emulate a license that was persisted BEFORE the staging catalog moved to a
 * single installation, so it already carries more bound devices than the new
 * plan limit. Also seed a matching activation code.
 */
function seedLegacyLicense(store, { planId, installations, code }) {
  const id = crypto.randomUUID();
  const nowMs = Date.now();
  store.licenses.set(id, {
    id,
    customerId: null,
    planId,
    installations: [...installations],
    status: 'active',
    issuedAtMs: nowMs,
    expiresAtMs: nowMs + 365 * DAY_MS,
    graceUntilMs: nowMs + 365 * DAY_MS,
    refreshTokenHash: null,
    source: 'purchase',
    orderId: null,
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
    revokedAtMs: null,
    revokedBy: null,
    revokeReason: null,
  });
  store.activationCodes.set(sha256Hex(code), {
    id: crypto.randomUUID(),
    codeHash: sha256Hex(code),
    code,
    licenseId: id,
    customerId: null,
    orderId: null,
    createdAtMs: nowMs,
    usedAtMs: null,
    installations: [],
  });
  return store.licenses.get(id);
}

test('a new staging license enforces a single installation', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    await client.signup('single-device@example.com', 'password-123');
    const order = await client.post('/api/orders', { planId: 'monthly' });
    await client.post('/api/mock/pay', { orderId: order.body.orderId });
    const code = [...server.store.activationCodes.values()][0].code;
    const first = uuid();
    const second = uuid();

    const bound = await client.request('POST', '/api/license', {
      json: { installationId: first, activationCode: code },
    });
    assert.equal(bound.status, 200);

    const rejected = await client.request('POST', '/api/license', {
      json: { installationId: second, activationCode: code },
    });
    assert.equal(rejected.status, 409);
    assert.equal(rejected.body.code, 'installation_limit');

    const license = [...server.store.licenses.values()][0];
    assert.deepEqual(license.installations, [first], 'a second new bind must not be persisted');
  } finally {
    await server.close();
  }
});

for (const { planId, count } of [{ planId: 'monthly', count: 2 }, { planId: 'yearly', count: 3 }]) {
  test(`an existing ${planId} license with ${count} devices stays usable and takes no new bind`, async () => {
    const server = await startServer();
    try {
      const client = new Client(server.baseUrl);
      const devices = Array.from({ length: count }, () => uuid());
      const code = 'legacy-activation-code';
      const license = seedLegacyLicense(server.store, { planId, installations: devices, code });
      const newDevice = uuid();

      // Every already-bound device still resolves a signed envelope.
      for (const device of devices) {
        const lookup = await client.request('POST', '/api/license', { json: { installationId: device } });
        assert.equal(lookup.status, 200, `${device} must remain usable`);
      }

      // No deletion of previously bound installations.
      assert.deepEqual(license.installations, devices, 'persisted installations must be preserved');

      // A further device cannot bind on top of the grandfathered set.
      const rejected = await client.request('POST', '/api/license', {
        json: { installationId: newDevice, activationCode: code },
      });
      assert.equal(rejected.status, 409);
      assert.equal(rejected.body.code, 'installation_limit');
      assert.deepEqual(license.installations, devices, 'no new bind may be persisted');
      assert.deepEqual(
        [...server.store.activationCodes.values()][0].installations,
        [],
        'no new bind may be recorded against the activation code'
      );
    } finally {
      await server.close();
    }
  });
}
