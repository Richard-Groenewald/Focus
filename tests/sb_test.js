// Unit checks for netlify/functions/sb.js — https stubbed, crypto real.
//   node tests/sb_test.js
// Lives OUTSIDE netlify/functions so Netlify never deploys it as a function.
// The stub answers like PostgREST for system_users / settings and echoes
// anything else (plain JSON, no content-encoding, so the v7.9.40 gzip leg is
// bypassed); it also mirrors the session_version trigger from
// sql/add_session_version.sql so the revocation paths can be exercised.
const assert = require('assert');
const crypto = require('crypto');
const https = require('https');
const { EventEmitter } = require('events');

process.env.SUPABASE_SECRET_KEY = 'test-service-key';

const db = { users: [
  { id: 4, person_id: 1, username: 'richard', active: true, password_hash: null, password_salt: null,
    password_set_at: null, must_set_password: true, failed_login_count: 0, locked_until: null, session_version: 1 },
  { id: 9, person_id: 77, username: 'gone', active: false, password_hash: null, password_salt: null,
    password_set_at: null, must_set_password: false, failed_login_count: 0, locked_until: null, session_version: 1 },
] };
const calls = [];
let failNext = false;

// Mirrors the BEFORE UPDATE trigger in sql/add_session_version.sql.
function bumpTrigger(o, n) {
  if ((o.active !== false && n.active === false)
      || (n.password_hash !== o.password_hash)
      || (!o.must_set_password && n.must_set_password === true)) {
    n.session_version = (o.session_version || 1) + 1;
  }
}

https.request = function (opts, cb) {
  const req = new EventEmitter();
  let bodyText = '';
  req.write = (c) => { bodyText += c; };
  req.reusedSocket = false;
  req.end = () => {
    calls.push({ method: opts.method, path: opts.path, headers: opts.headers, body: bodyText });
    if (failNext) {
      failNext = false;
      setImmediate(() => req.emit('error', Object.assign(new Error('boom'), { code: 'ECONNREFUSED' })));
      return;
    }
    const [pathOnly, qs = ''] = opts.path.split('?');
    let out = '[]';
    if (pathOnly === '/rest/v1/system_users') {
      const idm = /id=eq\.(\d+)/.exec(qs);
      const um = /username=ilike\.([^&]+)/.exec(qs);
      const rows = db.users.filter(u => idm ? u.id === +idm[1]
        : um ? u.username.toLowerCase() === decodeURIComponent(um[1]).toLowerCase() : true);
      if (opts.method === 'PATCH') {
        const patch = JSON.parse(bodyText);
        rows.forEach(u => { const before = { ...u }; Object.assign(u, patch); bumpTrigger(before, u); });
      }
      const sel = /select=([^&]+)/.exec(qs);
      const cols = sel ? decodeURIComponent(sel[1]).split(',') : ['*'];
      out = JSON.stringify(rows.map(u => cols[0] === '*' ? { ...u } : Object.fromEntries(cols.map(c => [c, u[c]]))));
    } else if (pathOnly === '/rest/v1/settings') {
      out = JSON.stringify([{ value: 'Test' }]);
    } else if (pathOnly === '/rest/v1/audit_log') {
      // What the trail looked like before sql/audit_log_scrub_credentials.sql.
      out = JSON.stringify([
        { id: 1, table_name: 'system_users', op: 'UPDATE', row_data: null,
          changes: { password_hash: { o: 'h1', n: 'h2' }, password_salt: { o: 's1', n: 's2' }, must_set_password: { o: true, n: false } } },
        { id: 2, table_name: 'system_users', op: 'INSERT', changes: null,
          row_data: { id: 4, username: 'richard', password_hash: 'h', password_salt: 's', password: '' } },
        { id: 3, table_name: 'leads', op: 'UPDATE', row_data: null, changes: { notes: { o: 'a', n: 'b' } } },
      ]);
    } else {
      out = JSON.stringify([{ echoed: opts.path }]);
    }
    const res = new EventEmitter();
    res.statusCode = 200;
    res.headers = { 'content-type': 'application/json' };   // no content-encoding → plain path
    cb(res);
    setImmediate(() => { res.emit('data', Buffer.from(out)); res.emit('end'); });
  };
  return req;
};

const sb = require('../netlify/functions/sb.js');
const call = (method, path, { headers = {}, body, rawQuery = '' } = {}) =>
  sb.handler({ httpMethod: method, path: '/.netlify/functions/sb' + path, rawQuery, headers,
               body: body ? JSON.stringify(body) : undefined });
const auth = (obj) => call('POST', '/auth', { body: obj }).then(r => JSON.parse(r.body));
const data = (token, path = '/leads', extra = {}) =>
  call('GET', path, { headers: { 'x-focus-token': token, ...extra.headers }, rawQuery: extra.rawQuery || '' });
const payloadOf = (token) => JSON.parse(Buffer.from(token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString());
const checkCalls = () => calls.filter(c => c.method === 'GET' && /system_users\?id=eq\.\d+&select=active,session_version/.test(c.path)).length;

// Forge tokens the way the function signs them (same derived key) to prove the
// format checks bite even when the signature is genuine.
const sessionKey = crypto.createHmac('sha256', 'test-service-key').update('focus-session-v1').digest();
const forge = (prefix, payload) => {
  const body = Buffer.from(JSON.stringify(payload)).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return prefix + '.' + body + '.' + crypto.createHmac('sha256', sessionKey).update(body).digest('hex');
};

const realNow = Date.now;
let passed = 0, failed = 0;
async function check(name, fn) {
  try { await fn(); passed++; console.log('  ok   ' + name); }
  catch (e) { failed++; console.log('  FAIL ' + name + '\n       ' + (e.message || e)); }
}

(async () => {
  console.log('sb.js session checks');

  await check('no token → 401 auth', async () => {
    const r = await call('GET', '/leads');
    assert.strictEqual(r.statusCode, 401);
    assert.strictEqual(JSON.parse(r.body).error, 'auth');
  });

  let tokenA;
  await check('first-time set → token carries the bumped session_version', async () => {
    const r = await auth({ action: 'set', username: 'richard', newPassword: 'Passw0rd!' });
    assert.ok(r.ok && r.token, JSON.stringify(r));
    tokenA = r.token;
    assert.ok(tokenA.startsWith('v2.'), 'prefix');
    assert.strictEqual(payloadOf(tokenA).v, 2, 'trigger bumped 1→2 on the hash write');
    assert.strictEqual(db.users[0].session_version, 2);
  });

  await check('data call with the token → 200, one liveness lookup', async () => {
    const before = checkCalls();
    const r = await data(tokenA);
    assert.strictEqual(r.statusCode, 200, r.body);
    assert.strictEqual(checkCalls() - before, 1);
  });

  await check('second call inside the cache window → no extra lookup', async () => {
    const before = checkCalls();
    const r = await data(tokenA);
    assert.strictEqual(r.statusCode, 200);
    assert.strictEqual(checkCalls() - before, 0);
  });

  await check('login with the password → token with the current version', async () => {
    const r = await auth({ action: 'login', username: 'Richard', password: 'Passw0rd!' });
    assert.ok(r.ok && r.token, JSON.stringify(r));
    assert.strictEqual(payloadOf(r.token).v, 2);
  });

  await check('version bumped elsewhere → still cached until the window lapses, then 401 revoked', async () => {
    db.users[0].session_version = 3;                  // e.g. admin SQL, or another instance's PATCH
    let r = await data(tokenA);
    assert.strictEqual(r.statusCode, 200, 'cached verdict inside the window');
    Date.now = () => realNow() + 61 * 1000;
    r = await data(tokenA);
    Date.now = realNow;
    assert.strictEqual(r.statusCode, 401);
    const j = JSON.parse(r.body);
    assert.strictEqual(j.error, 'auth');
    assert.strictEqual(j.reason, 'revoked');
    db.users[0].session_version = 2;                  // restore for the next checks
  });

  let tokenB;
  await check('password change via set → old token dead at once, new token live', async () => {
    const r = await auth({ action: 'set', userId: 4, password: 'Passw0rd!', newPassword: 'N3wPassw0rd!' });
    assert.ok(r.ok && r.token, JSON.stringify(r));
    tokenB = r.token;
    assert.strictEqual(payloadOf(tokenB).v, 3);
    assert.strictEqual((await data(tokenA)).statusCode, 401, 'old session');
    assert.strictEqual((await data(tokenB)).statusCode, 200, 'new session');
  });

  await check('deactivation through the proxy → cache cleared, 401 revoked immediately', async () => {
    const r = await call('PATCH', '/system_users', { headers: { 'x-focus-token': tokenB }, rawQuery: 'id=eq.4', body: { active: false } });
    assert.strictEqual(r.statusCode, 200);
    assert.strictEqual((await data(tokenB)).statusCode, 401);
    db.users[0].active = true;                        // reactivate — version stays bumped, so still dead
    Date.now = () => realNow() + 61 * 1000;
    assert.strictEqual((await data(tokenB)).statusCode, 401, 'reactivation does not resurrect old sessions');
    Date.now = realNow;
  });

  let tokenC;
  await check('admin reset through the proxy → the user\'s live session dies', async () => {
    let r = await auth({ action: 'login', username: 'richard', password: 'N3wPassw0rd!' });
    assert.ok(r.ok && r.token, JSON.stringify(r));
    tokenC = r.token;
    assert.strictEqual((await data(tokenC)).statusCode, 200);
    r = await call('PATCH', '/system_users', { headers: { 'x-focus-token': tokenC }, rawQuery: 'id=eq.4',
      body: { password_hash: null, password_salt: null, password_set_at: null, must_set_password: true } });
    assert.strictEqual(r.statusCode, 200);
    assert.strictEqual((await data(tokenC)).statusCode, 401);
  });

  await check('old v1 format (genuine signature, no version) → 401', async () => {
    const t = forge('v1', { u: 4, p: 1, e: realNow() + 3600e3 });
    assert.strictEqual((await data(t)).statusCode, 401);
  });

  await check('v2 token missing the version field → 401', async () => {
    const t = forge('v2', { u: 4, p: 1, e: realNow() + 3600e3 });
    assert.strictEqual((await data(t)).statusCode, 401);
  });

  await check('tampered payload → 401', async () => {
    const parts = tokenB.split('.');
    parts[1] = Buffer.from(JSON.stringify({ u: 4, p: 1, e: realNow() + 3600e3, v: 3 })).toString('base64').replace(/=+$/, '');
    assert.strictEqual((await data(parts.join('.'))).statusCode, 401);
  });

  await check('expired token → 401', async () => {
    const t = forge('v2', { u: 4, p: 1, e: realNow() - 1000, v: 3 });
    assert.strictEqual((await data(t)).statusCode, 401);
  });

  await check('liveness lookup failing → 503 (not a sign-out)', async () => {
    const r0 = await auth({ action: 'set', username: 'richard', newPassword: 'Ag4in!Pass' });
    assert.ok(r0.ok && r0.token, JSON.stringify(r0));
    Date.now = () => realNow() + 2 * 61 * 1000;      // force a cache miss
    failNext = true;
    const r = await data(r0.token);
    Date.now = realNow;
    assert.strictEqual(r.statusCode, 503, r.body);
    assert.notStrictEqual(JSON.parse(r.body).error, 'auth');
    tokenC = r0.token;
  });

  await check('system_users read is still scrubbed of credentials', async () => {
    const r = await data(tokenC, '/system_users', { rawQuery: 'select=*' });
    assert.strictEqual(r.statusCode, 200, r.body);
    const rows = JSON.parse(r.body);
    assert.ok(rows.length && !('password_hash' in rows[0]) && !('password_salt' in rows[0]) && !('password' in rows[0]));
  });

  await check('masquerade: claimed actor ≠ token person → real actor forced', async () => {
    const r = await data(tokenC, '/deals', { headers: { 'x-actor-id': '4105', 'x-real-actor-id': '999' } });
    assert.strictEqual(r.statusCode, 200);
    const last = calls[calls.length - 1];
    assert.strictEqual(last.headers['X-Actor-Id'], '4105');
    assert.strictEqual(last.headers['X-Real-Actor-Id'], '1');
  });

  await check('inactive account cannot sign in', async () => {
    const r = await auth({ action: 'login', username: 'gone', password: 'whatever1!A' });
    assert.strictEqual(r.ok, false);
  });

  await check('audit_log read is scrubbed inside changes and row_data, rest intact', async () => {
    const r = await data(tokenC, '/audit_log', { rawQuery: 'select=*&order=at.desc', headers: { 'x-focus-gzip': '1' } });
    assert.strictEqual(r.statusCode, 200, r.body);
    assert.notStrictEqual(r.isBase64Encoded, true, 'must not be gzip-passed-through');
    const rows = JSON.parse(r.body);
    assert.strictEqual(rows.length, 3);
    assert.deepStrictEqual(Object.keys(rows[0].changes), ['must_set_password']);
    assert.deepStrictEqual(Object.keys(rows[1].row_data).sort(), ['id', 'username']);
    assert.deepStrictEqual(rows[2].changes, { notes: { o: 'a', n: 'b' } });
    const last = calls[calls.length - 1];
    assert.strictEqual(last.headers['Accept-Encoding'], undefined, 'audit_log is never requested compressed');
  });

  await check('an ordinary table is still requested compressed when the browser can inflate', async () => {
    const r = await data(tokenC, '/leads', { headers: { 'x-focus-gzip': '1' } });
    assert.strictEqual(r.statusCode, 200);
    const last = calls[calls.length - 1];
    assert.strictEqual(last.headers['Accept-Encoding'], 'gzip');
  });

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})();
