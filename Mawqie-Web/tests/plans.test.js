import test from 'node:test';
import assert from 'node:assert/strict';
import { definePlan, validatePlan, PlanCatalog, PlanError, defaultPlanCatalog } from '../src/plans.js';

const validPlan = {
  id: 'starter',
  nameAr: 'مبتدئ',
  nameEn: 'Starter',
  descriptionAr: 'خطة',
  descriptionEn: 'A plan',
  price: { amount: 500, currency: 'sar' },
  durationDays: 30,
  graceDays: 3,
  trial: { eligible: true, durationHours: 12 },
  features: ['a', 'b'],
  maxInstallations: 1,
};

test('a valid plan normalizes to the canonical schema', () => {
  const plan = definePlan(validPlan);
  assert.equal(plan.schemaVersion, 1);
  assert.equal(plan.price.currency, 'SAR');
  assert.equal(plan.trial.durationHours, 12);
  assert.equal(Object.isFrozen(plan), true);
});

test('invalid plans report precise problems', () => {
  assert.ok(validatePlan({ ...validPlan, id: 'Bad Id' }).length > 0);
  assert.ok(validatePlan({ ...validPlan, price: { amount: -1, currency: 'SAR' } }).length > 0);
  assert.ok(validatePlan({ ...validPlan, price: { amount: 1, currency: 's' } }).length > 0);
  assert.ok(validatePlan({ ...validPlan, durationDays: 1.5 }).length > 0);
  assert.ok(validatePlan({ ...validPlan, nameAr: '' }).length > 0);
  assert.throws(() => definePlan({ ...validPlan, id: 'x' }), PlanError);
});

test('unknown top-level fields are preserved under metadata (extensible schema)', () => {
  const plan = definePlan({ ...validPlan, seats: 5, region: 'SA', metadata: { note: 'extra' } });
  assert.equal(plan.metadata.seats, 5);
  assert.equal(plan.metadata.region, 'SA');
  assert.equal(plan.metadata.note, 'extra');
});

test('the catalog supports lookup, listing and trial filtering', () => {
  const catalog = new PlanCatalog([validPlan, { ...validPlan, id: 'paid', trial: { eligible: false, durationHours: 0 } }]);
  assert.equal(catalog.get('starter').nameEn, 'Starter');
  assert.equal(catalog.list().length, 2);
  assert.deepEqual(catalog.trialEligible().map((plan) => plan.id), ['starter']);
  assert.throws(() => catalog.add(validPlan), PlanError);
  assert.throws(() => catalog.require('missing'), PlanError);
});

test('the default catalog ships a trial, monthly and yearly plan', () => {
  const ids = defaultPlanCatalog().list().map((plan) => plan.id);
  assert.deepEqual(ids, ['trial', 'monthly', 'yearly']);
  assert.equal(defaultPlanCatalog().trialEligible()[0].id, 'trial');
});
