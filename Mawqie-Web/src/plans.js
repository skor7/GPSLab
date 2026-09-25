// @ts-check
/**
 * Extensible plan schema.
 *
 * A plan is validated and normalized by `definePlan`. Unknown top-level fields
 * are preserved under `metadata` so the schema can grow without breaking older
 * consumers; the canonical fields below stay stable. Prices are integer minor
 * units (e.g. halalas for SAR) to avoid floating point drift.
 */

export const PLAN_SCHEMA_VERSION = 1;

const ID_PATTERN = /^[a-z0-9][a-z0-9-]{1,63}$/;

export class PlanError extends Error {
  /** @param {string[]} problems */
  constructor(problems) {
    super(`Invalid plan definition:\n- ${problems.join('\n- ')}`);
    this.name = 'PlanError';
    /** @type {string[]} */
    this.problems = problems;
  }
}

/**
 * @typedef {object} Plan
 * @property {string} id
 * @property {number} schemaVersion
 * @property {string} nameAr
 * @property {string} nameEn
 * @property {string} descriptionAr
 * @property {string} descriptionEn
 * @property {{amount: number, currency: string}} price
 * @property {number} durationDays
 * @property {number} graceDays
 * @property {{eligible: boolean, durationHours: number}} trial
 * @property {string[]} features
 * @property {number} maxInstallations
 * @property {boolean} active
 * @property {Record<string, unknown>} metadata
 */

/**
 * @param {unknown} input
 * @returns {string[]} a list of problems (empty when valid)
 */
export function validatePlan(input) {
  /** @type {string[]} */
  const problems = [];
  if (!input || typeof input !== 'object') return ['plan must be an object'];
  const plan = /** @type {Record<string, any>} */ (input);

  if (typeof plan.id !== 'string' || !ID_PATTERN.test(plan.id)) {
    problems.push('id must match /^[a-z0-9][a-z0-9-]{1,63}$/');
  }
  if (plan.schemaVersion !== undefined && plan.schemaVersion !== PLAN_SCHEMA_VERSION) {
    problems.push(`schemaVersion must be ${PLAN_SCHEMA_VERSION}`);
  }
  for (const key of ['nameAr', 'nameEn']) {
    if (typeof plan[key] !== 'string' || plan[key].trim().length === 0) {
      problems.push(`${key} is required`);
    }
  }
  if (plan.price === undefined || plan.price === null || typeof plan.price !== 'object') {
    problems.push('price is required');
  } else {
    if (!Number.isInteger(plan.price.amount) || plan.price.amount < 0) {
      problems.push('price.amount must be a non-negative integer (minor units)');
    }
    if (typeof plan.price.currency !== 'string' || !/^[A-Za-z]{3}$/.test(plan.price.currency)) {
      problems.push('price.currency must be a 3-letter currency code');
    }
  }
  if (!Number.isInteger(plan.durationDays) || plan.durationDays < 0) {
    problems.push('durationDays must be a non-negative integer');
  }
  if (plan.graceDays !== undefined && (!Number.isInteger(plan.graceDays) || plan.graceDays < 0)) {
    problems.push('graceDays must be a non-negative integer');
  }
  if (plan.trial !== undefined) {
    if (typeof plan.trial !== 'object' || plan.trial === null) {
      problems.push('trial must be an object');
    } else {
      if (typeof plan.trial.eligible !== 'boolean') problems.push('trial.eligible must be a boolean');
      if (!Number.isInteger(plan.trial.durationHours) || plan.trial.durationHours < 0) {
        problems.push('trial.durationHours must be a non-negative integer');
      }
    }
  }
  if (plan.features !== undefined && !Array.isArray(plan.features)) {
    problems.push('features must be an array');
  }
  if (plan.maxInstallations !== undefined && (!Number.isInteger(plan.maxInstallations) || plan.maxInstallations < 1)) {
    problems.push('maxInstallations must be a positive integer');
  }
  if (plan.active !== undefined && typeof plan.active !== 'boolean') {
    problems.push('active must be a boolean');
  }
  return problems;
}

/** Fields that definePlan understands natively. Everything else is metadata. */
const KNOWN_FIELDS = new Set([
  'id',
  'schemaVersion',
  'nameAr',
  'nameEn',
  'descriptionAr',
  'descriptionEn',
  'price',
  'durationDays',
  'graceDays',
  'trial',
  'features',
  'maxInstallations',
  'active',
  'metadata',
]);

/**
 * Validate and normalize a plan definition. Throws `PlanError` when invalid.
 * @param {Record<string, any>} input
 * @returns {Plan}
 */
export function definePlan(input) {
  const problems = validatePlan(input);
  if (problems.length > 0) throw new PlanError(problems);
  /** @type {Record<string, unknown>} */
  const extra = {};
  for (const [key, value] of Object.entries(input)) {
    if (!KNOWN_FIELDS.has(key)) extra[key] = value;
  }
  return Object.freeze({
    id: input.id,
    schemaVersion: PLAN_SCHEMA_VERSION,
    nameAr: String(input.nameAr).trim(),
    nameEn: String(input.nameEn).trim(),
    descriptionAr: String(input.descriptionAr || '').trim(),
    descriptionEn: String(input.descriptionEn || '').trim(),
    price: Object.freeze({
      amount: input.price.amount,
      currency: String(input.price.currency).toUpperCase(),
    }),
    durationDays: input.durationDays,
    graceDays: input.graceDays ?? 0,
    trial: Object.freeze({
      eligible: Boolean(input.trial?.eligible),
      durationHours: input.trial?.durationHours ?? 0,
    }),
    features: Object.freeze((input.features ?? []).map((value) => String(value))),
    maxInstallations: input.maxInstallations ?? 1,
    active: input.active ?? true,
    metadata: Object.freeze({ ...extra, ...(input.metadata ?? {}) }),
  });
}

/** The plan catalog: lookup, listing and trial-eligible filtering. */
export class PlanCatalog {
  /** @param {Array<Record<string, any>>} [plans] */
  constructor(plans = []) {
    /** @type {Map<string, Plan>} */
    this._plans = new Map();
    for (const plan of plans) this.add(plan);
  }

  /** @param {Record<string, any>} input */
  add(input) {
    const plan = definePlan(input);
    if (this._plans.has(plan.id)) throw new PlanError([`duplicate plan id: ${plan.id}`]);
    this._plans.set(plan.id, plan);
    return plan;
  }

  /** @param {string} id */
  get(id) {
    return this._plans.get(id) ?? null;
  }

  /** @param {string} id */
  require(id) {
    const plan = this.get(id);
    if (!plan) throw new PlanError([`unknown plan id: ${id}`]);
    return plan;
  }

  list() {
    return [...this._plans.values()];
  }

  active() {
    return this.list().filter((plan) => plan.active);
  }

  trialEligible() {
    return this.active().filter((plan) => plan.trial.eligible && plan.trial.durationHours > 0);
  }
}

/**
 * The default plan catalog for local/staging. Prices are illustrative minor
 * units and are NOT connected to a real payment processor.
 * @returns {PlanCatalog}
 */
export function defaultPlanCatalog() {
  return new PlanCatalog([
    {
      id: 'trial',
      nameAr: 'تجريبي',
      nameEn: 'Trial',
      descriptionAr: 'تجربة مجانية لمدة 24 ساعة على جهاز واحد.',
      descriptionEn: 'A free 24-hour trial on one installation.',
      price: { amount: 0, currency: 'SAR' },
      durationDays: 1,
      graceDays: 0,
      trial: { eligible: true, durationHours: 24 },
      features: ['24 ساعة', 'جهاز واحد'],
      maxInstallations: 1,
    },
    {
      id: 'monthly',
      nameAr: 'شهري',
      nameEn: 'Monthly',
      descriptionAr: 'اشتراك شهري مع فترة سماح 7 أيام.',
      descriptionEn: 'Monthly subscription with a 7-day grace window.',
      price: { amount: 1900, currency: 'SAR' },
      durationDays: 30,
      graceDays: 7,
      trial: { eligible: false, durationHours: 0 },
      features: ['30 يوم', 'جهاز واحد', 'تحديثات', 'فترة سماح 7 أيام'],
      maxInstallations: 1,
    },
    {
      id: 'yearly',
      nameAr: 'سنوي',
      nameEn: 'Yearly',
      descriptionAr: 'اشتراك سنوي مع فترة سماح 14 يومًا.',
      descriptionEn: 'Yearly subscription with a 14-day grace window.',
      price: { amount: 14900, currency: 'SAR' },
      durationDays: 365,
      graceDays: 14,
      trial: { eligible: false, durationHours: 0 },
      features: ['365 يوم', 'جهاز واحد', 'تحديثات', 'فترة سماح 14 يومًا', 'أفضل قيمة'],
      maxInstallations: 1,
    },
  ]);
}
