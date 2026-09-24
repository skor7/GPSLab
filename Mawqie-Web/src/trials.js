// @ts-check
/**
 * Trial eligibility and redemption.
 *
 * A trial can be claimed at most once per normalized email, at most once per
 * installation identity, and — when the caller is authenticated — at most once
 * per customer account. All three dimensions are checked against the redemption
 * history, so a signed-in customer cannot start a second trial by changing the
 * email or the installation, and a signed-in customer cannot claim against an
 * email that is not theirs (enforced by the HTTP layer before this service runs).
 * Decisions are made server-side only.
 */
import { isValidEmail, normalizeEmail } from './core/email.js';
import { recordRedemption, redemptionHistory } from './redemptions.js';

export class TrialError extends Error {
  /** @param {string} message @param {number} [status] @param {string} [code] */
  constructor(message, status = 400, code = 'trial_error') {
    super(message);
    this.name = 'TrialError';
    this.status = status;
    this.code = code;
  }
}

/**
 * Customer-facing (Arabic-first) reason messages. The stable machine `code`
 * stays in English; the human message is shown to the user.
 * @type {Record<string, string>}
 */
export const TRIAL_REASON_MESSAGES = {
  eligible: 'التجربة المجانية متاحة.',
  plan_not_trial: 'الخطة المطلوبة لا توفّر تجربة مجانية.',
  invalid_email: 'يرجى إدخال بريد إلكتروني صحيح.',
  email_already_used: 'تم استخدام التجربة المجانية مسبقًا لهذا البريد الإلكتروني.',
  installation_already_used: 'تم استخدام التجربة المجانية مسبقًا على هذا الجهاز.',
  account_already_used: 'تم استخدام التجربة المجانية مسبقًا على هذا الحساب.',
  already_licensed: 'لديك رخصة نشطة بالفعل، ولا حاجة لتجربة جديدة.',
  email_mismatch: 'البريد المدخل لا يطابق بريد حسابك المسجّل. استخدم بريد حسابك.',
};

/** @param {string} reason */
function messageFor(reason) {
  return TRIAL_REASON_MESSAGES[reason] || 'التجربة المجانية غير متاحة حاليًا.';
}

/**
 * @param {object} deps
 * @param {import('./store/store.js').Store} deps.store
 * @param {{trial: {eligible: boolean, durationHours: number}} | null} deps.plan
 * @param {string} deps.email
 * @param {string} deps.installationId
 * @param {string | null} [deps.customerId]
 * @returns {{eligible: boolean, reason: string}}
 */
export function trialEligibility({ store, plan, email, installationId, customerId = null }) {
  if (!plan || !plan.trial || !plan.trial.eligible || plan.trial.durationHours <= 0) {
    return { eligible: false, reason: 'plan_not_trial' };
  }
  const normalized = normalizeEmail(email);
  if (!isValidEmail(normalized)) {
    return { eligible: false, reason: 'invalid_email' };
  }
  const installation = String(installationId).toLowerCase();

  const history = redemptionHistory(store, {});
  // Authenticated account history participates: one trial per account, no matter
  // which email or installation the account tries next.
  if (customerId && history.some((entry) => entry.kind === 'trial' && entry.customerId === customerId)) {
    return { eligible: false, reason: 'account_already_used' };
  }
  if (history.some((entry) => entry.kind === 'trial' && entry.emailNormalized === normalized)) {
    return { eligible: false, reason: 'email_already_used' };
  }
  if (history.some((entry) => entry.kind === 'trial' && entry.installationId === installation)) {
    return { eligible: false, reason: 'installation_already_used' };
  }
  // A device that already holds a usable paid license does not need a trial.
  for (const license of store.licenses.values()) {
    if (license.status === 'active' && license.installations.includes(installation) && license.source !== 'trial') {
      return { eligible: false, reason: 'already_licensed' };
    }
  }
  return { eligible: true, reason: 'eligible' };
}

/**
 * Claim a trial. Callers must have validated `email` and `installationId`, and
 * must have already bound `email` to the authenticated account (if any).
 * @param {object} deps
 * @param {import('./store/store.js').Store} deps.store
 * @param {import('./plans.js').PlanCatalog} deps.plans
 * @param {import('./licensing/service.js').LicensingService} deps.licensing
 * @param {string} deps.planId
 * @param {string} deps.email
 * @param {string} deps.installationId
 * @param {string | null} [deps.customerId]
 * @param {string} [deps.ip]
 * @returns {{license: any, envelope: Record<string, unknown>, redemption: any, activationCode: string}}
 */
export function claimTrial({ store, plans, licensing, planId, email, installationId, customerId = null, ip = '' }) {
  const plan = plans.get(planId);
  const eligibility = trialEligibility({ store, plan, email, installationId, customerId });
  if (!eligibility.eligible) {
    const status = eligibility.reason === 'plan_not_trial' ? 404 : 409;
    throw new TrialError(messageFor(eligibility.reason), status, eligibility.reason);
  }
  const license = licensing.createTrialLicense({
    customerId,
    plan,
    installationId,
    email,
  });
  // Give the trial a usable activation code too, so a signed-in customer always
  // sees a concrete, usable result on their account page (no orphan license).
  const activationCode = licensing.createActivationCode(license, null);
  const redemption = recordRedemption(store, {
    kind: 'trial',
    email,
    installationId,
    planId,
    customerId,
    licenseId: license.id,
    orderId: null,
    ip,
  });
  const envelope = licensing.issueEnvelopeFor(license, installationId);
  return { license, envelope, redemption, activationCode };
}
