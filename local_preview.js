// Local preview: serves the WORKING-TREE code on this machine and proxies its API calls to the
// DEV Netlify function, so tests run undeployed code while every read and write lands on the
// Dev database - prod stays untouched.
//
//   node local_preview.js
//     http://localhost:8765/form   the salary-rate grid ALONE - no login, no sidebar
//     http://localhost:8765/       the full app (sign in with your Dev password)
//
// /form extracts the grid module from index.html at request time, so it always tests the
// current file byte-for-byte. Only whitelisted files are served (never .env).
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

const PORT = 8765;
const DEV_HOST = 'test--storied-griffin-6eab6b.netlify.app';

const TYPES = { '.html': 'text/html; charset=utf-8', '.webmanifest': 'application/manifest+json',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.json': 'application/json' };

function serveFile(res, rel) {
  const file = path.join(__dirname, rel);
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end('Not found'); return; }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
}

function extractGridModule() {
  const src = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
  const a = src.indexOf('// ── Statutory Salary Rates — the version grid');
  const b = src.indexOf('async function renderPbEditor(schemaId, opts) {');
  if (a < 0 || b < 0 || b < a) throw new Error('grid module not found in index.html');
  return src.slice(a, b);
}

const FORM_PAGE = `<!doctype html><html><head><meta charset="utf-8">
<title>Salary Rates — form test (Dev data)</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { --bg:#F1F4F8; --bg2:#FFFFFF; --border:#D9E1E9; --text:#0E1C28; --text2:#41505F;
          --text3:#6B7A89; --red:#FA0A11; --navy:#003057; }
  * { box-sizing:border-box; }
  body { margin:0; padding:22px; background:var(--bg); color:var(--text);
         font-family:Arial, Helvetica, sans-serif; font-size:14px; }
  .band { display:flex; align-items:baseline; gap:12px; margin-bottom:14px; }
  .band h1 { font-size:17px; color:var(--navy); margin:0; }
  .band .sub { font-size:12px; color:var(--text3); }
  .btn { font-family:inherit; font-size:13px; font-weight:600; border-radius:6px; cursor:pointer;
         padding:7px 13px; border:1px solid var(--border); background:var(--bg2); color:var(--text2); }
  .btn-sm { padding:5px 11px; font-size:12px; }
  .btn-primary { background:var(--navy); border-color:var(--navy); color:#fff; }
  .btn-secondary { background:var(--bg2); }
  .btn-ghost { background:transparent; border-color:transparent; color:var(--text3); }
  .btn:disabled { opacity:.45; cursor:default; }
  .form-control { font-family:inherit; font-size:13px; border:1px solid var(--border);
                  border-radius:6px; padding:6px 9px; background:var(--bg2); color:var(--text); }
  table { border-collapse:collapse; }
  #status { position:fixed; bottom:20px; right:20px; padding:10px 16px; border-radius:8px;
            font-size:13px; font-weight:600; display:none; z-index:9999; color:#fff; }
</style></head><body>
<div class="band"><h1>Statutory Salary Rates</h1>
  <span class="sub" id="page-sub"></span>
  <label class="sub" style="margin-left:auto;">Acting as
    <select id="acting-as" class="form-control" style="font-size:12px;padding:3px 6px;"
      onchange="currentUser.personId = +this.value; renderSalaryRateGrid();">
      <option value="1">Richard Groenewald</option>
      <option value="4105">Lesley-Anne Kleyn</option>
    </select></label>
  <span class="sub" style="background:#FEF3C7;border:1px solid #E9C46A;color:#7A5B10;
        border-radius:10px;padding:2px 9px;font-weight:700;">Test harness — saves go to the DEV database</span></div>
<table style="width:100%;"><thead id="table-head"></thead><tbody id="table-body"></tbody></table>
<div id="status"></div>
<script>
  // Just enough of the app for the module to run - same api() semantics, no login, no sidebar.
  const FN_URL = '/.netlify/functions/sb';
  let pbActiveSchema = null;
  const currentUser = { personId: 1 };            // PEOPLE id (not system_users id) - switchable above
  const can = () => true;                         // harness: every permission granted
  const pbEsc = s => String(s == null ? '' : s).replace(/[&<>"]/g,
    c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;' }[c]));
  function showStatus(msg, kind) {
    const el = document.getElementById('status');
    el.textContent = msg; el.style.background = kind === 'error' ? 'var(--red)' : '#1B7A4B';
    el.style.display = 'block'; clearTimeout(el._t); el._t = setTimeout(() => el.style.display = 'none', 3500);
  }
  const startBusy = () => {}; const stopBusy = () => {};
  function pbBackToHrGrid() { showStatus('The harness has only this form — nothing to go back to'); }
  async function api(table, method = 'GET', body = null, params = '') {
    const opts = { method, headers: { 'Content-Type': 'application/json',
      'Prefer': (method === 'POST' || method === 'PATCH') ? 'return=representation' : '',
      'X-Actor-Id': String(currentUser.personId) } };
    if (body) opts.body = JSON.stringify(body);
    const res = await fetch(FN_URL + '/' + table + (params ? '?' + params : ''), opts);
    if (!res.ok) throw new Error(res.status + ': ' + (await res.text()).slice(0, 180));
    const t = await res.text(); return t ? JSON.parse(t) : null;
  }
  const apiGet = (t, p = '') => api(t, 'GET', null, p);
  async function apiGetAll(t, p = '') {
    const PAGE = 1000, out = [];
    const tie = /(^|&)order=/.test(p) ? p.replace(/((?:^|&)order=[^&]*)/, '$1,id.asc')
                                      : p + (p ? '&' : '') + 'order=id.asc';
    for (let o = 0; ; o += PAGE) {
      const page = await api(t, 'GET', null, tie + '&limit=' + PAGE + '&offset=' + o);
      out.push(...page);
      if (page.length < PAGE) return out;
    }
  }
</script>
<script src="/rategrid.js"></script>
<script>renderSalaryRateGrid();</script>
</body></html>`;

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://localhost');

  if (u.pathname.startsWith('/.netlify/functions/')) {
    const headers = { 'Content-Type': req.headers['content-type'] || 'application/json' };
    for (const h of ['x-actor-id', 'x-real-actor-id', 'prefer']) if (req.headers[h]) headers[h] = req.headers[h];
    const up = https.request({ hostname: DEV_HOST, port: 443, path: u.pathname + u.search,
      method: req.method, headers }, r => {
      res.writeHead(r.statusCode, { 'Content-Type': r.headers['content-type'] || 'application/json' });
      r.pipe(res);
    });
    up.on('error', e => { res.writeHead(502); res.end('Proxy error: ' + e.message); });
    req.pipe(up);
    return;
  }

  if (u.pathname === '/form') { res.writeHead(200, { 'Content-Type': TYPES['.html'] }); res.end(FORM_PAGE); return; }
  if (u.pathname === '/rategrid.js') {
    try { res.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8' }); res.end(extractGridModule()); }
    catch (e) { res.writeHead(500); res.end('// ' + e.message); }
    return;
  }
  if (u.pathname === '/' || u.pathname === '/index.html') return serveFile(res, 'index.html');
  if (u.pathname === '/manifest.webmanifest') return serveFile(res, 'manifest.webmanifest');
  if (/^\/(icons|assets)\/[\w .\-']+$/.test(u.pathname)) return serveFile(res, decodeURIComponent(u.pathname.slice(1)));
  res.writeHead(404); res.end('Not found');
}).listen(PORT, () => console.log(`Focus local preview on http://localhost:${PORT} (form-only: /form) -> API to ${DEV_HOST}`));
