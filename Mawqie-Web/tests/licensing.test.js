import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { loadKeyMaterial, signEnvelope, verifyEnvelope } from '../src/licensing/signing.js';
import { LocalLicenseIssuer, licenseStatusAt } from '../src/licensing/issuer.js';

const CONFIG = { licenseIssuer: 'GPSLab', licenseAudience: 'GPSLab-iOS' };

function license(overrides = {}) {
  const base = 1_700_000_000_000;
  return {
    id: 'license-1',
    customerId: 'customer-1',
    planId: 'monthly',
    installations: [],
    status: 'active',
    issuedAtMs: base,
    expiresAtMs: base + 1000,
    graceUntilMs: base + 2000,
    refreshTokenHash: null,
    source: 'purchase',
    orderId: null,
    createdAtMs: base,
    updatedAtMs: base,
    revokedAtMs: null,
    revokedBy: null,
    revokeReason: null,
    ...overrides,
  };
}

test('the public key is an exact 91-byte P-256 SPKI', () => {
  const material = loadKeyMaterial({ isProduction: false });
  const der = Buffer.from(material.publicKeyBase64Spki, 'base64');
  assert.equal(der.length, 91);
  assert.equal(der[26], 0x04);
  assert.equal(material.ephemeral, true);
});

test('sign/verify round-trips and rejects tampering', () => {
  const material = loadKeyMaterial({ isProduction: false });
  const claims = { entitlementId: 'e', installationId: 'i', plan: 'monthly', status: 'active', issuedAt: 1, expiresAt: 2, graceUntil: 0, issuer: 'x', audience: 'y' };
  const envelope = signEnvelope(claims, material.privateKey, 'refresh-1');
  assert.equal(verifyEnvelope(envelope, material.publicKey).entitlementId, 'e');
  const tampered = { ...envelope, payload: Buffer.from(JSON.stringify({ ...claims, plan: 'yearly' })).toString('base64url') };
  assert.equal(verifyEnvelope(tampered, material.publicKey), null);
});

test('a production config without a PEM is refused', () => {
  assert.throws(() => loadKeyMaterial({ isProduction: true }), /required in production/);
});

test('a provided PEM is used instead of an ephemeral key', () => {
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  const spki = crypto.createPublicKey(privateKey).export({ type: 'spki', format: 'der' }).toString('base64');
  const material = loadKeyMaterial({ isProduction: true, licensePrivateKeyPem: pem, licenseExpectedPublicKey: spki });
  assert.equal(material.ephemeral, false);
});

test('production local signing requires the embedded-key pin', () => {
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  // Without the pin there is no proof the host app can verify the key, so a
  // production local signer must refuse rather than issue unverifiable licenses.
  assert.throws(
    () => loadKeyMaterial({ isProduction: true, licensePrivateKeyPem: pem }),
    /LICENSE_EXPECTED_PUBLIC_KEY/
  );
});

test('an expected public key pin rejects a mismatched signing key', () => {
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  const otherPublic = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
    .publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  assert.throws(
    () => loadKeyMaterial({ isProduction: true, licensePrivateKeyPem: pem, licenseExpectedPublicKey: otherPublic }),
    /does not match/
  );
  const spki = crypto.createPublicKey(privateKey).export({ type: 'spki', format: 'der' }).toString('base64');
  const material = loadKeyMaterial({ isProduction: true, licensePrivateKeyPem: pem, licenseExpectedPublicKey: spki });
  assert.equal(material.publicKeyBase64Spki, spki);
});

test('time-derived status follows active -> grace -> expired, and revoked wins', () => {
  const now = { value: 1_700_000_000_000 };
  const record = license();
  assert.equal(licenseStatusAt(record, now.value), 'active');
  assert.equal(licenseStatusAt(record, record.expiresAtMs), 'grace');
  assert.equal(licenseStatusAt(record, record.graceUntilMs), 'expired');
  assert.equal(licenseStatusAt(license({ status: 'revoked' }), now.value), 'revoked');
});

test('issued claims match the GPSLab wire contract', () => {
  const material = loadKeyMaterial({ isProduction: false });
  const nowMs = 1_700_000_000_000;
  const issuer = new LocalLicenseIssuer({ config: CONFIG, keyMaterial: material, now: () => nowMs });
  const envelope = issuer.issue(license(), 'install-1', 'refresh-token');
  const claims = verifyEnvelope(envelope, material.publicKey);
  assert.equal(envelope.version, 1);
  assert.equal(envelope.alg, 'ES256');
  assert.equal(envelope.refreshToken, 'refresh-token');
  assert.equal(claims.entitlementId, 'license-1');
  assert.equal(claims.installationId, 'install-1');
  assert.equal(claims.status, 'active');
  assert.equal(claims.issuer, 'GPSLab');
  assert.equal(claims.audience, 'GPSLab-iOS');
  assert.ok(claims.issuedAt <= claims.expiresAt);
});

test('a grace envelope always carries a real graceUntil window', () => {
  const material = loadKeyMaterial({ isProduction: false });
  const record = license();
  const issuer = new LocalLicenseIssuer({ config: CONFIG, keyMaterial: material, now: () => record.expiresAtMs + 1 });
  const claims = verifyEnvelope(issuer.issue(record, 'install-1'), material.publicKey);
  assert.equal(claims.status, 'grace');
  assert.ok(claims.graceUntil > claims.expiresAt);
});
