import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeEmail, isValidEmail, emailKey } from '../src/core/email.js';

test('normalizeEmail lowercases, trims and NFKC-folds', () => {
  assert.equal(normalizeEmail('  User@Example.COM '), 'user@example.com');
  assert.equal(normalizeEmail('ＡＢＣ@ｅｘａｍｐｌｅ.com'), 'abc@example.com');
  assert.equal(normalizeEmail('A@B.com'), 'a@b.com');
  assert.equal(normalizeEmail(null), '');
  assert.equal(normalizeEmail(42), '');
});

test('emailKey is the normalized address', () => {
  assert.equal(emailKey('  X@Y.Z '), 'x@y.z');
});

test('isValidEmail accepts normal addresses and rejects malformed ones', () => {
  assert.equal(isValidEmail('user@example.com'), true);
  assert.equal(isValidEmail('first.last+tag@sub.example.co'), true);
  assert.equal(isValidEmail('no-at-sign'), false);
  assert.equal(isValidEmail('two@@example.com'), false);
  assert.equal(isValidEmail('spaces in@example.com'), false);
  assert.equal(isValidEmail(''), false);
});

test('normalization collapses case/whitespace variants to one identity', () => {
  const variants = ['Ali@Example.com', ' ali@example.com ', 'ALI@EXAMPLE.COM'];
  const normalized = new Set(variants.map((value) => normalizeEmail(value)));
  assert.equal(normalized.size, 1);
});
