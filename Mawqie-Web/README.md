# Mawqie-Web (موقع)

A **separate, clean local/staging web portal** for the Mawqie (موقع) iOS product.
It provides Arabic-first marketing and account pages, trial eligibility, a mock
payment pipeline, server-side license issuance and an admin dashboard.

> This app is intentionally **isolated** from the GPSLab Objective-C project. It
> does not modify, reimplement or depend on the dylib. The GPSLab source tree is
> untouched by this deliverable.

## Status: what is proven and what is not

| Area | Status |
|---|---|
| Portal pages, accounts, sessions, CSRF, rate limiting, tickets, admin | Implemented + covered by automated tests |
| Trial eligibility (normalized email + installation identity + authenticated account) + redemption history | Implemented + tested. This is **best-effort duplicate prevention, not a strong identity check** (see "Trial eligibility is not verified identity"). |
| Mock payment provider state machine + authoritative signed webhook | Implemented + tested |
| Server-side entitlement envelope (ES256, GPSLab wire contract) | Implemented; signature verified in tests with an independent verifier |
| **Compatibility with an "existing license backend"** | **NOT proven — no such backend exists in this repository.** The remote path is a documented, fail-closed adapter seam (issue / verify / revoke, with optional pinned-key signature verification) covered by automated tests against a local stand-in backend; it is still not proven against a real backend (see "Integration limitations"). |
| Real payments | **Not implemented and not claimed.** The only provider is a mock. |
| Real email delivery | **Not implemented.** Email is an adapter seam; the default is a console provider. |
| **Production deployment** | **Refused by design.** Production startup fails closed while the store, payment provider and license integration are staging-only. |
| **Email verification / account ownership** | **NOT implemented.** Email addresses are normalized, never verified. |
| **Strong duplicate-trial prevention** | **NOT achieved.** Email/installation values are attacker-supplied; only an authenticated account is a durable identity. |

## Requirements

- **Node.js >= 20** (developed and tested on Node 24). No network access and no
  third-party packages are required — everything uses Node built-ins only.

## Quick start (local)

```sh
cd Mawqie-Web
npm test          # run the automated test suite (119 tests)
npm run check     # syntax/parse gate for every source and test file
npm start         # start the portal on http://localhost:3000
```

With no configuration, the server runs in development mode: it generates
ephemeral `SESSION_SECRET`/`WEBHOOK_SECRET` values and an ephemeral P-256 license
signing key, enables mock payments, and leaves admin login disabled. Copy
`.env.example` and export the variables you need (the app does **not** auto-load
`.env`).

## Scripts

| Script | Purpose |
|---|---|
| `npm start` | Run the HTTP server (`src/server.js`). |
| `npm run dev` | Same with `--watch`. |
| `npm test` | `node --test` over `tests/*.test.js`. |
| `npm run check` | Parses every `.js` file with `node --check` (the static gate). |
| `node scripts/hash-password.js "…"` | Produce an `ADMIN_PASSWORD_HASH` (scrypt). |

## Configuration

All configuration is read from environment variables. See `.env.example`.

| Variable | Notes |
|---|---|
| `NODE_ENV` | `production` enables all strict checks. |
| `PORT`, `BASE_URL` | `BASE_URL` must be `https://` in production. |
| `TRUST_PROXY` | Set to `1` only behind a trusted reverse proxy that sets `X-Forwarded-Proto`. |
| `COOKIE_SECURE` | Defaults to `true` in production; must not be disabled there. |
| `SESSION_SECRET` | **Required in production.** |
| `WEBHOOK_SECRET` | **Required in production.** Signs/verifies payment webhooks. |
| `ADMIN_EMAIL`, `ADMIN_PASSWORD_HASH` | **Required in production.** scrypt hash only. |
| `LICENSE_MODE` | `local` (this server signs) or `remote` (unverified adapter seam; **refused in production**). |
| `LICENSE_PRIVATE_KEY_PEM` | EC P-256 private key. **Required in production** when `LICENSE_MODE=local`. Never commit it. |
| `LICENSE_BACKEND_URL` | Required when `LICENSE_MODE=remote`. |
| `LICENSE_EXPECTED_PUBLIC_KEY` | Pin (base64 SPKI) of the host app's embedded `GPSLabLicensePublicKey`. Startup fails if the signing key's public key does not match. **Required in production** when `LICENSE_MODE=local`, so the server can never issue a license the app cannot verify. |
| `LICENSE_ISSUER`, `LICENSE_AUDIENCE`, `LICENSE_GRACE_SECONDS` | Envelope claims. Defaults are `GPSLab` / `GPSLab-iOS`, matching `Source/GPSLabLicenseBuildConfig.h`. |
| `ALLOW_MOCK_PAYMENTS` | Defaults on outside production; **must be off in production**. |
| `NOTIFY_CHANNELS`, `NOTIFY_EMAIL_FROM`, `NOTIFY_EMAIL_ENDPOINT`, `NOTIFY_FILE_PATH` | Notification channels. |
| `DATA_FILE` | Optional JSON state file (local/staging persistence). |
| `RATE_LIMIT_WINDOW_MS`, `RATE_LIMIT_MAX` | Global limiter defaults (per-route limits are stricter). |

### Production strictness (fail closed)

`loadConfig` **refuses to start** in production unless: `SESSION_SECRET`,
`WEBHOOK_SECRET`, `ADMIN_EMAIL`+`ADMIN_PASSWORD_HASH`, and a signing key are
present; `BASE_URL` is HTTPS; `COOKIE_SECURE` is not disabled; and
`ALLOW_MOCK_PAYMENTS` is off. Error messages never include secret values.

In addition, **production is refused entirely while the components below are
staging-only**, because deploying them as production would be unsafe:

- the in-memory / single-process JSON store is not a database;
- the mock payment provider is the only provider (no real PSP);
- `LICENSE_MODE=remote` uses an unverified adapter that cannot check the remote
  signature;
- local signing without `LICENSE_EXPECTED_PUBLIC_KEY` cannot prove the host app
  can verify the issued licenses.

`createApp` re-checks the same readiness gate, so a production config cannot be
constructed in code and started around `loadConfig`. Local/staging behavior is
unchanged. This is intentional: production must not start until real
infrastructure exists.

## Routes

Pages (Arabic-first, RTL, bilingual via `?lang=en`): `/`, `/pricing`, `/purchase`,
`/trial`, `/activation`, `/how-to-use`, `/faq`, `/contact`, `/feedback`,
`/privacy`, `/terms`, `/login`, `/signup`, `/account`, plus `/admin` and
`/admin/login`.

APIs: `/api/csrf`, `/api/auth/{signup,login,logout}`, `/api/account/summary`,
`/api/trial`, `/api/orders`, `/api/tickets`, `/api/license`,
`/api/v1/license/check` (alias of `/api/license` for the Objective-C client's
built-in path), `/api/license/public-key`, `/api/admin/{summary,audit}`,
`/api/admin/licenses/:id/revoke`, `/api/admin/tickets/:id/status`,
`/webhooks/payment`, `/healthz`. The dev/staging-only aliases `/webhooks/payment/mock`
and `/api/mock/pay` are **not registered in production**.

## Security design

- **No hardcoded credentials.** Admin and signing secrets come from configuration.
- **Passwords**: scrypt (`N=16384, r=8, p=1`) with a random salt; verified in
  constant time.
- **Sessions**: opaque random tokens; only their SHA-256 hash is stored. Cookies
  are `HttpOnly`, `SameSite=Lax`, and `Secure` in production. Admin cookies use
  `SameSite=Strict`.
- **Cross-customer isolation**: every account-scoped read/write verifies
  ownership and returns `404` (not `403`) to avoid leaking existence.
- **CSRF**: double-submit cookie enforced on all cookie-authenticated mutations.
  Webhooks and the machine license endpoint authenticate by signature/token, not
  by cookie.
- **Payments**: the browser can never mark an order paid. Only a webhook whose
  raw body carries a valid HMAC-SHA256 signature (constant-time compared) is
  trusted, and the event amount/currency must match the server-held order.
  Licenses are issued **only** from a `paid` order. Refunds revoke the license.
- **Licensing**: the signing key never leaves the server. Only the public key is
  exposed (`/api/license/public-key`) for the host app's `GPSLabLicensePublicKey`.
- **Input validation**: all mutations are validated server-side with explicit
  field rules; browser attributes are convenience only.
- **Rate limiting**: fixed-window limiter on auth, trial, tickets, orders,
  license and webhook endpoints (`429` + `Retry-After`).
- **Headers**: strict CSP (no `unsafe-inline`/`unsafe-eval`), `nosniff`,
  `X-Frame-Options: DENY`, referrer policy, and HSTS in production. HTTPS is
  enforced in production (redirect for GET, `403` for other methods).
- **Trial identity binding (best-effort)**: a signed-in customer may only claim a
  trial against their own account email (a different email is rejected with
  `403 email_mismatch`), and eligibility also checks the account's redemption
  history, so a signed-in account cannot start a second trial by changing the
  email or installation. Trial claims return a signed envelope plus a usable
  activation code, and the license is attached to the account (no orphan license).
- **Tickets**: six categories (`general`, `technical`, `billing`, `activation`,
  `suggestion`, `other`) and a server-enforced `new → reviewing → answered → closed`
  status workflow.
- **Audit log**: license issuance/activation/revocation, admin logins, order and
  ticket state changes.

## Trial eligibility is not verified identity

The trial system reduces casual abuse; it is **not** a verified-identity or
strong anti-abuse control, and the README does not claim otherwise:

- **Email is never verified.** There is no confirmation link, no email ownership
  proof and no email delivery in this build. `normalizeEmail` only trims,
  NFKC-folds and lowercases.
- **The email and installation id are client-supplied.** For an unauthenticated
  claim, a new email address plus a new installation id yields another trial.
- **Only an authenticated account is durable.** Account-bound trials are checked
  against redemption history, so the same account cannot repeat a trial; but
  creating a new account is not blocked by anything stronger than the normalized
  email uniqueness check on signup.
- **Signup duplicate handling** relies on the normalized-email uniqueness check
  in the store, not on a verified mailbox.

A production-grade system would add email verification and a server-issued
installation attestation; neither exists here.

## Licensing wire contract (matches GPSLab)

`POST /api/license` (and its alias `POST /api/v1/license/check`, the path baked
into `Source/GPSLabLicenseBuildConfig.h`) accepts
`{ installationId, activationCode?, refreshToken? }` and returns the signed
envelope GPSLab verifies. The Objective-C client's request/response shape was
inspected in `Source/GPSLabLicenseManager.m` and matches this contract; the alias
exists so a build pointed at this portal works without changing client
semantics. The `issuer`/`audience` claims default to `GPSLab` / `GPSLab-iOS` to
match the app's verifier, and the signing key's public key must equal the app's
embedded `GPSLabLicensePublicKey` (pin it with `LICENSE_EXPECTED_PUBLIC_KEY`):

```json
{
  "version": 1,
  "alg": "ES256",
  "payload": "<base64url payload JSON>",
  "signature": "<base64url DER ECDSA P-256 SHA-256 signature over the payload bytes>",
  "refreshToken": "<opaque>"
}
```

Payload claims: `entitlementId`, `installationId`, `plan`, `status`
(`active|grace|expired|revoked`), `issuedAt`, `expiresAt`, `graceUntil`, `issuer`,
`audience`. The signature is DER ECDSA over the **raw payload bytes**, exactly what
`SecKeyAlgorithmECDSASignatureMessageX962SHA256` expects. Tests
verify this with an independent Node verifier.

Remote mode (`LICENSE_MODE=remote`) proxies the same operations through
`src/licensing/adapter.js`, so a future backend can be dropped in without a
frontend/API rewrite:

- **issuance / refresh / lookup** — `POST` the unchanged
  `{installationId, refreshToken?, activationCode?}` body to `LICENSE_BACKEND_URL`;
- **revocation** — `POST` `{action: "revoke", licenseId, reason?, actorId?}`;
- **verification** — when `LICENSE_EXPECTED_PUBLIC_KEY` is set, every returned
  envelope is verified (ES256 over the raw payload) before it is returned, and a bad
  signature is a hard failure; without a pin the signature cannot be checked and
  this is documented.

Every remote operation throws when `LICENSE_BACKEND_URL` is missing (fail closed).
Production startup is still refused in remote mode.

## Payment mock

`MockPaymentProvider` is a state machine
(`created → pending → processing → paid/failed → refunded`, plus
`cancelled/expired`). Outcomes are delivered as signed webhook events to the
canonical `/webhooks/payment` path. In development, `/api/mock/pay`
(authenticated + CSRF) simulates a successful payment and then routes the outcome
through the **same signature-verified webhook path**, so the mock cannot bypass
verification. Both `/api/mock/pay` and the `/webhooks/payment/mock` alias are
registered only outside production; production exposes the provider-neutral
`/webhooks/payment` only.

## Integration limitations and compatibility gap

- **There is no license backend in the GPSLab repository.** GPSLab itself ships
  only public configuration: a production endpoint and public P-256 verification
  key pinned in `Source/GPSLabLicenseBuildConfig.h`. The signing backend, sign-in
  provider and payment provider live in the separate `GPSLab-License-Server`
  deployment. Compatibility with any external license backend therefore **cannot be
  claimed or proven** from this repository alone.
- `LICENSE_MODE=remote` routes to `src/licensing/adapter.js`. It speaks the
  documented `{installationId, refreshToken?, activationCode?}` issuance contract,
  an explicit `{action:"revoke", licenseId, ...}` revocation contract, and it
  verifies the returned ES256 envelope against `LICENSE_EXPECTED_PUBLIC_KEY` when
  that pin is set (a bad signature is rejected). Without a pin it validates only
  the response shape, persists nothing, and fails closed when
  `LICENSE_BACKEND_URL` is missing. A real integration must still re-verify the
  response contract, error codes, auth and signature semantics against
  `Source/GPSLabTokenVerifier.m`; production remains refused in remote mode.
- The Objective-C verifier cannot be executed in this environment (no iOS/macOS
  Security.framework). The envelope format was matched from the source and is
  verified with an independent signer/verifier pair in tests; end-to-end device
  verification remains an integration task.
- Persistence is a single-process JSON file (or in-memory). It is not a database;
  multi-instance deployments need shared storage for sessions, rate limits and
  state.
- Email delivery is an adapter seam; no SMTP library is bundled.
- The mock provider is the only payment implementation. **No real payment is
  processed, and this build must not be presented to production customers as a
  payment surface.**
- Provisioning/deployment (TLS termination, reverse proxy, secret management,
  DNS, database, real PSP, real email provider) is **out of scope** and not
  proven by this deliverable.

## Tests

`npm test` runs 119 focused tests covering: email normalization; trial eligibility
by email, by installation and by authenticated account; trial email binding
(a signed-in customer cannot claim against another email) and the account-bound
trial result; redemption history; account sessions/auth; weak password and
duplicate-email handling; cross-customer isolation; payment provider states and
illegal transitions; webhook signature acceptance/rejection, tampering, amount
mismatch and unknown events; license-only-after-paid; idempotent webhooks;
activation/refresh/binding; the `/api/v1/license/check` client compatibility path;
refund revocation; plan schema validation and extensibility; licensing key shape,
claim contract, the production `LICENSE_EXPECTED_PUBLIC_KEY` requirement and the
mismatched-key rejection; the remote adapter boundary (fail-closed when
unconfigured, the exact issue/revoke request contracts, response caps and shape
checks, pinned-key signature verification and tamper rejection, and mode-aware
revocation); admin auth/dashboard/revocation audit; the six ticket
categories and `new → reviewing → answered → closed` workflow; rate limiting;
CSRF; server-side validation; notification channels; the production fail-closed
gate (staging store, mock provider and unverified remote adapter are refused) and
the production local-signing pin; absence of the mock payment route and the mock
webhook alias when mock payments are disabled; HTTPS enforcement; and rendering
of every required page.
