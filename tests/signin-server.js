// Local sign-in server (v7.10.58): the working tree, with /sb/* answered by the REAL proxy
// (supabase/functions/sb/index.ts, transpiled with esbuild) over the in-memory gateway in
// tests/fake_postgrest.js. Open the app in mock mode and the login card signs in for real:
//
//   node tests/signin-server.js            then  http://localhost:8770/?mock=reset
//
// Logins: richard (Admin) and thandi (Sales), ids 1 and 2 as in the mock seed, password
// Focus-Test-1. Sign-in goes through the proxy; the app's data stays the mock store.
// /__test/* lets a harness look behind the curtain (never part of Focus):
//   GET  /__test/state            users, credentials (flags only), devices, sessions, audit, config
//   GET  /__test/code?user=<id>   the code the login's authenticator would show now
//   POST /__test/config           { code_required, trust_days }
//   POST /__test/clock            { addMs }   move this server's clock forward
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { pathToFileURL } = require('url');
const esbuild = require('esbuild');
const { makeFake } = require('./fake_postgrest.js');

const PORT = +process.env.PORT || 8770;
const ROOT = path.join(__dirname, '..');
const PASSWORD = 'Focus-Test-1';
const TYPES = { '.html': 'text/html; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml',
  '.webmanifest': 'application/manifest+json', '.js': 'text/javascript', '.txt': 'text/plain', '.ico': 'image/x-icon' };

process.env.FOCUS_SERVICE_KEY = 'local-test-service-key';
process.env.SUPABASE_HOST = 'fake.supabase.test';

const realNow = Date.now;
let clock = 0;
Date.now = () => realNow() + clock;

async function loadProxy() {
  const src = fs.readFileSync(path.join(ROOT, 'supabase', 'functions', 'sb', 'index.ts'), 'utf8');
  const out = esbuild.transformSync(src, { loader: 'ts', format: 'esm', target: 'es2022' });
  const file = path.join(os.tmpdir(), 'focus-sb-local-' + process.pid + '.mjs');
  fs.writeFileSync(file, out.code);
  try { return await import(pathToFileURL(file).href); } finally { fs.unlinkSync(file); }
}

(async () => {
  const sb = await loadProxy();
  const fake = makeFake({ environment: 'Local test' });
  const db = fake.db;
  globalThis.fetch = fake.fetch;
  const cred = async () => { const salt = 'local-' + Math.random().toString(16).slice(2); return { password_hash: await sb.hashPassword(PASSWORD, salt), password_salt: salt }; };
  db.addUser({ id: 1, person_id: 1, username: 'richard' }, await cred());
  db.addUser({ id: 2, person_id: 2, username: 'thandi' }, await cred());
  db.userRoles.push({ user_id: 1, role_id: 1 }, { user_id: 2, role_id: 2 });

  const readBody = (req) => new Promise(resolve => { const chunks = []; req.on('data', c => chunks.push(c)); req.on('end', () => resolve(Buffer.concat(chunks))); });
  const send = (res, status, obj) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };

  http.createServer(async (req, res) => {
    const u = new URL(req.url, 'http://localhost:' + PORT);
    try {
      if (u.pathname.startsWith('/__test/')) {
        const body = req.method === 'POST' ? JSON.parse((await readBody(req)).toString() || '{}') : {};
        if (u.pathname === '/__test/state') {
          return send(res, 200, { config: db.config, clockMs: clock,
            users: db.users.map(x => ({ id: x.id, username: x.username, active: x.active, must_set_password: x.must_set_password,
              failed_login_count: x.failed_login_count, locked_until: x.locked_until, session_version: x.session_version, old_column: x.password_hash })),
            creds: Array.from(db.creds.entries()).map(([id, c]) => ({ id, has_password: !!c.password_hash, temp_expires_at: c.temp_expires_at,
              sealed: !!c.totp_secret, enrolled_at: c.totp_confirmed_at, last_step: c.totp_last_step })),
            devices: db.devices.map(d => ({ user: d.system_user_id, expires_at: d.expires_at })),
            sessions: db.sessions, audit: db.audit });
        }
        if (u.pathname === '/__test/code') {
          const id = +u.searchParams.get('user');
          const c = db.creds.get(id);
          const secret = c && c.totp_secret ? await sb.openSecret(id, c.totp_secret) : null;
          if (!secret) return send(res, 404, { error: 'no authenticator secret for that login' });
          return send(res, 200, { code: await sb.totpAt(secret, Math.floor(Date.now() / 30000)), secret: sb.base32Encode(secret) });
        }
        if (u.pathname === '/__test/config') { Object.assign(db.config, body); return send(res, 200, db.config); }
        if (u.pathname === '/__test/clock') { clock += +body.addMs || 0; return send(res, 200, { clockMs: clock }); }
        return send(res, 404, { error: 'unknown test route' });
      }

      if (u.pathname === '/sb' || u.pathname.startsWith('/sb/')) {
        const headers = {};
        Object.keys(req.headers).forEach(k => { if (k !== 'host' && k !== 'connection' && k !== 'content-length') headers[k] = String(req.headers[k]); });
        const body = req.method === 'GET' || req.method === 'HEAD' ? undefined : await readBody(req);
        const out = await sb.handler(new Request('https://fn.test' + u.pathname + u.search, { method: req.method, headers, body }));
        const buf = Buffer.from(await out.arrayBuffer());
        const h = {}; out.headers.forEach((v, k) => { h[k] = v; });
        res.writeHead(out.status, h); res.end(buf);
        return;
      }

      const rel = u.pathname === '/' ? 'index.html' : u.pathname === '/time' ? 'time.html' : u.pathname === '/log' ? 'log.html' : decodeURIComponent(u.pathname.slice(1));
      const file = path.join(ROOT, rel);
      if (!file.startsWith(ROOT) || /(^|[\\/])\.(env|git)/.test(rel)) { res.writeHead(404); res.end('nf'); return; }
      fs.readFile(file, (err, data) => {
        if (err) { res.writeHead(404); res.end('nf'); return; }
        res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' }); res.end(data);
      });
    } catch (e) { send(res, 500, { error: String(e && e.message || e) }); }
  }).listen(PORT, () => console.log(`Focus sign-in server on http://localhost:${PORT}/?mock=reset  (richard / thandi, password ${PASSWORD})`));
})();
