// @ts-check
/** Static assets served from /assets. Same-origin, no external CDN, no inline script. */

export const APP_CSS = `
:root{--bg:#111116;--panel:#19191e;--panel2:#15151a;--text:#f5f5f7;--muted:#9b9ba4;--accent:#8e5cff;--accent2:#9b62ff;--green:#30d158;--red:#ff375f;--border:#2a2a31;--radius:18px}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{background:radial-gradient(circle at 15% 0%,rgba(142,92,255,.10),transparent 34%),var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Tahoma,Arial,sans-serif;line-height:1.65}
a{color:#c9b4ff;text-decoration:none}
a:hover{text-decoration:underline}
.skip{position:absolute;inset-inline-start:-999px;top:0;background:#000;color:#fff;padding:8px 12px;z-index:50}
.skip:focus{inset-inline-start:8px}
.wrap{width:min(1080px,100% - 32px);margin-inline:auto}
.banner{background:rgba(142,92,255,.14);border-bottom:1px solid rgba(142,92,255,.32);color:#d9ccff;text-align:center;padding:8px 14px;font-size:14px}
.topbar{position:sticky;top:0;z-index:20;background:rgba(12,12,16,.94);backdrop-filter:blur(8px);border-bottom:1px solid var(--border)}
.topbar .wrap{display:flex;align-items:center;gap:14px;flex-wrap:wrap;padding:12px 0}
.brand{display:flex;align-items:center;gap:10px;color:var(--text);font-weight:800}
.brand:hover{text-decoration:none}
.brand-mark{background:linear-gradient(180deg,var(--accent2),#7a42eb);border-radius:12px;padding:6px 10px;font-size:18px}
.brand-name{font-size:18px}
.mainnav{display:flex;gap:6px;flex-wrap:wrap;align-items:center;flex:1}
.mainnav a,.mainnav .link{color:#cfcfd6;padding:7px 10px;border-radius:10px;font-size:14px}
.mainnav a.active,.mainnav a:hover{background:var(--panel);color:#fff;text-decoration:none}
.mainnav form.inline{display:inline;margin:0}
button.link{background:none;border:0;cursor:pointer;font:inherit}
.topbar-actions{display:flex;align-items:center;gap:10px}
.who{color:var(--muted);font-size:13px;max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lang{border:1px solid var(--border);border-radius:10px;padding:6px 10px;color:#fff;font-size:13px}
main{padding:28px 0 56px}
h1{font-size:clamp(26px,4vw,38px);line-height:1.2;margin:0 0 8px}
h2{font-size:22px;margin:34px 0 10px}
h3{font-size:17px;margin:0 0 6px}
p{color:#d9d9df}
.lead{color:var(--muted);font-size:17px;max-width:70ch}
.grid{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));margin:20px 0}
.card{background:var(--panel);border:1px solid var(--border);border-radius:var(--radius);padding:18px}
.card.featured{border-color:rgba(142,92,255,.65);box-shadow:0 0 0 1px rgba(142,92,255,.18) inset}
.price{font-size:26px;font-weight:800;margin:6px 0}
.price small{font-size:13px;color:var(--muted);font-weight:500}
ul.features{list-style:none;padding:0;margin:10px 0}
ul.features li{padding:5px 0;border-bottom:1px solid #23232a;color:#d6d6dd}
ul.features li:last-child{border-bottom:0}
.btn{display:inline-block;border:1px solid transparent;border-radius:13px;padding:12px 18px;font-weight:700;cursor:pointer;font:inherit;text-align:center}
.btn:hover{text-decoration:none}
.btn-primary{background:linear-gradient(180deg,var(--accent2),#7a42eb);color:#fff}
.btn-secondary{background:var(--panel2);color:#fff;border-color:var(--border)}
.btn-danger{background:#3a1420;color:#ffb3c1;border-color:#5a2233}
.btn:disabled{opacity:.5;cursor:not-allowed}
.actions{display:flex;gap:10px;flex-wrap:wrap;margin:16px 0}
form.stack{display:grid;gap:12px;max-width:520px}
label{display:block;font-size:13px;color:var(--muted);margin-bottom:5px}
input,select,textarea{width:100%;background:#0f0f12;color:#fff;border:1px solid #2d2d34;border-radius:11px;padding:11px 12px;font:inherit}
textarea{min-height:130px;resize:vertical}
input:focus,select:focus,textarea:focus{outline:2px solid rgba(142,92,255,.6);border-color:transparent}
.notice,.error{border-radius:12px;padding:11px 14px;margin:0 0 16px}
.notice{background:rgba(48,209,88,.12);border:1px solid rgba(48,209,88,.35);color:#c9f5d4}
.error{background:rgba(255,55,95,.12);border:1px solid rgba(255,55,95,.4);color:#ffc9d3}
table{width:100%;border-collapse:collapse;font-size:14px;margin:12px 0}
th,td{text-align:start;padding:9px 10px;border-bottom:1px solid #24242b;vertical-align:top}
th{color:var(--muted);font-weight:600}
code,.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;direction:ltr;unicode-bidi:embed;background:#0d0d11;border:1px solid #26262d;border-radius:8px;padding:2px 6px;font-size:13px}
.muted{color:var(--muted)}
.pill{display:inline-block;border-radius:999px;padding:3px 10px;font-size:12px;font-weight:700}
.pill.active{background:rgba(48,209,88,.15);color:#7ee39a}
.pill.revoked,.pill.failed{background:rgba(255,55,95,.15);color:#ff9fb1}
.pill.pending,.pill.open{background:rgba(142,92,255,.15);color:#c9b4ff}
.pill.paid,.pill.resolved{background:rgba(48,209,88,.15);color:#7ee39a}
.pill.refunded,.pill.closed,.pill.expired{background:#2a2a31;color:#c4c4cc}
.footer{border-top:1px solid var(--border);padding:22px 0;color:var(--muted);font-size:13px}
.footer .wrap{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}
.footer nav{display:flex;gap:14px}
details{background:var(--panel2);border:1px solid var(--border);border-radius:14px;padding:12px 14px;margin:10px 0}
summary{cursor:pointer;font-weight:700}
@media(max-width:640px){.mainnav{gap:2px}.mainnav a{padding:6px 8px;font-size:13px}.who{display:none}}
`;

export const APP_JS = `
(function(){
  // Language switch preserves the current path.
  document.querySelectorAll('a.lang').forEach(function(link){
    link.addEventListener('click', function(event){
      event.preventDefault();
      var url = new URL(window.location.href);
      url.searchParams.set('lang', link.textContent.trim().toLowerCase() === 'ar' ? 'ar' : 'en');
      window.location.href = url.toString();
    });
  });

  function csrfToken(){
    var match = document.cookie.match(/(?:^|; )mawqie_csrf=([^;]+)/);
    return match ? decodeURIComponent(match[1]) : '';
  }

  function showResult(form, message, ok){
    var box = form.querySelector('.form-result');
    if(!box){ box = document.createElement('p'); box.className='form-result'; form.appendChild(box); }
    box.className = 'form-result ' + (ok ? 'notice' : 'error');
    box.textContent = message;
  }

  // Progressive enhancement: submit forms via fetch and show JSON results inline.
  document.querySelectorAll('form[data-json]').forEach(function(form){
    form.addEventListener('submit', function(event){
      event.preventDefault();
      var button = form.querySelector('button[type=submit]');
      if(button) button.disabled = true;
      var data = new FormData(form);
      var headers = { 'Accept': 'application/json' };
      var token = csrfToken();
      if(token) headers['X-CSRF-Token'] = token;
      fetch(form.getAttribute('action'), { method:'POST', body:data, headers:headers, credentials:'same-origin' })
        .then(function(response){ return response.json().then(function(body){ return {ok:response.ok, status:response.status, body:body}; }); })
        .then(function(result){
          var message = result.body && (result.body.message || result.body.error) ? (result.body.message || result.body.error) : (result.ok ? 'OK' : 'Request failed');
          if(result.body && result.body.activationCode) message += ' — ' + result.body.activationCode;
          showResult(form, message, result.ok);
          if(result.ok && form.dataset.reload === 'true') setTimeout(function(){ window.location.reload(); }, 900);
        })
        .catch(function(){ showResult(form, 'Network error', false); })
        .finally(function(){ if(button) button.disabled = false; });
    });
  });
})();
`;
