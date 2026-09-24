// @ts-check
/** Shared HTML layout, translations and escaping. Arabic is the default locale. */

export const LANGS = /** @type {const} */ (['ar', 'en']);
export const DEFAULT_LANG = 'ar';

/** @param {unknown} value */
export function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** Bilingual string helper. */
export function bi(lang, ar, en) {
  return lang === 'en' ? en : ar;
}

/** @type {Record<string, {ar: string, en: string}>} */
const T = {
  brand: { ar: 'موقع', en: 'Mawqie' },
  tagline: { ar: 'تحكم بالموقع ببساطة', en: 'Simple location control' },
  nav_home: { ar: 'الرئيسية', en: 'Home' },
  nav_pricing: { ar: 'الأسعار', en: 'Pricing' },
  nav_purchase: { ar: 'الشراء', en: 'Purchase' },
  nav_trial: { ar: 'التجربة', en: 'Trial' },
  nav_activation: { ar: 'التفعيل', en: 'Activation' },
  nav_howto: { ar: 'طريقة الاستخدام', en: 'How to Use' },
  nav_faq: { ar: 'الأسئلة الشائعة', en: 'FAQ' },
  nav_contact: { ar: 'تواصل', en: 'Contact' },
  nav_feedback: { ar: 'ملاحظات', en: 'Feedback' },
  nav_account: { ar: 'حسابي', en: 'Account' },
  nav_admin: { ar: 'الإدارة', en: 'Admin' },
  login: { ar: 'تسجيل الدخول', en: 'Sign in' },
  signup: { ar: 'إنشاء حساب', en: 'Create account' },
  logout: { ar: 'خروج', en: 'Sign out' },
  lang_toggle: { ar: 'EN', en: 'AR' },
  footer_rights: { ar: 'جميع الحقوق محفوظة', en: 'All rights reserved' },
  privacy: { ar: 'الخصوصية', en: 'Privacy' },
  terms: { ar: 'الشروط', en: 'Terms' },
  mock_notice: {
    ar: 'نسخة محلية/تجريبية — لا تتم أي عملية دفع حقيقية.',
    en: 'Local/staging build — no real payment is processed.',
  },
};

/** @param {string} lang @param {string} key */
export function t(lang, key) {
  const entry = T[key];
  if (!entry) return key;
  return lang === 'en' ? entry.en : entry.ar;
}

const NAV = [
  ['home', '/', 'nav_home'],
  ['pricing', '/pricing', 'nav_pricing'],
  ['purchase', '/purchase', 'nav_purchase'],
  ['trial', '/trial', 'nav_trial'],
  ['activation', '/activation', 'nav_activation'],
  ['howto', '/how-to-use', 'nav_howto'],
  ['faq', '/faq', 'nav_faq'],
  ['contact', '/contact', 'nav_contact'],
  ['feedback', '/feedback', 'nav_feedback'],
];

/**
 * @param {object} options
 * @param {'ar'|'en'} options.lang
 * @param {string} options.title
 * @param {string} [options.active]
 * @param {string} options.body
 * @param {string} options.csrfToken
 * @param {{email: string} | null} [options.user]
 * @param {boolean} [options.isProduction]
 * @param {string} [options.currentPath]
 * @param {string} [options.notice]
 * @param {string} [options.error]
 */
export function renderPage({ lang, title, active = '', body, csrfToken, user = null, isProduction = false, currentPath = '/', notice = '', error = '' }) {
  const dir = lang === 'en' ? 'ltr' : 'rtl';
  const otherLang = lang === 'en' ? 'ar' : 'en';
  const nav = NAV.map(([key, href, label]) => {
    const isActive = key === active ? ' class="active"' : '';
    return `<a href="${href}?lang=${lang}"${isActive}>${escapeHtml(t(lang, label))}</a>`;
  }).join('');
  const account = user
    ? `<a href="/account?lang=${lang}">${escapeHtml(t(lang, 'nav_account'))}</a><form method="post" action="/api/auth/logout?lang=${lang}" class="inline"><input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}"><button class="link" type="submit">${escapeHtml(t(lang, 'logout'))}</button></form>`
    : `<a href="/login?lang=${lang}">${escapeHtml(t(lang, 'login'))}</a>`;
  const banner = !isProduction ? `<div class="banner">${escapeHtml(t(lang, 'mock_notice'))}</div>` : '';
  const noticeHtml = notice ? `<p class="notice" role="status">${escapeHtml(notice)}</p>` : '';
  const errorHtml = error ? `<p class="error" role="alert">${escapeHtml(error)}</p>` : '';
  const userLabel = user ? `<span class="who">${escapeHtml(user.email)}</span>` : '';

  return `<!DOCTYPE html>
<html lang="${lang}" dir="${dir}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="referrer" content="strict-origin-when-cross-origin">
<title>${escapeHtml(title)} — ${escapeHtml(t(lang, 'brand'))}</title>
<link rel="stylesheet" href="/assets/app.css">
</head>
<body>
<a class="skip" href="#main">${bi(lang, 'تجاوز إلى المحتوى', 'Skip to content')}</a>
${banner}
<header class="topbar">
  <div class="wrap">
    <a class="brand" href="/?lang=${lang}"><span class="brand-mark">موقع</span><span class="brand-name">${escapeHtml(t(lang, 'brand'))}</span></a>
    <nav class="mainnav">${nav}${account}</nav>
    <div class="topbar-actions">
      ${userLabel}
      <a class="lang" href="${escapeHtml(currentPath)}?lang=${otherLang}">${escapeHtml(t(lang, 'lang_toggle'))}</a>
    </div>
  </div>
</header>
<main id="main" class="wrap">
  ${noticeHtml}${errorHtml}
  ${body}
</main>
<footer class="footer">
  <div class="wrap">
    <span>© ${new Date().getUTCFullYear()} ${escapeHtml(t(lang, 'brand'))} — ${escapeHtml(t(lang, 'footer_rights'))}</span>
    <nav>
      <a href="/privacy?lang=${lang}">${escapeHtml(t(lang, 'privacy'))}</a>
      <a href="/terms?lang=${lang}">${escapeHtml(t(lang, 'terms'))}</a>
      <a href="/contact?lang=${lang}">${escapeHtml(t(lang, 'nav_contact'))}</a>
    </nav>
  </div>
</footer>
<script src="/assets/app.js" defer></script>
</body>
</html>`;
}

/** Format integer minor units as a currency string (display only). */
export function formatPrice(lang, amount, currency) {
  const major = (amount / 100).toLocaleString(lang === 'en' ? 'en' : 'ar', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return `${major} ${currency}`;
}
