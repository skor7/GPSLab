import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client } from './helpers.js';

const PAGES = [
  ['/', 'الرئيسية'],
  ['/pricing', 'الأسعار'],
  ['/purchase', 'الشراء'],
  ['/trial', 'التجربة'],
  ['/activation', 'التفعيل'],
  ['/how-to-use', 'طريقة الاستخدام'],
  ['/faq', 'الأسئلة الشائعة'],
  ['/contact', 'تواصل'],
  ['/feedback', 'الملاحظات'],
  ['/privacy', 'الخصوصية'],
  ['/terms', 'الشروط'],
  ['/login', 'تسجيل الدخول'],
  ['/signup', 'إنشاء حساب'],
];

test('every required page renders Arabic-first, responsive and Mawqie-branded', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    for (const [path, title] of PAGES) {
      const response = await client.get(path);
      assert.equal(response.status, 200, `${path} should return 200`);
      assert.match(response.text, /dir="rtl"/, `${path} should be RTL by default`);
      assert.match(response.text, /lang="ar"/, `${path} should declare Arabic`);
      assert.match(response.text, /viewport/, `${path} should be responsive`);
      assert.ok(response.text.includes('موقع'), `${path} should show the Mawqie brand`);
      assert.ok(response.text.includes(title), `${path} should contain its title`);
      assert.equal(response.text.includes('GPSLab'), false, `${path} must not expose the internal project name`);
      assert.equal(/unsafe-inline|unsafe-eval/.test(response.text), false, `${path} must not weaken CSP`);
    }
  } finally {
    await server.close();
  }
});

test('the English toggle renders LTR', async () => {
  const server = await startServer();
  try {
    const response = await new Client(server.baseUrl).get('/?lang=en');
    assert.equal(response.status, 200);
    assert.match(response.text, /dir="ltr"/);
    assert.ok(response.text.includes('Mawqie'));
  } finally {
    await server.close();
  }
});

test('pages carry a Content-Security-Policy without inline script', async () => {
  const server = await startServer();
  try {
    const response = await new Client(server.baseUrl).get('/');
    const csp = response.headers.get('content-security-policy');
    assert.ok(csp.includes("default-src 'self'"));
    assert.ok(csp.includes("script-src 'self'"));
    assert.equal(csp.includes('unsafe-inline'), false);
  } finally {
    await server.close();
  }
});

test('static assets are served same-origin', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const css = await client.get('/assets/app.css');
    assert.equal(css.status, 200);
    assert.match(css.headers.get('content-type'), /text\/css/);
    const js = await client.get('/assets/app.js');
    assert.equal(js.status, 200);
    assert.match(js.headers.get('content-type'), /javascript/);
  } finally {
    await server.close();
  }
});

test('the public license key endpoint exposes only public material', async () => {
  const server = await startServer();
  try {
    const response = await new Client(server.baseUrl).get('/api/license/public-key');
    assert.equal(response.status, 200);
    assert.equal(response.body.alg, 'ES256');
    assert.equal(Buffer.from(response.body.publicKey, 'base64').length, 91);
    assert.equal(JSON.stringify(response.body).includes('private'), false);
  } finally {
    await server.close();
  }
});

test('unknown pages return a 404 page', async () => {
  const server = await startServer();
  try {
    const response = await new Client(server.baseUrl).get('/does-not-exist');
    assert.equal(response.status, 404);
    assert.ok(response.text.includes('404'));
  } finally {
    await server.close();
  }
});

test('the health endpoint responds', async () => {
  const server = await startServer();
  try {
    const response = await new Client(server.baseUrl).get('/healthz');
    assert.equal(response.status, 200);
    assert.equal(response.body.status, 'ok');
  } finally {
    await server.close();
  }
});
