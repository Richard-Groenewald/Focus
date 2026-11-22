// Checks for the Focus proxy, supabase/functions/sb/index.ts (v7.10.58).
//   node tests/sb_test.js
// The TypeScript is transpiled with esbuild (the build's own dependency) and run in Node, whose
// fetch / Request / WebCrypto are the ones the Edge runtime offers. The Supabase gateway is
// tests/fake_postgrest.js; the cryptography is real.
// (Until v7.10.58 this file tested netlify/functions/sb.js, the proxy's retired Netlify copy.)
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { pathToFileURL } = require('url');
const esbuild = require('esbuild');
const { makeFake } = require('./fake_postgrest.js');

process.env.FOCUS_SERVICE_KEY = 'test-service-key';
process.env.SUPABASE_HOST = 'fake.supabase.test';

let sb, fake, db;
const realNow = Date.now;
let clock = 0;                               // ms added to the real clock
Date.now = () => realNow() + clock;

async function load() {
  const src = fs.readFileSync(path.join(__dirname, '..', 'supabase', 'functions', 'sb', 'index.ts'), 'utf8');
  const out = esbuild.transformSync(src, { loader: 'ts', format: 'esm', target: 'es2022' });
  const file = path.join(os.tmpdir(), 'focus-sb-test-' + process.pid + '.mjs');
  fs.writeFileSync(file, out.code);
  try { return await import(pathToFileURL(file).href); } finally { fs.unlinkSync(file); }
}

function fresh(opts) {
  fake = makeFake(opts); db = fake.db;
  globalThis.fetch = fake.fetch;
  clock += 61 * 1000;                        // past the proxy's 60-second session cache
}
async function cred(password) {
  const salt = 'salt-' + Math.random().toString(16).slice(2);
  return { password_hash: await sb.hashPassword(password, salt), password_salt: salt };
}
async function auth(body, headers) {
  const res = await sb.handler(new Request('https://fn.test/sb/auth', { method: 'POST',
    headers: Object.assign({ 'Content-Type': 'application/json' }, headers || {}), body: JSON.stringify(body) }));
  let j = null; try { j = await res.json(); } catch (e) { /* no body */ }
  return Object.assign({ status: res.status }, j || {});
}
async function call(method, p, o) {
  o = o || {};
  const headers = Object.assign({ 'Content-Type': 'application/json' }, o.headers || {});
  if (o.token) headers['X-Focus-Token'] = o.token;
  const res = await sb.handler(new Request('https://fn.test/sb' + p, { method, headers,
    body: method === 'GET' || method === 'HEAD' ? undefined : JSON.stringify(o.body || {}) }));
  const text = await res.text();
  let j = null; try { j = JSON.parse(text); } catch (e) { /* not json */ }
  return { status: res.status, json: j, text };
}
const upstream = (re) => db.calls.filter(c => re.test(c.path));
async function codeFor(userId, offsetSteps) {
  const secret = await sb.openSecret(userId, db.creds.get(userId).totp_secret);
  return sb.totpAt(secret, Math.floor(Date.now() / 30000) + (offsetSteps || 0));
}
const PW = 'Correct-Horse-9', PW2 = 'Battery-Staple-7';

const tests = [];
const t = (name, fn) => tests.push([name, fn]);

// ── A. The cryptography ─────────────────────────────────────────────────────────────────────
t('RFC 6238 vectors (SHA-1), six digits', async () => {
  const secret = new TextEncoder().encode('12345678901234567890');
  const want = { 59: '287082', 1111111109: '081804', 1111111111: '050471', 1234567890: '005924', 2000000000: '279037', 20000000000: '353130' };
  for (const s of Object.keys(want)) assert.strictEqual(await sb.totpAt(secret, Math.floor(+s / 30)), want[s], 'at ' + s);
});
t('base32 round trip and a known value', async () => {
  const bytes = new TextEncoder().encode('12345678901234567890');
  assert.strictEqual(sb.base32Encode(bytes), 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
  assert.deepStrictEqual(Array.from(sb.base32Decode('gezd gnbv-gy3t qojq gezd gnbv gy3t qojq')), Array.from(bytes));
  for (let n = 1; n < 40; n++) {
    const r = crypto.getRandomValues(new Uint8Array(n));
    assert.deepStrictEqual(Array.from(sb.base32Decode(sb.base32Encode(r))), Array.from(r), 'length ' + n);
  }
  assert.strictEqual(sb.base32Decode('not base32 !'), null);
});
t('a code is accepted one step either side of now, and no further', async () => {
  const secret = crypto.getRandomValues(new Uint8Array(20));
  const now = Date.now(), step = Math.floor(now / 30000);
  for (const d of [-1, 0, 1]) assert.strictEqual(await sb.totpMatch(secret, await sb.totpAt(secret, step + d), now), step + d);
  for (const d of [-2, 2]) {
    const far = await sb.totpAt(secret, step + d);
    const near = [await sb.totpAt(secret, step - 1), await sb.totpAt(secret, step), await sb.totpAt(secret, step + 1)];
    if (!near.includes(far)) assert.strictEqual(await sb.totpMatch(secret, far, now), null);
  }
  const c = await sb.totpAt(secret, step);
  assert.strictEqual(await sb.totpMatch(secret, c.slice(0, 3) + ' ' + c.slice(3), now), step, 'a space in the middle is fine');
  for (const bad of ['', '12345', '1234567', 'abcdef', null, undefined]) assert.strictEqual(await sb.totpMatch(secret, bad, now), null);
});
t('the stored secret is sealed, and opens only for the login it belongs to', async () => {
  const secret = crypto.getRandomValues(new Uint8Array(20));
  const sealed = await sb.sealSecret(7, secret);
  assert.ok(/^v1\.[\w-]+\.[\w-]+$/.test(sealed));
  assert.ok(!sealed.includes(sb.base32Encode(secret)));
  assert.deepStrictEqual(Array.from(await sb.openSecret(7, sealed)), Array.from(secret));
  assert.strictEqual(await sb.openSecret(8, sealed), null);
  assert.strictEqual(await sb.openSecret(7, sealed.slice(0, -2) + 'AA'), null);
  assert.notStrictEqual(await sb.sealSecret(7, secret), sealed, 'a fresh nonce each time');
});
t('a one-time password always meets the policy', async () => {
  const seen = new Set();
  for (let i = 0; i < 300; i++) {
    const p = sb.oneTimePassword();
    assert.ok(/^[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}$/.test(p), p);
    assert.strictEqual(sb.passwordPolicyError(p), null, p);
    assert.ok(!/[01IOlo]/.test(p), 'no look-alike characters: ' + p);
    seen.add(p);
  }
  assert.strictEqual(seen.size, 300);
});

// ── B. A database without the sign-in upgrade behaves exactly as before ──────────────────────
t('before the SQL: first-time set, sign-in, lock, and no method on the log', async () => {
  fresh({ vault: false });
  db.addUser({ id: 4, person_id: 1, username: 'richard', must_set_password: true });
  assert.deepStrictEqual((await auth({ action: 'env' })).environment, 'Test');
  assert.strictEqual((await auth({ action: 'check', username: 'Richard' })).mustSet, true);
  const set = await auth({ action: 'set', username: 'richard', newPassword: PW });
  assert.ok(set.ok && set.token, 'first-time set signs in');
  assert.ok((await sb.verifyToken('test-service-key', set.token)).userId === 4);
  const ok = await auth({ action: 'login', username: 'RICHARD', password: PW });
  assert.ok(ok.ok && ok.token && ok.sessionId);
  for (let i = 0; i < 5; i++) assert.strictEqual((await auth({ action: 'login', username: 'richard', password: 'wrong' })).ok, false);
  assert.ok(/Too many/.test((await auth({ action: 'login', username: 'richard', password: PW })).error));
  assert.ok(db.sessions.length >= 6 && db.sessions.every(s => !('method' in s)), 'the old log has no method column');
  assert.strictEqual((await auth({ action: 'totp-begin', username: 'richard', password: PW })).notInstalled, true);
});
t('before the SQL: the admin actions say the upgrade is missing', async () => {
  fresh({ vault: false });
  db.addUser({ id: 4, person_id: 1, username: 'richard' }, await cred(PW));
  db.userRoles.push({ user_id: 4, role_id: 1 });
  const s = await auth({ action: 'login', username: 'richard', password: PW });
  const r = await auth({ action: 'admin-list' }, { 'X-Focus-Token': s.token });
  assert.strictEqual(r.notInstalled, true);
});

// ── C. The new store, code not required ─────────────────────────────────────────────────────
t('no account can be claimed from the login screen', async () => {
  fresh();
  db.addUser({ id: 5, person_id: 2, username: 'newbie', must_set_password: true });   // no password at all
  assert.strictEqual((await auth({ action: 'check', username: 'newbie' })).mustSet, false);
  assert.strictEqual((await auth({ action: 'login', username: 'newbie', password: '' })).ok, false);
  const set = await auth({ action: 'set', username: 'newbie', newPassword: PW });
  assert.strictEqual(set.ok, false);
  assert.ok(!set.token && !db.creds.has(5));
});
t('sign-in, wrong password, lock, deactivated', async () => {
  fresh();
  db.addUser({ id: 4, person_id: 1, username: 'richard' }, await cred(PW));
  db.addUser({ id: 9, person_id: 3, username: 'gone', active: false }, await cred(PW));
  const ok = await auth({ action: 'login', username: 'Richard', password: PW });
  assert.ok(ok.ok && ok.token && ok.userId === 4 && ok.personId === 1 && ok.sessionId);
  assert.strictEqual(db.sessions[db.sessions.length - 1].method, 'password');
  assert.strictEqual((await auth({ action: 'login', username: 'gone', password: PW })).ok, false);
  const bad = await auth({ action: 'login', username: 'richard', password: 'nope' });
  assert.deepStrictEqual([bad.ok, bad.error], [false, 'Sign-in failed']);
  assert.strictEqual(db.users[0].failed_login_count, 1);
  await auth({ action: 'login', username: 'richard', password: PW });
  assert.strictEqual(db.users[0].failed_login_count, 0, 'a sign-in clears the count');
  for (let i = 0; i < 5; i++) await auth({ action: 'login', username: 'richard', password: 'nope' });
  assert.ok(db.users[0].locked_until);
  assert.ok(/Too many/.test((await auth({ action: 'login', username: 'richard', password: PW })).error));
  assert.strictEqual(db.users[0].password_hash, '!vault', 'the old column is never written');
  assert.strictEqual((await auth({ action: 'login', username: 'nobody', password: PW })).error, 'Sign-in failed');
});
t('changing a password from the login screen and in the app', async () => {
  fresh();
  db.addUser({ id: 4, person_id: 1, username: 'richard' }, await cred(PW));
  assert.ok(/incorrect/.test((await auth({ action: 'set', username: 'richard', password: 'nope', newPassword: PW2 })).error));
  assert.ok(/different/.test((await auth({ action: 'set', username: 'richard', password: PW, newPassword: PW })).error));
  assert.ok(/at least 8/.test((await auth({ action: 'set', username: 'richard', password: PW, newPassword: 'short' })).error));
  const s1 = await auth({ action: 'login', username: 'richard', password: PW });
  const set = await auth({ action: 'set', userId: 4, password: PW, newPassword: PW2 }, { 'X-Focus-Token': s1.token });
  assert.ok(set.ok && set.token);
  assert.strictEqual(db.users[0].session_version, 2);
  assert.strictEqual((await call('GET', '/people', { token: s1.token })).status, 401, 'the old session is over');
  assert.strictEqual((await call('GET', '/people', { token: set.token })).status, 200);
  assert.strictEqual((await auth({ action: 'login', username: 'richard', password: PW })).ok, false);
  assert.ok((await auth({ action: 'login', username: 'richard', password: PW2 })).ok);
});

// ── D. The new store, code required ─────────────────────────────────────────────────────────
t('enrolment: the secret, a wrong code, the right code', async () => {
  fresh(); db.config.code_required = 'true';
  db.addUser({ id: 4, person_id: 1, username: 'richard' }, await cred(PW));
  const first = await auth({ action: 'login', username: 'richard', password: PW });
  assert.deepStrictEqual([first.ok, first.enrol, !!first.token], [false, true, false]);
  assert.strictEqual((await auth({ action: 'totp-begin', username: 'richard', password: 'nope' })).ok, false);
  const begin = await auth({ action: 'totp-begin', username: 'richard', password: PW });
  assert.ok(begin.ok && /^[A-Z2-7]{32}$/.test(begin.secret));
  const uri = new URL(begin.uri);
  assert.strictEqual(uri.protocol, 'otpauth:');
  assert.strictEqual(uri.searchParams.get('secret'), begin.secret);
  assert.strictEqual(uri.searchParams.get('issuer'), 'Focus Test');
  assert.strictEqual(decodeURIComponent(uri.pathname), '/Focus Test:richard');
  const stored = db.creds.get(4);
  assert.ok(stored.totp_secret.startsWith('v1.') && !stored.totp_secret.includes(begin.secret) && !stored.totp_confirmed_at);
  assert.strictEqual((await auth({ action: 'login', username: 'richard', password: PW })).enrol, true, 'pending is not enrolled');
  const wrong = await auth({ action: 'totp-confirm', username: 'richard', password: PW, code: '000000' });
  assert.ok(wrong.ok === false && wrong.badCode && db.users[0].failed_login_count === 1);
  const done = await auth({ action: 'totp-confirm', username: 'richard', password: PW, code: await codeFor(4) });
  assert.ok(done.ok && done.token && done.sessionId && !done.device);
  assert.ok(db.creds.get(4).totp_confirmed_at);
  assert.strictEqual(db.sessions[db.sessions.length - 1].method, 'password+code');
  assert.ok(/already set up/.test((await auth({ action: 'totp-begin', username: 'richard', password: PW })).error));
  assert.strictEqual((await auth({ action: 'totp-confirm', username: 'richard', password: PW, code: await codeFor(4) })).restart, true);
});
t('sign-in asks for the code, takes it once, and counts wrong ones', async () => {
  fresh(); db.config.code_required = 'true';
  db.addUser({ id: 4, person_id: 1, username: 'richard' }, await cred(PW));
  await auth({ action: 'totp-begin', username: 'richard', password: PW });
  await auth({ action: 'totp-confirm', username: 'richard', password: PW, code: await codeFor(4) });
  const ask = await auth({ action: 'login', username: 'richard', password: PW });
  assert.deepStrictEqual([ask.ok, ask.needCode, ask.trustDays, !!ask.token], [false, true, 30, false]);
  assert.strictEqual(db.users[0].failed_login_count, 0, 'being asked is not a failure');
  const used = await auth({ action: 'login', username: 'richard', password: PW, code: await codeFor(4) });
  assert.ok(used.ok === false && /already been used/.test(used.error), 'the enrolment code cannot be replayed');
  clock += 30 * 1000;
  const code = await codeFor(4);
  const ok = await auth({ action: 'login', username: 'richard', password: PW, code });
  assert.ok(ok.ok && ok.token);
  assert.strictEqual((await auth({ action: 'login', username: 'richard', password: PW, code })).ok, false, 'a code works once');
  const bad = await auth({ action: 'login', username: 'richard', password: PW, code: '123456' === code ? '654321' : '123456' });
  assert.ok(bad.ok === false && bad.needCode && bad.badCode);
  assert.deepStrictEqual([db.sessions[db.sessions.length - 1].outcome, db.sessions[db.sessions.length - 1].method], ['failed', 'code']);
  assert.strictEqual((await auth({ action: 'login', username: 'richard', password: 'nope', code })).error, 'Sign-in failed', 'the password is still checked first');
  for (let i = 0; i < 5; i++) await auth({ action: 'login', username: 'richard', password: PW, code: '000001' });
  clock += 30 * 1000;
  assert.ok(/Too many/.test((await auth({ action: 'login', username: 'richard', password: PW, code: await codeFor(4) })).error), 'wrong codes lock the account');
});
t('a trusted device skips the code until it lapses or is forgotten', async () => {
  fresh(); db.config.code_required = 'true';
  db.addUser({ id: 4, person_id: 1, username: 'richard' }, await cred(PW));
  db.addUser({ id: 6, person_id: 5, username: 'thandi' }, await cred(PW));
  await auth({ action: 'totp-begin', username: 'richard', password: PW });
  const en = await auth({ action: 'totp-confirm', username: 'richard', password: PW, code: await codeFor(4), trust: true });
  assert.ok(en.ok && en.device && en.trustDays === 30);
  assert.ok(db.devices.length === 1 && db.devices[0].token_hash === await sb.sha256Hex(en.device) && db.devices[0].token_hash !== en.device);
  const quick = await auth({ action: 'login', username: 'richard', password: PW, device: en.device });
  assert.ok(quick.ok && quick.token && !quick.device);
  assert.strictEqual(db.sessions[db.sessions.length - 1].method, 'password+device');
  assert.strictEqual((await auth({ action: 'login', username: 'richard', password: 'nope', device: en.device })).ok, false, 'the device never replaces the password');
  assert.strictEqual((await auth({ action: 'login', username: 'richard', password: PW, device: 'made-up' })).needCode, true);
  // Somebody else's device token is not mine.
  await auth({ action: 'totp-begin', username: 'thandi', password: PW });
  await auth({ action: 'totp-confirm', username: 'thandi', password: PW, code: await codeFor(6) });
  assert.strictEqual((await auth({ action: 'login', username: 'thandi', password: PW, device: en.device })).needCode, true);
  db.config.trust_days = '0';
  assert.strictEqual((await auth({ action: 'login', username: 'richard', password: PW, device: en.device })).needCode, true, 'trust switched off');
  clock += 60 * 1000;
  const noTrust = await auth({ action: 'login', username: 'richard', password: PW, code: await codeFor(4), trust: true });
  assert.ok(noTrust.ok && !noTrust.device);
  db.config.trust_days = '30';
  clock += 31 * 86400000;
  assert.strictEqual((await auth({ action: 'login', username: 'richard', password: PW, device: en.device })).needCode, true, 'lapsed after 30 days');
});
t('a password change from the login screen is not a sign-in while a code is required', async () => {
  fresh(); db.config.code_required = 'true';
  db.addUser({ id: 4, person_id: 1, username: 'richard' }, await cred(PW));
  db.addUser({ id: 6, person_id: 5, username: 'thandi' }, await cred(PW));
  await auth({ action: 'totp-begin', username: 'richard', password: PW });
  const s = await auth({ action: 'totp-confirm', username: 'richard', password: PW, code: await codeFor(4), trust: true });
  const byId = await auth({ action: 'set', userId: 4, password: PW, newPassword: PW2 });
  assert.ok(byId.ok && byId.set && !byId.token, 'knowing the password and the id is not enough for a token');
  assert.strictEqual(db.devices.length, 0, 'a password change forgets every trusted device');
  assert.strictEqual((await auth({ action: 'login', username: 'richard', password: PW2, device: s.device })).needCode, true);
  clock += 30 * 1000;
  const s2 = await auth({ action: 'login', username: 'richard', password: PW2, code: await codeFor(4) });
  // In the app, with a live session of the same login, the session carries on.
  const inApp = await auth({ action: 'set', userId: 4, password: PW2, newPassword: PW }, { 'X-Focus-Token': s2.token });
  assert.ok(inApp.ok && inApp.token);
  // A session of ANOTHER login does not count.
  await auth({ action: 'totp-begin', username: 'thandi', password: PW });
  const th = await auth({ action: 'totp-confirm', username: 'thandi', password: PW, code: await codeFor(6) });
  const cross = await auth({ action: 'set', userId: 4, password: PW, newPassword: PW2 }, { 'X-Focus-Token': th.token });
  assert.ok(cross.ok && !cross.token);
});

// ── E. Administration, checked on the server ────────────────────────────────────────────────
async function staff() {
  fresh(); db.config.code_required = 'true';
  db.addUser({ id: 1, person_id: 11, username: 'admin' }, await cred(PW));
  db.addUser({ id: 2, person_id: 12, username: 'thandi' }, await cred(PW));
  db.addUser({ id: 3, person_id: 13, username: 'useradmin' }, await cred(PW));
  db.addUser({ id: 4, person_id: 14, username: 'settings' }, await cred(PW));
  db.userRoles.push({ user_id: 1, role_id: 1 }, { user_id: 2, role_id: 2 }, { user_id: 3, role_id: 3 }, { user_id: 4, role_id: 4 });
  const out = {};
  for (const u of db.users) {
    await auth({ action: 'totp-begin', username: u.username, password: PW });
    out[u.username] = (await auth({ action: 'totp-confirm', username: u.username, password: PW, code: await codeFor(u.id) })).token;
    assert.ok(out[u.username], u.username + ' signed in');
  }
  return out;
}
t('the admin actions need a session and the permission', async () => {
  const tok = await staff();
  assert.strictEqual((await auth({ action: 'admin-list' })).status, 401);
  assert.strictEqual((await auth({ action: 'admin-list' }, { 'X-Focus-Token': 'v2.bogus.token' })).status, 401);
  assert.strictEqual((await auth({ action: 'admin-list' }, { 'X-Focus-Token': tok.thandi })).status, 403);
  assert.strictEqual((await auth({ action: 'admin-reset-password', targetUserId: 1 }, { 'X-Focus-Token': tok.thandi })).status, 403);
  assert.strictEqual((await auth({ action: 'policy-set', codeRequired: false }, { 'X-Focus-Token': tok.thandi })).status, 403);
  assert.strictEqual((await auth({ action: 'policy-set', codeRequired: false }, { 'X-Focus-Token': tok.useradmin })).status, 403, 'user admin is not settings');
  assert.strictEqual(db.config.code_required, 'true');
  const list = await auth({ action: 'admin-list' }, { 'X-Focus-Token': tok.useradmin });
  assert.ok(list.ok && list.users.length === 4 && list.users.every(u => u.has_password && u.enrolled_at));
  assert.ok(!JSON.stringify(list).includes('salt') && !JSON.stringify(list).includes('v1.'), 'no secrets in the list');
  db.failEmbed = true; clock += 61 * 1000;
  assert.strictEqual((await auth({ action: 'admin-list' }, { 'X-Focus-Token': tok.admin })).status, 503, 'permissions unreadable: not allowed, not denied');
  db.failEmbed = false;
});
t('reset password: a one-time password that must be replaced, and expires', async () => {
  const tok = await staff();
  const r = await auth({ action: 'admin-reset-password', targetUserId: 2 }, { 'X-Focus-Token': tok.useradmin });
  assert.ok(r.ok && sb.passwordPolicyError(r.password) === null && r.days === 7);
  assert.strictEqual((await call('GET', '/people', { token: tok.thandi })).status, 401, 'her sessions ended');
  assert.strictEqual((await auth({ action: 'login', username: 'thandi', password: PW })).ok, false, 'the old password is dead');
  const audit = db.audit[db.audit.length - 1];
  assert.deepStrictEqual([audit.actor_id, audit.row_id, audit.changes.password.n], [13, 2, 'one-time password issued']);
  const write = upstream(/auth_write/).filter(c => /"must_set_password":true/.test(c.body)).pop();
  assert.strictEqual(write.headers['x-actor-id'], '13', 'the change is attributed to the admin');
  const once = await auth({ action: 'login', username: 'thandi', password: r.password });
  assert.deepStrictEqual([once.ok, once.mustSet, !!once.token], [false, true, false]);
  assert.ok(/own password/.test((await auth({ action: 'totp-begin', username: 'thandi', password: r.password })).error));
  const set = await auth({ action: 'set', username: 'thandi', password: r.password, newPassword: PW2 });
  assert.ok(set.ok && !set.token);
  clock += 60 * 1000;
  const back = await auth({ action: 'login', username: 'thandi', password: PW2, code: await codeFor(2) });
  assert.ok(back.ok && back.token, 'her authenticator still stands');
  // An unused one-time password stops working after seven days.
  const r2 = await auth({ action: 'admin-reset-password', targetUserId: 2 }, { 'X-Focus-Token': tok.useradmin });
  clock += 8 * 86400000;
  assert.ok(/expired/.test((await auth({ action: 'login', username: 'thandi', password: r2.password })).error));
  assert.ok(/expired/.test((await auth({ action: 'set', username: 'thandi', password: r2.password, newPassword: PW })).error));
  assert.strictEqual((await auth({ action: 'admin-reset-password', targetUserId: 999 }, { 'X-Focus-Token': tok.admin })).status, 401, 'eight days on, the admin session has expired too');
});
t('reset authenticator: the user enrols again', async () => {
  const tok = await staff();
  const r = await auth({ action: 'admin-reset-authenticator', targetUserId: 2 }, { 'X-Focus-Token': tok.admin });
  assert.ok(r.ok && !db.creds.get(2).totp_secret && !db.creds.get(2).totp_confirmed_at);
  assert.strictEqual((await call('GET', '/people', { token: tok.thandi })).status, 401);
  assert.strictEqual(db.audit[db.audit.length - 1].changes.authenticator.n, 'reset');
  assert.strictEqual((await auth({ action: 'login', username: 'thandi', password: PW })).enrol, true);
  assert.strictEqual((await auth({ action: 'admin-reset-authenticator', targetUserId: 999 }, { 'X-Focus-Token': tok.admin })).error, 'User not found');
});
t('the policy: read, change, limits, and the audit line', async () => {
  const tok = await staff();
  const get = await auth({ action: 'policy-get' }, { 'X-Focus-Token': tok.settings });
  assert.deepStrictEqual([get.ok, get.codeRequired, get.trustDays], [true, true, 30]);
  assert.strictEqual((await auth({ action: 'policy-set', trustDays: 400 }, { 'X-Focus-Token': tok.settings })).ok, false);
  const set = await auth({ action: 'policy-set', codeRequired: false, trustDays: 14 }, { 'X-Focus-Token': tok.settings });
  assert.deepStrictEqual([set.codeRequired, set.trustDays], [false, 14]);
  assert.ok(db.audit.some(a => a.table_name === 'settings' && a.changes.signin_code_required && a.actor_id === 14));
  const plain = await auth({ action: 'login', username: 'thandi', password: PW });
  assert.ok(plain.ok && plain.token, 'code no longer asked');
  assert.ok(/not required/.test((await auth({ action: 'totp-begin', username: 'thandi', password: PW })).error));
});

// ── F. What the proxy forwards ──────────────────────────────────────────────────────────────
t('no session, a bad token, an ended session', async () => {
  const tok = await staff();
  assert.strictEqual((await call('GET', '/people')).status, 401);
  assert.strictEqual((await call('GET', '/people', { token: tok.thandi.slice(0, -1) + 'x' })).status, 401);
  db.users.find(u => u.id === 2).active = false; clock += 61 * 1000;
  const gone = await call('GET', '/people', { token: tok.thandi });
  assert.deepStrictEqual([gone.status, gone.json.reason], [401, 'revoked']);
  db.failNext = 2;
  assert.strictEqual((await call('GET', '/people', { token: tok.admin })).status, 503, 'a blip is not a sign-out');
});
t('the sign-in functions and odd paths are never forwarded', async () => {
  const tok = await staff();
  const before = db.calls.length;
  const n = () => db.calls.slice(before).filter(c => !/^\/system_users$/.test(c.path)).length;
  for (const p of ['/rpc/auth_read', '/rpc/auth_write', '/rpc/AUTH_read', '/rpc/auth_']) {
    assert.strictEqual((await call('POST', p, { token: tok.admin, body: { p_user_id: 1 } })).status, 403, p);
  }
  for (const p of ['/rpc/%61uth_read', '/rpc/auth%5Fread', '/system_users/extra', '/rpc', '/', '/rpc/a/b', '/people;x', '/sys%74em_users']) {
    assert.strictEqual((await call('POST', p, { token: tok.admin, body: {} })).status, 404, p);
  }
  assert.strictEqual(n(), 0, 'nothing reached the gateway');
  const ok = await call('POST', '/rpc/heartbeat', { token: tok.thandi, body: {}, headers: { 'X-Focus-Internal': 'auth' } });
  assert.strictEqual(ok.status, 201);
  const fwd = db.calls[db.calls.length - 1];
  assert.strictEqual(fwd.headers['x-focus-client'], '1', 'forwarded requests carry the client mark');
  assert.ok(!('x-focus-internal' in fwd.headers), 'and never the internal one, whatever the browser sent');
  assert.strictEqual(fwd.headers['x-actor-id'], '12');
  // The functions themselves refuse a marked request, and one with no mark at all.
  const direct = await fake.fetch('https://fake.supabase.test/rest/v1/rpc/auth_read', { method: 'POST',
    headers: { 'X-Focus-Internal': 'auth', 'X-Focus-Client': '1' }, body: '{"p_user_id":1}' });
  assert.strictEqual(direct.status, 403);
  assert.strictEqual((await fake.fetch('https://fake.supabase.test/rest/v1/rpc/auth_read', { method: 'POST', headers: {}, body: '{"p_user_id":1}' })).status, 403);
});
t('writes to the access tables need the permission; reads stay open and scrubbed', async () => {
  const tok = await staff();
  const tables = { system_users: 'useradmin', user_roles: 'useradmin', system_user_regions: 'useradmin', system_user_branches: 'useradmin',
    user_permission_overrides: 'useradmin', roles: null, role_permissions: null, permissions: null };
  for (const tbl of Object.keys(tables)) {
    for (const method of ['POST', 'PATCH', 'DELETE']) {
      const before = db.calls.length;
      assert.strictEqual((await call(method, '/' + tbl + '?id=eq.1', { token: tok.thandi, body: { x: 1 } })).status, 403, method + ' ' + tbl);
      assert.ok(!db.calls.slice(before).some(c => c.path === '/' + tbl && c.method === method), 'not forwarded');
      assert.ok([200, 201].includes((await call(method, '/' + tbl + '?id=eq.999', { token: tok.admin, body: { x: 1 } })).status), 'admin ' + method + ' ' + tbl);
    }
    const ua = await call('PATCH', '/' + tbl + '?id=eq.999', { token: tok.useradmin, body: { x: 1 } });
    assert.strictEqual(ua.status, tables[tbl] ? 200 : 403, 'user admin on ' + tbl);
    assert.strictEqual((await call('GET', '/' + tbl, { token: tok.thandi })).status, 200, 'read ' + tbl);
  }
  // The classic: a signed-in user sending the password-reset write for somebody else.
  const reset = await call('PATCH', '/system_users?id=eq.1', { token: tok.thandi, body: { password_hash: null, must_set_password: true } });
  assert.strictEqual(reset.status, 403);
  assert.strictEqual(db.users[0].must_set_password, false);
  const rows = (await call('GET', '/system_users', { token: tok.thandi })).json;
  assert.ok(rows.length === 4 && rows.every(r => !('password_hash' in r) && !('password_salt' in r)));
  // Other tables are untouched by the guard.
  assert.strictEqual((await call('PATCH', '/deals?id=eq.1', { token: tok.thandi, body: { name: 'x' } })).status, 200);
});
t('a permission change bites at once; an override counts; unreadable permissions refuse', async () => {
  const tok = await staff();
  assert.strictEqual((await call('PATCH', '/roles?id=eq.9', { token: tok.thandi, body: {} })).status, 403);
  db.overrides.push({ user_id: 2, name: 'manage_roles', granted: true });
  assert.strictEqual((await call('PATCH', '/roles?id=eq.9', { token: tok.thandi, body: {} })).status, 403, 'still cached');
  await call('POST', '/user_permission_overrides', { token: tok.admin, body: {} });   // an admin write clears the cache
  assert.strictEqual((await call('PATCH', '/roles?id=eq.9', { token: tok.thandi, body: {} })).status, 200);
  db.overrides.push({ user_id: 3, name: 'manage_system_users', granted: false });
  await call('POST', '/user_permission_overrides', { token: tok.admin, body: {} });
  assert.strictEqual((await call('PATCH', '/system_users?id=eq.999', { token: tok.useradmin, body: {} })).status, 403, 'an override takes it away');
  db.failEmbed = true; clock += 61 * 1000;
  assert.strictEqual((await call('PATCH', '/system_users?id=eq.999', { token: tok.admin, body: {} })).status, 503);
  assert.strictEqual((await call('GET', '/system_users', { token: tok.admin })).status, 200, 'reads carry on');
  assert.strictEqual((await call('PATCH', '/deals?id=eq.1', { token: tok.admin, body: {} })).status, 200);
});
t('permsOf: roles, overrides, Admin', async () => {
  const row = { user_roles: [{ roles: { name: 'Sales', role_permissions: [{ permissions: { name: 'a' } }, { permissions: { name: 'b' } }] } },
    { roles: { name: 'Admin', role_permissions: [] } }, { roles: null }],
    user_permission_overrides: [{ granted: false, permissions: { name: 'a' } }, { granted: true, permissions: { name: 'c' } }, { granted: true, permissions: null }] };
  assert.deepStrictEqual(sb.permsOf(row), { perms: ['b', 'c'], admin: true });
  assert.deepStrictEqual(sb.permsOf({}), { perms: [], admin: false });
});

(async () => {
  sb = await load();
  let failed = 0;
  for (const [name, fn] of tests) {
    try { await fn(); console.log('  ok  ' + name); }
    catch (e) { failed++; console.log('FAIL  ' + name + '\n      ' + String(e && e.stack || e).split('\n').slice(0, 4).join('\n      ')); }
  }
  console.log(`\n${tests.length - failed}/${tests.length} passed`);
  process.exit(failed ? 1 : 0);
})();
