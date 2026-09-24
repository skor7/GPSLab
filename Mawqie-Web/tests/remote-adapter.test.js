// @ts-check
/**
 * Remote license-backend adapter boundary.
 *
 * A local HTTP server stands in for the future backend so the issue / verify /
 * revoke contract and the fail-closed rules can be proven without network access
 * to any real service.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import crypto from 'node:crypto';
import { RemoteLicenseIssuer, RemoteBackendError, isEnvelopeShape } from '../src/licensing/adapter.js';
import { loadKeyMaterial, signEnvelope, verifyEnvelope } from '../src/licensing/signing.js';
import { LicensingService, LicenseError } from '../src/licensing/service.js';
import { defaultPlanCatalog } from '../src/plans.js';
import { Store } from '../src/store/store.js';
import { startServer, testConfig, Client } from './helpers.js';

const ISSUER_CONFIG = { licenseIssuer: 'GPSLab', licenseAudience: 'GPSLab-iOS' };

/** @param {(req: http.IncomingMessage, raw: string) => {status: number, body?: any, rawBody?: string, contentType?: string}} handler */
async function startBackend(handler) {
  const received = /** @type {Array<{method: string, path: string, body: any}>} */ ([]);
  const server = http.createServer(async (req, res) => {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    received.push({ method: req.method || '', path: req.url || '', body: raw ? JSON.parse(raw) : null });
    const result = handler(req, raw);
    res.writeHead(result.status, { 'content-type': result.contentType ?? 'application/json' });
    res.end(result.rawBody ?? JSON.stringify(result.body ?? {}));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : 0;
  return {
    url: `http://127.0.0.1:${port}`,
    received,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

function configFor(url, extra = {}) {
  return { licenseBackendUrl: url, ...ISSUER_CONFIG, ...extra };
}

test('the adapter fails closed when no backend URL is configured', async () => {
  const issuer = new RemoteLicenseIssuer({
    config: configFor(''),
    fetchImpl: () => {
      throw new Error('fetch must not be reached when unconfigured');
    },
  });
  assert.equal(issuer.isConfigured(), false);
  await assert.rejects(
    () => issuer.issue({ installationId: 'i' }),
    (error) => error instanceof RemoteBackendError && error.code === 'not_configured'
  );
  await assert.rejects(
    () => issuer.revoke({ licenseId: 'L' }),
    (error) => error instanceof RemoteBackendError && error.code === 'not_configured'
  );
});

test('issuance forwards the exact GPSLab contract and returns a shape-valid envelope', async () => {
  const envelope = { version: 1, alg: 'ES256', payload: 'e30', signature: 'AA' };
  const backend = await startBackend(() => ({ status: 200, body: envelope }));
  try {
    const issuer = new RemoteLicenseIssuer({ config: configFor(backend.url) });
    const result = await issuer.issue({ installationId: 'install-1', activationCode: 'CODE', refreshToken: 'R' });
    assert.deepEqual(backend.received[0].body, {
      installationId: 'install-1',
      refreshToken: 'R',
      activationCode: 'CODE',
    });
    assert.equal(isEnvelopeShape(result), true);
    assert.equal(result.payload, 'e30');
  } finally {
    await backend.close();
  }
});

test('revocation forwards an explicit revoke action and accepts a JSON acknowledgement', async () => {
  const backend = await startBackend(() => ({ status: 200, body: { revoked: true, licenseId: 'L-1' } }));
  try {
    const issuer = new RemoteLicenseIssuer({ config: configFor(backend.url) });
    const result = await issuer.revoke({ licenseId: 'L-1', reason: 'chargeback', actorId: 'admin@example.test' });
    assert.deepEqual(backend.received[0].body, {
      action: 'revoke',
      licenseId: 'L-1',
      reason: 'chargeback',
      actorId: 'admin@example.test',
    });
    assert.equal(result.revoked, true);
  } finally {
    await backend.close();
  }
});

test('a non-200, invalid JSON, oversized or badly shaped response is rejected', async () => {
  for (const [name, backendHandler, code] of /** @type {const} */ ([
    ['status', () => ({ status: 500, body: { error: 'boom' } }), 'bad_status'],
    ['json', () => ({ status: 200, rawBody: 'not json' }), 'invalid_json'],
    ['oversized', () => ({ status: 200, rawBody: 'x'.repeat(256 * 1024 + 1) }), 'oversized'],
    ['shape', () => ({ status: 200, body: { version: 2, alg: 'ES256', payload: 'e30', signature: 'AA' } }), 'bad_envelope'],
  ])) {
    const backend = await startBackend(backendHandler);
    try {
      const issuer = new RemoteLicenseIssuer({ config: configFor(backend.url) });
      await assert.rejects(
        () => issuer.issue({ installationId: 'i' }),
        (error) => error instanceof RemoteBackendError && error.code === code,
        `expected ${name} to fail with ${code}`
      );
    } finally {
      await backend.close();
    }
  }
});

test('a pinned key verifies the remote signature and rejects tampering', async () => {
  const material = loadKeyMaterial({ isProduction: false });
  const claims = {
    entitlementId: 'e-1',
    installationId: 'install-1',
    plan: 'monthly',
    status: 'active',
    issuedAt: 1700000000,
    expiresAt: 1800000000,
    graceUntil: 0,
    issuer: 'GPSLab',
    audience: 'GPSLab-iOS',
  };
  const envelope = signEnvelope(claims, material.privateKey);
  const tampered = { ...envelope, payload: Buffer.from(JSON.stringify({ ...claims, plan: 'yearly' })).toString('base64url') };
  const backend = await startBackend(() => ({ status: 200, body: envelope }));
  const tamperBackend = await startBackend(() => ({ status: 200, body: tampered }));
  try {
    const verifyIssuer = new RemoteLicenseIssuer({ config: configFor(backend.url) });
    verifyIssuer.setPublicKeyBase64(material.publicKeyBase64Spki);
    assert.equal(verifyIssuer.publicKeyBase64(), material.publicKeyBase64Spki);
    const result = await verifyIssuer.issue({ installationId: 'install-1' });
    assert.equal(verifyIssuer.verify(result).entitlementId, 'e-1');
    assert.equal(verifyEnvelope(result, material.publicKey).plan, 'monthly');

    const tamperIssuer = new RemoteLicenseIssuer({ config: configFor(tamperBackend.url) });
    tamperIssuer.setPublicKeyBase64(material.publicKeyBase64Spki);
    await assert.rejects(
      () => tamperIssuer.issue({ installationId: 'install-1' }),
      (error) => error instanceof RemoteBackendError && error.code === 'bad_signature'
    );
  } finally {
    await backend.close();
    await tamperBackend.close();
  }
});

test('verification without a pinned key fails closed (never reports valid)', async () => {
  const material = loadKeyMaterial({ isProduction: false });
  const envelope = signEnvelope(
    { entitlementId: 'e', installationId: 'i', plan: 'monthly', status: 'active', issuedAt: 1, expiresAt: 2, graceUntil: 0, issuer: 'x', audience: 'y' },
    material.privateKey
  );
  const issuer = new RemoteLicenseIssuer({ config: configFor('https://backend.example') });
  assert.equal(issuer.verify(envelope), null);
});

test('a malformed pinned key is rejected at configuration time', () => {
  const issuer = new RemoteLicenseIssuer({ config: configFor('https://backend.example') });
  assert.throws(
    () => issuer.setPublicKeyBase64('not-a-real-spki'),
    (error) => error instanceof RemoteBackendError && error.code === 'invalid_pin_key'
  );
});

test('the licensing service dispatches revocation by mode and verifies remote envelopes', async () => {
  const backend = await startBackend(() => ({ status: 200, body: { revoked: true, licenseId: 'L-9' } }));
  const plans = defaultPlanCatalog();
  try {
    const remoteStore = new Store();
    const remoteIssuer = new RemoteLicenseIssuer({ config: configFor(backend.url) });
    const remoteService = new LicensingService({
      config: { licenseMode: 'remote' },
      store: remoteStore,
      plans,
      issuer: remoteIssuer,
      now: () => Date.now(),
    });
    const ack = await remoteService.revokeLicense('L-9', { actorType: 'admin', actorId: 'admin@example.test', reason: 'refund' });
    assert.equal(ack.revoked, true);
    assert.equal(backend.received[0].body.action, 'revoke');

    const material = loadKeyMaterial({ isProduction: false });
    const envelope = signEnvelope(
      { entitlementId: 'e', installationId: 'i', plan: 'monthly', status: 'active', issuedAt: 1, expiresAt: 2, graceUntil: 0, issuer: 'x', audience: 'y' },
      material.privateKey
    );
    const verifyIssuer = new RemoteLicenseIssuer({ config: configFor(backend.url) });
    verifyIssuer.setPublicKeyBase64(material.publicKeyBase64Spki);
    const verifyService = new LicensingService({
      config: { licenseMode: 'remote' },
      store: remoteStore,
      plans,
      issuer: verifyIssuer,
      now: () => Date.now(),
    });
    assert.equal(verifyService.verifyRemoteEnvelope(envelope).entitlementId, 'e');

    // Local mode still revokes synchronously through the same dispatch method.
    const localStore = new Store();
    const localService = new LicensingService({
      config: { licenseMode: 'local' },
      store: localStore,
      plans,
      issuer: { publicKeyBase64: () => '', isEphemeral: () => false, issue: () => ({}) },
      now: () => Date.now(),
    });
    localStore.licenses.set('L-1', { id: 'L-1', status: 'active', createdAtMs: 1, updatedAtMs: 1 });
    const local = await localService.revokeLicense('L-1', { actorType: 'admin' });
    assert.equal(local.status, 'revoked');
    assert.equal(localStore.licenses.get('L-1').status, 'revoked');
  } finally {
    await backend.close();
  }
});

test('local calls still verify remote is enabled and fail closed when unconfigured', async () => {
  const service = new LicensingService({
    config: { licenseMode: 'local' },
    store: new Store(),
    plans: defaultPlanCatalog(),
    issuer: { publicKeyBase64: () => '', isEphemeral: () => false, issue: () => ({}) },
    now: () => Date.now(),
  });
  assert.equal(service.isRemote(), false);
  await assert.rejects(
    () => service.forwardRemote({ installationId: 'i' }),
    (error) => error instanceof LicenseError && error.code === 'not_remote'
  );
  assert.throws(
    () => service.verifyRemoteEnvelope({}),
    (error) => error instanceof LicenseError && error.code === 'not_remote'
  );
  await assert.rejects(
    () => service.revokeRemote('L-1'),
    (error) => error instanceof LicenseError && error.code === 'not_remote'
  );
});

test('the app forwards the license endpoint and admin revocation in remote mode', async () => {
  const envelope = { version: 1, alg: 'ES256', payload: 'e30', signature: 'AA' };
  const backend = await startBackend(() => ({ status: 200, body: envelope }));
  const server = await startServer({
    config: testConfig({ LICENSE_MODE: 'remote', LICENSE_BACKEND_URL: backend.url }),
  });
  try {
    const client = new Client(server.baseUrl);
    const installationId = crypto.randomUUID();
    const license = await client.request('POST', '/api/license', { json: { installationId } });
    assert.equal(license.status, 200);
    assert.equal(license.body.alg, 'ES256');
    assert.deepEqual(backend.received[0].body, { installationId });

    const admin = new Client(server.baseUrl);
    await admin.adminLogin();
    const revoke = await admin.post('/api/admin/licenses/remote-license-1/revoke', { reason: 'refund' });
    assert.equal(revoke.status, 200);
    assert.equal(revoke.body.licenseId, 'remote-license-1');
    assert.equal(revoke.body.status, 'revoked');
    const revokeCall = backend.received.find((entry) => entry.body && entry.body.action === 'revoke');
    assert.ok(revokeCall);
    assert.equal(revokeCall.body.licenseId, 'remote-license-1');
  } finally {
    await server.close();
    await backend.close();
  }
});
