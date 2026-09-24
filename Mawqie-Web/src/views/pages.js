// @ts-check
/**
 * Arabic-first page bodies. Each function returns `{title, active, body}` where
 * `body` is the inner HTML for the shared layout.
 */
import { bi, escapeHtml, formatPrice, t } from './layout.js';

const DAY = 24 * 60 * 60 * 1000;

/** @param {'ar'|'en'} lang */
function pageTitle(lang, ar, en) {
  return bi(lang, ar, en);
}

/** @param {any} plan @param {'ar'|'en'} lang */
function planName(plan, lang) {
  return lang === 'en' ? plan.nameEn : plan.nameAr;
}

/** @param {any} plan @param {'ar'|'en'} lang */
function planDescription(plan, lang) {
  return lang === 'en' ? plan.descriptionEn : plan.descriptionAr;
}

/** @param {'ar'|'en'} lang @param {any[]} plans @param {{showTrial?: boolean}} [options] */
function planCards(lang, plans, options = {}) {
  return plans
    .map((plan) => {
      const trial = plan.trial.eligible && plan.trial.durationHours > 0;
      const cta = trial
        ? `<a class="btn btn-secondary" href="/trial?lang=${lang}">${bi(lang, 'ابدأ التجربة', 'Start trial')}</a>`
        : `<a class="btn btn-primary" href="/purchase?lang=${lang}&plan=${escapeHtml(plan.id)}">${bi(lang, 'اشترِ الآن', 'Buy now')}</a>`;
      const priceLine = plan.price.amount === 0
        ? `<div class="price">${bi(lang, 'مجاني', 'Free')}<small> / ${plan.trial.durationHours}${bi(lang, ' ساعة', 'h')}</small></div>`
        : `<div class="price">${escapeHtml(formatPrice(lang, plan.price.amount, plan.price.currency))}<small> / ${plan.durationDays}${bi(lang, ' يوم', 'd')}</small></div>`;
      return `<article class="card">
        <h3>${escapeHtml(planName(plan, lang))}</h3>
        <p class="muted">${escapeHtml(planDescription(plan, lang))}</p>
        ${priceLine}
        <ul class="features">${plan.features.map((feature) => `<li>${escapeHtml(feature)}</li>`).join('')}</ul>
        ${cta}
      </article>`;
    })
    .join('');
}

/** @param {any} license @param {'ar'|'en'} lang */
function licenseStatusPill(license, lang, nowMs) {
  let status = license.status;
  if (status === 'active') {
    if (nowMs >= license.graceUntilMs) status = 'expired';
    else if (nowMs >= license.expiresAtMs) status = 'grace';
  }
  return `<span class="pill ${escapeHtml(status)}">${escapeHtml(status)}</span>`;
}

export function homePage({ lang, user }) {
  const body = `
<section class="hero">
  <h1>${bi(lang, 'موقع — تحكم بالموقع ببساطة', 'Mawqie — simple location control')}</h1>
  <p class="lead">${bi(
    lang,
    'موقع تطبيق لاختبار المواقع على أجهزة تملكها وتصرّح لك بذلك. اشترِ، فعّل، وأدر اشتراكك من هنا.',
    'Mawqie is a location-testing tool for devices you own and are authorized to modify. Buy, activate and manage your subscription here.'
  )}</p>
  <div class="actions">
    <a class="btn btn-primary" href="/trial?lang=${lang}">${bi(lang, 'جرّب مجانًا', 'Try free')}</a>
    <a class="btn btn-secondary" href="/pricing?lang=${lang}">${bi(lang, 'عرض الأسعار', 'See pricing')}</a>
  </div>
</section>
<div class="grid">
  <article class="card"><h3>${bi(lang, 'تفعيل فوري', 'Instant activation')}</h3><p class="muted">${bi(lang, 'يصدر الخادم رخصة موقّعة بعد تأكيد الدفع فقط.', 'The server issues a signed license only after payment is confirmed.')}</p></article>
  <article class="card"><h3>${bi(lang, 'تجربة عادلة', 'Fair trial')}</h3><p class="muted">${bi(lang, 'تجربة واحدة لكل بريد ولكل جهاز.', 'One trial per email and per installation.')}</p></article>
  <article class="card"><h3>${bi(lang, 'دعم مباشر', 'Direct support')}</h3><p class="muted">${bi(lang, 'تواصل معنا أو أرسل ملاحظاتك في أي وقت.', 'Contact us or send feedback any time.')}</p></article>
</div>
<p class="muted">${bi(lang, 'هذه نسخة محلية/تجريبية. لا تتم أي عملية دفع حقيقية.', 'This is a local/staging build. No real payment is processed.')}</p>`;
  return { title: bi(lang, 'الرئيسية', 'Home'), active: 'home', body };
}

export function pricingPage({ lang, plans }) {
  const body = `
<h1>${bi(lang, 'الأسعار', 'Pricing')}</h1>
<p class="lead">${bi(lang, 'خطط واضحة ومرنة. الأسعار لأغراض العرض في النسخة المحلية.', 'Clear, flexible plans. Prices are display-only in this local build.')}</p>
<div class="grid">${planCards(lang, plans)}</div>
<p class="muted">${bi(lang, 'فترة السماح تمنحك وقتًا لتجديد الاشتراك دون انقطاع.', 'The grace window gives you time to renew without interruption.')}</p>`;
  return { title: bi(lang, 'الأسعار', 'Pricing'), active: 'pricing', body };
}

export function purchasePage({ lang, plans, user, csrfToken, isProduction }) {
  const planOptions = plans
    .filter((plan) => plan.price.amount > 0)
    .map((plan) => `<option value="${escapeHtml(plan.id)}">${escapeHtml(planName(plan, lang))} — ${escapeHtml(formatPrice(lang, plan.price.amount, plan.price.currency))}</option>`)
    .join('');
  const authBlock = user
    ? `<form class="stack" method="post" action="/api/orders?lang=${lang}" data-json="true">
        <input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}">
        <div><label for="plan">${bi(lang, 'الخطة', 'Plan')}</label><select id="plan" name="planId" required>${planOptions}</select></div>
        <button class="btn btn-primary" type="submit">${bi(lang, 'إنشاء طلب', 'Create order')}</button>
        <p class="muted">${bi(lang, 'بعد إنشاء الطلب أكمل الدفع من صفحة حسابك.', 'After creating the order, complete payment from your account page.')}</p>
      </form>`
    : `<div class="card"><p>${bi(lang, 'سجّل الدخول أو أنشئ حسابًا لإتمام الشراء.', 'Sign in or create an account to purchase.')}</p>
        <div class="actions"><a class="btn btn-primary" href="/login?lang=${lang}">${t(lang, 'login')}</a><a class="btn btn-secondary" href="/signup?lang=${lang}">${t(lang, 'signup')}</a></div></div>`;
  const payNote = isProduction
    ? ''
    : `<p class="muted">${bi(lang, 'في هذه النسخة التجريبية يمكنك إتمام الدفع الوهمي من صفحة الحساب.', 'In this staging build you can complete the mock payment from your account page.')}</p>`;
  const body = `
<h1>${bi(lang, 'الشراء', 'Purchase')}</h1>
<p class="lead">${bi(lang, 'اختر خطتك وأنشئ طلبًا. لا تُصدر الرخصة إلا بعد تأكيد الدفع من الخادم.', 'Choose a plan and create an order. A license is issued only after the server confirms payment.')}</p>
<div class="grid">${planCards(lang, plans.filter((plan) => plan.price.amount > 0))}</div>
<h2>${bi(lang, 'إنشاء طلب', 'Create an order')}</h2>
${authBlock}
${payNote}`;
  return { title: bi(lang, 'الشراء', 'Purchase'), active: 'purchase', body };
}

export function trialPage({ lang, csrfToken }) {
  const body = `
<h1>${bi(lang, 'التجربة المجانية', 'Free trial')}</h1>
<p class="lead">${bi(lang, 'تجربة واحدة لكل بريد إلكتروني ولكل جهاز. أدخل بياناتك للحصول على رخصة تجريبية موقّعة.', 'One trial per email and per installation. Enter your details to receive a signed trial license.')}</p>
<form class="stack" method="post" action="/api/trial?lang=${lang}" data-json="true">
  <input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}">
  <div><label for="email">${bi(lang, 'البريد الإلكتروني', 'Email')}</label><input id="email" name="email" type="email" required autocomplete="email"></div>
  <div><label for="installationId">${bi(lang, 'معرّف التثبيت (Installation ID)', 'Installation ID')}</label><input id="installationId" name="installationId" required placeholder="00000000-0000-0000-0000-000000000000"></div>
  <button class="btn btn-primary" type="submit">${bi(lang, 'ابدأ التجربة', 'Start trial')}</button>
</form>
<p class="muted">${bi(lang, 'يُطبّع البريد الإلكتروني (حروف صغيرة وNFKC) قبل فحص الأهلية.', 'The email is normalized (lowercase, NFKC) before the eligibility check.')}</p>`;
  return { title: bi(lang, 'التجربة', 'Trial'), active: 'trial', body };
}

export function activationPage({ lang, csrfToken, publicKey }) {
  const body = `
<h1>${bi(lang, 'التفعيل', 'Activation')}</h1>
<p class="lead">${bi(lang, 'أدخل رمز التفعيل داخل التطبيق. يمكنك هنا التحقق من رمزك واستلام مظروف الرخصة الموقّع.', 'Enter the activation code inside the app. Here you can verify your code and receive the signed license envelope.')}</p>
<form class="stack" method="post" action="/api/license?lang=${lang}" data-json="true">
  <input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}">
  <div><label for="installationId">${bi(lang, 'معرّف التثبيت', 'Installation ID')}</label><input id="installationId" name="installationId" required placeholder="00000000-0000-0000-0000-000000000000"></div>
  <div><label for="activationCode">${bi(lang, 'رمز التفعيل', 'Activation code')}</label><input id="activationCode" name="activationCode" required autocomplete="off"></div>
  <button class="btn btn-primary" type="submit">${bi(lang, 'تفعيل', 'Activate')}</button>
</form>
<h2>${bi(lang, 'مفتاح التحقق العام', 'Public verification key')}</h2>
<p class="muted">${bi(lang, 'هذا المفتاح العام يُوضع في إعدادات التطبيق. لا يُشارَك المفتاح الخاص أبدًا.', 'This public key goes into the app configuration. The private key is never shared.')}</p>
<code class="mono">${escapeHtml(publicKey || '—')}</code>`;
  return { title: bi(lang, 'التفعيل', 'Activation'), active: 'activation', body };
}

export function howToPage({ lang }) {
  const steps = [
    [bi(lang, 'ثبّت التطبيق', 'Install the app'), bi(lang, 'ثبّت نسخة موقع على الجهاز الذي تملكه.', 'Install the Mawqie build on a device you own.')],
    [bi(lang, 'اختر خطة', 'Choose a plan'), bi(lang, 'اشترِ من صفحة الشراء أو ابدأ تجربة مجانية.', 'Purchase from the purchase page or start a free trial.')],
    [bi(lang, 'أكمل الدفع', 'Complete payment'), bi(lang, 'في النسخة التجريبية يتم الدفع الوهمي من صفحة الحساب.', 'In staging, complete the mock payment from your account page.')],
    [bi(lang, 'فعّل', 'Activate'), bi(lang, 'أدخل رمز التفعيل ومعرّف التثبيت داخل التطبيق.', 'Enter the activation code and installation ID inside the app.')],
    [bi(lang, 'استخدم', 'Use it'), bi(lang, 'يُفتح المحرك فقط عند وجود رخصة صالحة وموقّعة.', 'The engine unlocks only with a valid, signed license.')],
  ];
  const body = `
<h1>${bi(lang, 'طريقة الاستخدام', 'How to use')}</h1>
<ol class="steps">${steps.map(([title, text]) => `<li><h3>${escapeHtml(title)}</h3><p class="muted">${escapeHtml(text)}</p></li>`).join('')}</ol>
<p class="muted">${bi(lang, 'التطبيق مغلق افتراضيًا ولا يعمل بدون رخصة موقّعة.', 'The app is fail-closed and never runs without a signed license.')}</p>`;
  return { title: bi(lang, 'طريقة الاستخدام', 'How to use'), active: 'howto', body };
}

export function faqPage({ lang }) {
  const items = [
    [bi(lang, 'هل هذه عملية دفع حقيقية؟', 'Is this a real payment?'), bi(lang, 'لا. هذه نسخة محلية/تجريبية ولا تتم أي عملية دفع حقيقية.', 'No. This is a local/staging build and no real payment is processed.')],
    [bi(lang, 'كيف تُصدر الرخصة؟', 'How is a license issued?'), bi(lang, 'يصدرها الخادم بعد التحقق من توقيع الدفع، ولا يمكن للعميل إصدارها بنفسه.', 'The server issues it after verifying the payment webhook; the client cannot mint one.')],
    [bi(lang, 'كم مرة يمكنني استخدام التجربة؟', 'How many trials can I use?'), bi(lang, 'مرة واحدة لكل بريد إلكتروني ومرة واحدة لكل معرّف تثبيت.', 'Once per email address and once per installation ID.')],
    [bi(lang, 'ماذا لو انتهى الاشتراك؟', 'What if my subscription expires?'), bi(lang, 'يدخل التطبيق حالة السماح إن كانت مفعّلة، ثم يقفل تلقائيًا.', 'The app enters the grace state if enabled, then locks automatically.')],
    [bi(lang, 'كيف أراجع استخدامي؟', 'How do I review my usage?'), bi(lang, 'من صفحة حسابي يمكنك رؤية الطلبات والرخص والتذاكر.', 'From your account page you can see orders, licenses and tickets.')],
  ];
  const body = `
<h1>${bi(lang, 'الأسئلة الشائعة', 'Frequently asked questions')}</h1>
${items.map(([q, a]) => `<details><summary>${escapeHtml(q)}</summary><p class="muted">${escapeHtml(a)}</p></details>`).join('')}`;
  return { title: bi(lang, 'الأسئلة الشائعة', 'FAQ'), active: 'faq', body };
}

/** The six ticket category options, in display order. */
export const TICKET_CATEGORY_LABELS = [
  ['general', 'استفسار عام', 'General'],
  ['technical', 'مشكلة تقنية', 'Technical'],
  ['billing', 'الدفع والفواتير', 'Billing'],
  ['activation', 'التفعيل والرخصة', 'Activation'],
  ['suggestion', 'اقتراح', 'Suggestion'],
  ['other', 'أخرى', 'Other'],
];

/** @param {{lang: 'ar'|'en', csrfToken: string, category: string, user: any}} options */
function ticketForm({ lang, csrfToken, category, user }) {
  const emailValue = user ? user.email : '';
  const options = TICKET_CATEGORY_LABELS
    .map(([value, ar, en]) => `<option value="${value}"${value === category ? ' selected' : ''}>${bi(lang, ar, en)}</option>`)
    .join('');
  return `<form class="stack" method="post" action="/api/tickets?lang=${lang}" data-json="true">
  <input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}">
  <div><label for="category">${bi(lang, 'التصنيف', 'Category')}</label><select id="category" name="category" required>${options}</select></div>
  <div><label for="name">${bi(lang, 'الاسم', 'Name')}</label><input id="name" name="name" required maxlength="120"></div>
  <div><label for="email">${bi(lang, 'البريد الإلكتروني', 'Email')}</label><input id="email" name="email" type="email" required value="${escapeHtml(emailValue)}" autocomplete="email"></div>
  <div><label for="subject">${bi(lang, 'الموضوع', 'Subject')}</label><input id="subject" name="subject" required maxlength="160"></div>
  <div><label for="message">${bi(lang, 'الرسالة', 'Message')}</label><textarea id="message" name="message" required maxlength="4000"></textarea></div>
  <button class="btn btn-primary" type="submit">${bi(lang, 'إرسال', 'Send')}</button>
</form>`;
}

export function contactPage({ lang, csrfToken, user }) {
  const body = `
<h1>${bi(lang, 'تواصل معنا', 'Contact us')}</h1>
<p class="lead">${bi(lang, 'أرسل استفسارك وسنعود إليك عبر البريد الإلكتروني.', 'Send your enquiry and we will get back to you by email.')}</p>
${ticketForm({ lang, csrfToken, category: 'general', user })}`;
  return { title: bi(lang, 'تواصل', 'Contact'), active: 'contact', body };
}

export function feedbackPage({ lang, csrfToken, user }) {
  const body = `
<h1>${bi(lang, 'الملاحظات', 'Feedback')}</h1>
<p class="lead">${bi(lang, 'رأيك يساعدنا على التحسين.', 'Your feedback helps us improve.')}</p>
${ticketForm({ lang, csrfToken, category: 'suggestion', user })}`;
  return { title: bi(lang, 'ملاحظات', 'Feedback'), active: 'feedback', body };
}

export function privacyPage({ lang }) {
  const body = `
<h1>${bi(lang, 'سياسة الخصوصية', 'Privacy policy')}</h1>
<p class="lead">${bi(lang, 'نحن نجمع الحد الأدنى من البيانات اللازمة لتشغيل الخدمة.', 'We collect the minimum data needed to operate the service.')}</p>
<h2>${bi(lang, 'ما نجمعه', 'What we collect')}</h2>
<ul class="features">
  <li>${bi(lang, 'البريد الإلكتروني (مُطبّع) لإنشاء الحساب وفحص أهلية التجربة.', 'Email address (normalized) for account creation and trial eligibility.')}</li>
  <li>${bi(lang, 'معرّف التثبيت لربط الرخصة بالجهاز.', 'Installation ID to bind a license to a device.')}</li>
  <li>${bi(lang, 'سجل الطلبات والرخص والتذاكر لدعم العملاء.', 'Order, license and ticket history for customer support.')}</li>
</ul>
<h2>${bi(lang, 'ما لا نجمعه', 'What we do not collect')}</h2>
<p class="muted">${bi(lang, 'لا نجمع إحداثيات حقيقية أو بيانات الموقع الفعلية. لا نستخدم كوكيز تتبّع أو إعلانات.', 'We do not collect real coordinates or actual location data. We use no tracking or advertising cookies.')}</p>
<h2>${bi(lang, 'الأمان', 'Security')}</h2>
<p class="muted">${bi(lang, 'كلمات المرور مُشفّرة بـ scrypt، والجلسات مخزّنة كتجزئات، ويُتحقق من توقيع كل عملية دفع على الخادم.', 'Passwords are scrypt-hashed, sessions are stored hashed, and every payment webhook is signature-verified server-side.')}</p>`;
  return { title: bi(lang, 'الخصوصية', 'Privacy'), active: '', body };
}

export function termsPage({ lang }) {
  const body = `
<h1>${bi(lang, 'شروط الاستخدام', 'Terms of use')}</h1>
<p class="lead">${bi(lang, 'باستخدامك موقع فأنت توافق على هذه الشروط.', 'By using Mawqie you agree to these terms.')}</p>
<h2>${bi(lang, 'الاستخدام المصرّح', 'Authorized use')}</h2>
<p class="muted">${bi(lang, 'يُستخدم التطبيق فقط على أجهزة تملكها أو لديك تصريح صريح باختبارها.', 'Use the app only on devices you own or are explicitly authorized to test.')}</p>
<h2>${bi(lang, 'الاشتراكات', 'Subscriptions')}</h2>
<p class="muted">${bi(lang, 'تُصدر الرخصة بعد تأكيد الدفع. في هذه النسخة المحلية لا تتم مدفوعات حقيقية.', 'Licenses are issued after payment confirmation. This local build processes no real payments.')}</p>
<h2>${bi(lang, 'إساءة الاستخدام', 'Misuse')}</h2>
<p class="muted">${bi(lang, 'يُحظر استخدام الخدمة للاحتيال أو انتهاك حقوق الآخرين، وقد تُلغى الرخصة عند الإساءة.', 'Using the service for fraud or to violate others is prohibited and a license may be revoked for misuse.')}</p>`;
  return { title: bi(lang, 'الشروط', 'Terms'), active: '', body };
}

export function loginPage({ lang, csrfToken, mode = 'login' }) {
  const isSignup = mode === 'signup';
  const body = `
<h1>${isSignup ? bi(lang, 'إنشاء حساب', 'Create account') : bi(lang, 'تسجيل الدخول', 'Sign in')}</h1>
<form class="stack" method="post" action="${isSignup ? `/api/auth/signup?lang=${lang}` : `/api/auth/login?lang=${lang}`}" data-json="true" data-reload="true">
  <input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}">
  <div><label for="email">${bi(lang, 'البريد الإلكتروني', 'Email')}</label><input id="email" name="email" type="email" required autocomplete="email"></div>
  ${isSignup ? `<div><label for="displayName">${bi(lang, 'الاسم', 'Name')}</label><input id="displayName" name="displayName" maxlength="120"></div>` : ''}
  <div><label for="password">${bi(lang, 'كلمة المرور', 'Password')}</label><input id="password" name="password" type="password" required minlength="8" autocomplete="${isSignup ? 'new-password' : 'current-password'}"></div>
  <button class="btn btn-primary" type="submit">${isSignup ? t(lang, 'signup') : t(lang, 'login')}</button>
</form>
<p class="muted">${isSignup
    ? bi(lang, 'لديك حساب؟', 'Already have an account?') + ` <a href="/login?lang=${lang}">${t(lang, 'login')}</a>`
    : bi(lang, 'ليس لديك حساب؟', 'No account yet?') + ` <a href="/signup?lang=${lang}">${t(lang, 'signup')}</a>`}</p>`;
  return { title: isSignup ? bi(lang, 'إنشاء حساب', 'Create account') : bi(lang, 'تسجيل الدخول', 'Sign in'), active: '', body };
}

export function accountPage({ lang, csrfToken, user, orders, licenses, tickets, isProduction }) {
  const nowMs = Date.now();
  const orderRows = orders.length
    ? orders.map((order) => `<tr>
        <td><code>${escapeHtml(order.id.slice(0, 8))}</code></td>
        <td>${escapeHtml(order.planId)}</td>
        <td>${escapeHtml(formatPrice(lang, order.amount, order.currency))}</td>
        <td><span class="pill ${escapeHtml(order.status)}">${escapeHtml(order.status)}</span></td>
        <td>${order.status === 'pending' && !isProduction
          ? `<form method="post" action="/api/mock/pay?lang=${lang}" data-json="true" data-reload="true"><input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}"><input type="hidden" name="orderId" value="${escapeHtml(order.id)}"><button class="btn btn-secondary" type="submit">${bi(lang, 'دفع تجريبي', 'Mock pay')}</button></form>`
          : '<span class="muted">—</span>'}</td>
      </tr>`).join('')
    : `<tr><td colspan="5" class="muted">${bi(lang, 'لا توجد طلبات.', 'No orders.')}</td></tr>`;

  const licenseRows = licenses.length
    ? licenses.map((license) => {
        const codes = license.activationCodes.map((code) => `<code>${escapeHtml(code)}</code>`).join(' ');
        return `<tr>
        <td><code>${escapeHtml(license.id.slice(0, 8))}</code></td>
        <td>${escapeHtml(license.planId)}</td>
        <td>${licenseStatusPill(license, lang, nowMs)}</td>
        <td>${escapeHtml(new Date(license.expiresAtMs).toISOString().slice(0, 10))}</td>
        <td>${codes || '<span class="muted">—</span>'}</td>
      </tr>`;
      }).join('')
    : `<tr><td colspan="5" class="muted">${bi(lang, 'لا توجد رخص.', 'No licenses.')}</td></tr>`;

  const ticketRows = tickets.length
    ? tickets.map((ticket) => `<tr>
        <td><code>${escapeHtml(ticket.id.slice(0, 8))}</code></td>
        <td>${escapeHtml(ticket.category)}</td>
        <td>${escapeHtml(ticket.subject)}</td>
        <td><span class="pill ${escapeHtml(ticket.status)}">${escapeHtml(ticket.status)}</span></td>
      </tr>`).join('')
    : `<tr><td colspan="4" class="muted">${bi(lang, 'لا توجد تذاكر.', 'No tickets.')}</td></tr>`;

  const body = `
<h1>${bi(lang, 'حسابي', 'My account')}</h1>
<p class="muted">${escapeHtml(user.email)}</p>
<h2>${bi(lang, 'الطلبات', 'Orders')}</h2>
<table><thead><tr><th>ID</th><th>${bi(lang, 'الخطة', 'Plan')}</th><th>${bi(lang, 'المبلغ', 'Amount')}</th><th>${bi(lang, 'الحالة', 'Status')}</th><th></th></tr></thead><tbody>${orderRows}</tbody></table>
<h2>${bi(lang, 'الرخص', 'Licenses')}</h2>
<table><thead><tr><th>ID</th><th>${bi(lang, 'الخطة', 'Plan')}</th><th>${bi(lang, 'الحالة', 'Status')}</th><th>${bi(lang, 'تنتهي', 'Expires')}</th><th>${bi(lang, 'رمز التفعيل', 'Activation code')}</th></tr></thead><tbody>${licenseRows}</tbody></table>
<h2>${bi(lang, 'التذاكر', 'Tickets')}</h2>
<table><thead><tr><th>ID</th><th>${bi(lang, 'التصنيف', 'Category')}</th><th>${bi(lang, 'الموضوع', 'Subject')}</th><th>${bi(lang, 'الحالة', 'Status')}</th></tr></thead><tbody>${ticketRows}</tbody></table>`;
  return { title: bi(lang, 'حسابي', 'My account'), active: '', body };
}

export function notFoundPage({ lang }) {
  const body = `<h1>404</h1><p class="lead">${bi(lang, 'الصفحة غير موجودة.', 'Page not found.')}</p><a class="btn btn-secondary" href="/?lang=${lang}">${t(lang, 'nav_home')}</a>`;
  return { title: '404', active: '', body };
}

export { licenseStatusPill, planCards, DAY };
