// @ts-check
/** Minimal admin pages (login + dashboard). Reuses the shared layout. */
import { escapeHtml } from './layout.js';
import { TICKET_STATUSES } from '../tickets.js';

/** @param {{lang: 'ar'|'en', csrfToken: string, error?: string}} options */
export function adminLoginBody({ lang, csrfToken, error = '' }) {
  return `
<h1>${lang === 'en' ? 'Admin sign in' : 'دخول الإدارة'}</h1>
${error ? `<p class="error">${escapeHtml(error)}</p>` : ''}
<form class="stack" method="post" action="/admin/login">
  <input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}">
  <div><label for="email">Email</label><input id="email" name="email" type="email" required autocomplete="username"></div>
  <div><label for="password">Password</label><input id="password" name="password" type="password" required autocomplete="current-password"></div>
  <button class="btn btn-primary" type="submit">${lang === 'en' ? 'Sign in' : 'دخول'}</button>
</form>`;
}

/**
 * @param {{lang: 'ar'|'en', csrfToken: string, summary: any, audit: any[]}} options
 */
export function adminDashboardBody({ lang, csrfToken, summary, audit }) {
  const counts = summary.counts;
  const licenseRows = summary.licenses
    .map((license) => `<tr>
      <td><code>${escapeHtml(license.id.slice(0, 8))}</code></td>
      <td>${escapeHtml(license.planId)}</td>
      <td>${escapeHtml(license.source)}</td>
      <td><span class="pill ${escapeHtml(license.status)}">${escapeHtml(license.status)}</span></td>
      <td>${license.installations.map((id) => `<code>${escapeHtml(String(id).slice(0, 8))}</code>`).join(' ') || '—'}</td>
      <td>${license.status === 'revoked'
        ? `<span class="muted">${escapeHtml(license.revokeReason || 'revoked')}</span>`
        : `<form method="post" action="/api/admin/licenses/${escapeHtml(license.id)}/revoke" data-json="true" data-reload="true">
             <input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}">
             <input type="hidden" name="reason" value="admin action">
             <button class="btn btn-danger" type="submit">${lang === 'en' ? 'Revoke' : 'إلغاء'}</button>
           </form>`}</td>
    </tr>`)
    .join('') || `<tr><td colspan="6" class="muted">—</td></tr>`;

  const ticketRows = summary.tickets
    .map((ticket) => `<tr>
      <td><code>${escapeHtml(ticket.id.slice(0, 8))}</code></td>
      <td>${escapeHtml(ticket.category)}</td>
      <td>${escapeHtml(ticket.email)}</td>
      <td>${escapeHtml(ticket.subject)}</td>
      <td><span class="pill ${escapeHtml(ticket.status)}">${escapeHtml(ticket.status)}</span></td>
      <td><form method="post" action="/api/admin/tickets/${escapeHtml(ticket.id)}/status" data-json="true" data-reload="true">
        <input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}">
        <select name="status">
          ${TICKET_STATUSES.map((status) => `<option value="${status}"${status === ticket.status ? ' selected' : ''}>${status}</option>`).join('')}
        </select>
        <button class="btn btn-secondary" type="submit">${lang === 'en' ? 'Update' : 'تحديث'}</button>
      </form></td>
    </tr>`)
    .join('') || `<tr><td colspan="6" class="muted">—</td></tr>`;

  const auditRows = audit
    .map((entry) => `<tr>
      <td class="muted">${escapeHtml(new Date(entry.atMs).toISOString().replace('T', ' ').slice(0, 19))}</td>
      <td>${escapeHtml(entry.action)}</td>
      <td>${escapeHtml(entry.actorType)}${entry.actorId ? ` / ${escapeHtml(entry.actorId)}` : ''}</td>
      <td>${escapeHtml(entry.targetType || '')}${entry.targetId ? ` <code>${escapeHtml(String(entry.targetId).slice(0, 8))}</code>` : ''}</td>
    </tr>`)
    .join('') || `<tr><td colspan="4" class="muted">—</td></tr>`;

  return `
<h1>${lang === 'en' ? 'Admin dashboard' : 'لوحة الإدارة'}</h1>
<div class="grid">
  <div class="card"><h3>${lang === 'en' ? 'Customers' : 'العملاء'}</h3><p class="price">${counts.customers}</p></div>
  <div class="card"><h3>${lang === 'en' ? 'Active licenses' : 'رخص نشطة'}</h3><p class="price">${counts.activeLicenses}</p></div>
  <div class="card"><h3>${lang === 'en' ? 'Paid orders' : 'طلبات مدفوعة'}</h3><p class="price">${counts.paidOrders}</p></div>
  <div class="card"><h3>${lang === 'en' ? 'Open tickets' : 'تذاكر مفتوحة'}</h3><p class="price">${counts.openTickets}</p></div>
</div>
<form method="post" action="/admin/logout"><input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}"><button class="btn btn-secondary" type="submit">${lang === 'en' ? 'Sign out' : 'خروج'}</button></form>
<h2>${lang === 'en' ? 'Licenses' : 'الرخص'}</h2>
<table><thead><tr><th>ID</th><th>Plan</th><th>Source</th><th>Status</th><th>Installations</th><th></th></tr></thead><tbody>${licenseRows}</tbody></table>
<h2>${lang === 'en' ? 'Tickets' : 'التذاكر'}</h2>
<table><thead><tr><th>ID</th><th>Type</th><th>Email</th><th>Subject</th><th>Status</th><th></th></tr></thead><tbody>${ticketRows}</tbody></table>
<h2>${lang === 'en' ? 'Audit log' : 'سجل التدقيق'}</h2>
<table><thead><tr><th>Time</th><th>Action</th><th>Actor</th><th>Target</th></tr></thead><tbody>${auditRows}</tbody></table>`;
}
