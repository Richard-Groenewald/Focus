const https = require('https');
const crypto = require('crypto');
// Host is env-driven so production vs test databases can be selected per Netlify
// deploy context. Falls back to the production project if SUPABASE_HOST is unset.
const SB = process.env.SUPABASE_HOST || 'kevrfdjqyuhmgziqxuvs.supabase.co';

// Reuse TLS connections to Supabase across warm invocations. Without this, every
// proxied query opened a fresh cross-Atlantic TLS handshake (~the bulk of the
// per-call latency). Module scope so the agent (and its socket pool) survives
// between invocations on a warm function instance.
const sbAgent = new https.Agent({ keepAlive: true, keepAliveMsecs: 30000, maxSockets: 64 });

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type,Prefer,X-Actor-Id,X-Real-Actor-Id,X-Focus-Token',
  'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS',
};

// ── Password hashing ─────────────────────────────────────────────────────────
// PBKDF2-SHA256. Deliberately plain: no dependencies, and it keeps the whole
// verification server-side so a password hash never reaches the browser. This is
// the rudimentary first pass — see sql/add_passwords_and_masquerade.sql.
const PBKDF2_ITER = 120000, PBKDF2_LEN = 32, PBKDF2_ALG = 'sha256';
const hashPassword = (password, salt) =>
  crypto.pbkdf2Sync(String(password), salt, PBKDF2_ITER, PBKDF2_LEN, PBKDF2_ALG).toString('hex');

function passwordMatches(password, salt, expectedHex) {
  if (!salt || !expectedHex) return false;
  const actual = Buffer.from(hashPassword(password, salt), 'hex');
  const expected = Buffer.from(String(expectedHex), 'hex');
  // Length check first: timingSafeEqual throws on a mismatch.
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

// Password policy (Richard, 2026-08-26): at least 8 characters with a lowercase
// letter, an uppercase letter, a number and a special character. Enforced HERE —
// the client-side copy in index.html (PW_MIN + pwPolicyProblems) only drives the
// wording and the live nudge. Keep the two in step.
// Rate limiting (Richard, 2026-08-27): 5 wrong passwords lock the account for
// 15 minutes. Counters live on system_users (failed_login_count, locked_until —
// sql/usernames_password_policy.sql adds them).
const MAX_LOGIN_FAILURES = 5, LOCK_MINUTES = 15;
const PASSWORD_POLICY_MSG = 'Password needs at least 8 characters, with a lowercase letter, an uppercase letter, a number and a special character';
function passwordPolicyError(p) {
  if (typeof p !== 'string' || p.length > 200) return PASSWORD_POLICY_MSG;
  if (p.length < 8) return PASSWORD_POLICY_MSG;
  if (!/[a-z]/.test(p) || !/[A-Z]/.test(p) || !/[0-9]/.test(p) || !/[^A-Za-z0-9]/.test(p)) return PASSWORD_POLICY_MSG;
  return null;
}

// ── Sessions ─────────────────────────────────────────────────────────────────
// The proxy runs on the service key, and Focus has no RLS — so before this,
// ANYONE who knew the function URL could read and write every table; the login
// screen was purely client-side theatre. Now sign-in issues a stateless token
// (v1.<payload>.<hmac>), and every proxied request must carry it or gets a 401.
//
// The signing key is DERIVED from the service key already in the environment
// (HMAC of a fixed label), so no new secret has to be provisioned and the
// service key itself is never used directly as an HMAC key. Stateless means no
// session table, nothing to migrate, and log-out is client-side; the trade-off
// is that a token stays valid until it expires, which at a 24-hour TTL is the
// working day plus slack.
const SESSION_TTL_MS = 24 * 60 * 60 * 1000;
const sessionKey = (key) => crypto.createHmac('sha256', String(key)).update('focus-session-v1').digest();

const b64url = (s) => Buffer.from(s).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64url = (s) => Buffer.from(String(s).replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString();

function issueToken(key, userId, personId) {
  const payload = JSON.stringify({ u: +userId, p: personId == null ? null : +personId, e: Date.now() + SESSION_TTL_MS });
  const body = b64url(payload);
  const sig = crypto.createHmac('sha256', sessionKey(key)).update(body).digest('hex');
  return 'v1.' + body + '.' + sig;
}

function verifyToken(key, token) {
  try {
    const parts = String(token || '').split('.');
    if (parts.length !== 3 || parts[0] !== 'v1') return null;
    const expect = crypto.createHmac('sha256', sessionKey(key)).update(parts[1]).digest();
    const got = Buffer.from(parts[2], 'hex');
    if (got.length !== expect.length || !crypto.timingSafeEqual(got, expect)) return null;
    const payload = JSON.parse(unb64url(parts[1]));
    if (!payload || !payload.u || !payload.e || Date.now() > +payload.e) return null;
    return { userId: +payload.u, personId: payload.p == null ? null : +payload.p };
  } catch (e) { return null; }
}

// Minimal REST helper against Supabase, service key, for the auth endpoint only.
function sbRest(key, method, path, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const req = https.request({
      hostname: SB, port: 443, path: '/rest/v1' + path, method, agent: sbAgent,
      headers: {
        'Content-Type': 'application/json', 'apikey': key, 'Authorization': 'Bearer ' + key,
        'Prefer': method === 'PATCH' ? 'return=representation' : '',
      },
    }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => {
        if (res.statusCode >= 400) return reject(new Error(`HTTP ${res.statusCode}: ${d.slice(0, 200)}`));
        try { resolve(d ? JSON.parse(d) : null); } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

// Credential columns must never leave this function. Focus has no RLS — the proxy
// runs on the service key, so anything PostgREST will serve is reachable by anyone
// who can call the function. That is a known property of the whole app (every
// table is readable), but a password hash + salt is a different order of problem:
// it is an offline brute-force target for every account at once. So the columns
// are stripped from every system_users response, whatever the caller asked for.
const CREDENTIAL_COLUMNS = ['password_hash', 'password_salt', 'password'];
function scrubCredentials(bodyText) {
  let parsed;
  try { parsed = JSON.parse(bodyText); } catch (e) { return bodyText; }   // errors, empties: untouched
  const strip = (o) => {
    if (!o || typeof o !== 'object') return o;
    CREDENTIAL_COLUMNS.forEach(c => { if (c in o) delete o[c]; });
    return o;
  };
  const out = Array.isArray(parsed) ? parsed.map(strip) : strip(parsed);
  return JSON.stringify(out);
}

const authReply = (statusCode, obj) => ({
  statusCode, headers: { 'Content-Type': 'application/json', ...CORS }, body: JSON.stringify(obj),
});

// POST /.netlify/functions/sb/auth
//   { action: 'env' }                                    -> the environment label
//   { action: 'check', username|userId }                 -> does this user still need to choose one?
//   { action: 'login', username|userId, password }       -> verify; returns a session token
//   { action: 'set',   username|userId, password, newPassword }
//                                                        -> first-time set (password ignored) or
//                                                           change; returns a fresh token
// Sign-in is by TYPED username (= first name, case-insensitive) since v7.8.86 —
// the public 'users' roster action is gone; nothing pre-login enumerates accounts.
// The userId form remains for in-app flows (change password) that already hold a
// session. Never returns a hash, a salt, or any hint about which half of a wrong
// pair was wrong. Failures are deliberately uniform.
async function handleAuth(event, key) {
  let body;
  try { body = JSON.parse(event.body || '{}'); } catch (e) { return authReply(400, { ok: false, error: 'Bad request' }); }

  // The one pre-login lookup the login screen still needs.
  if (body.action === 'env') {
    try {
      const rows = await sbRest(key, 'GET', '/settings?key=eq.environment&select=value');
      return authReply(200, { ok: true, environment: (rows && rows[0] && rows[0].value) || '' });
    } catch (e) { return authReply(200, { ok: true, environment: '' }); }
  }

  const SELECT = 'select=id,person_id,active,password_hash,password_salt,must_set_password,failed_login_count,locked_until';
  let rows;
  try {
    const uname = String(body.username || '').trim();
    if (uname) {
      if (uname.length > 80) return authReply(400, { ok: false, error: 'Bad request' });
      // ilike without wildcards = case-insensitive equality.
      rows = await sbRest(key, 'GET', `/system_users?username=ilike.${encodeURIComponent(uname)}&${SELECT}`);
    } else {
      const userId = parseInt(body.userId, 10);
      if (!userId) return authReply(400, { ok: false, error: 'Bad request' });
      rows = await sbRest(key, 'GET', `/system_users?id=eq.${userId}&${SELECT}`);
    }
  } catch (e) { return authReply(500, { ok: false, error: 'Sign-in is unavailable right now' }); }

  const user = rows && rows[0];
  if (!user || user.active === false) return authReply(200, { ok: false, error: 'Sign-in failed' });
  const userId = +user.id;
  const hasPw = !!user.password_hash;
  const mustSet = !!user.must_set_password || !hasPw;

  // Account lock: MAX_LOGIN_FAILURES wrong passwords lock the account for
  // LOCK_MINUTES. Counted on login AND on a wrong current-password in 'set'
  // (both are guessing surfaces); any successful verify clears the slate.
  const locked = user.locked_until && Date.parse(user.locked_until) > Date.now();
  const LOCK_MSG = 'Too many failed attempts — try again in a few minutes';
  const registerFailure = async () => {
    const fails = (+user.failed_login_count || 0) + 1;
    const patch = fails >= MAX_LOGIN_FAILURES
      ? { failed_login_count: 0, locked_until: new Date(Date.now() + LOCK_MINUTES * 60000).toISOString() }
      : { failed_login_count: fails };
    try { await sbRest(key, 'PATCH', `/system_users?id=eq.${userId}`, patch); } catch (e) {}
  };
  const clearFailures = async () => {
    if (!(+user.failed_login_count || 0) && !user.locked_until) return;
    try { await sbRest(key, 'PATCH', `/system_users?id=eq.${userId}`, { failed_login_count: 0, locked_until: null }); } catch (e) {}
  };

  // 'check' drives the login card's panel choice. Only a TRULY passwordless
  // account may see the set panel unverified; an account holding a temp (or
  // current) password reaches the set panel through 'login', which verifies it.
  if (body.action === 'check') return authReply(200, { ok: true, mustSet: mustSet && !hasPw });

  if (body.action === 'set') {
    if (locked) return authReply(200, { ok: false, error: LOCK_MSG });
    // The current password is required whenever one EXISTS — including a
    // must_set account holding an admin-issued temp password. Only a truly
    // passwordless first-time set may skip it.
    if (hasPw && !passwordMatches(String(body.password || ''), user.password_salt, user.password_hash)) {
      await registerFailure();
      return authReply(200, { ok: false, error: 'Current password is incorrect' });
    }
    const next = String(body.newPassword || '');
    const policyError = passwordPolicyError(next);
    if (policyError) return authReply(200, { ok: false, error: policyError });
    const salt = crypto.randomBytes(16).toString('hex');
    try {
      await sbRest(key, 'PATCH', `/system_users?id=eq.${userId}`, {
        password_hash: hashPassword(next, salt),
        password_salt: salt,
        password_set_at: new Date().toISOString(),
        must_set_password: false,
        failed_login_count: 0,
        locked_until: null,
      });
    } catch (e) { return authReply(500, { ok: false, error: 'Could not save the password' }); }
    // Setting a password IS proving you hold it — sign the session straight away.
    return authReply(200, { ok: true, set: true,
      token: issueToken(key, userId, user.person_id), userId, personId: user.person_id });
  }

  if (body.action === 'login') {
    if (locked) return authReply(200, { ok: false, error: LOCK_MSG });
    if (mustSet && !hasPw) return authReply(200, { ok: false, mustSet: true, error: 'Choose a password to continue' });
    const ok = passwordMatches(String(body.password || ''), user.password_salt, user.password_hash);
    if (!ok) { await registerFailure(); return authReply(200, { ok: false, error: 'Sign-in failed' }); }
    if (mustSet) {
      // Temp (or pre-reset) password verified — now they choose their own.
      // No session yet: the token comes from completing 'set'.
      await clearFailures();
      return authReply(200, { ok: false, mustSet: true, error: 'Choose your own password to continue' });
    }
    await clearFailures();
    return authReply(200, { ok: true, token: issueToken(key, userId, user.person_id), userId, personId: user.person_id });
  }

  return authReply(400, { ok: false, error: 'Bad request' });
}

exports.handler = async (event) => {
  const KEY = process.env.SUPABASE_SECRET_KEY;
  if (!KEY) return { statusCode: 500, headers: { 'Access-Control-Allow-Origin': '*' }, body: 'Missing SUPABASE_SECRET_KEY env var' };
  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers: CORS, body: '' };

  const path = event.path.replace('/.netlify/functions/sb', '/rest/v1');
  // Auth is handled here, not proxied: the browser must never be able to read
  // password_hash / password_salt, and PostgREST would happily serve them.
  if (/\/rest\/v1\/auth\/?$/.test(path)) {
    if (event.httpMethod !== 'POST') return authReply(405, { ok: false, error: 'Bad request' });
    return handleAuth(event, KEY);
  }

  // ── The session gate ──
  // Everything else requires a valid token. 401 carries a stable marker the app
  // recognises to drop back to the sign-in screen.
  const session = verifyToken(KEY, event.headers['x-focus-token']);
  if (!session) {
    return { statusCode: 401, headers: { 'Content-Type': 'application/json', ...CORS },
             body: JSON.stringify({ error: 'auth', message: 'Sign in required' }) };
  }

  // Audit attribution is no longer taken on trust. The effective actor may be a
  // masquerade target, but whenever it differs from the person the TOKEN belongs
  // to, the real-actor header is overwritten with the token's person — so the
  // audit trail always records who actually held the session.
  const claimedActor = event.headers['x-actor-id'] || '';
  const tokenPerson = session.personId == null ? '' : String(session.personId);
  const realActor = (claimedActor && tokenPerson && claimedActor !== tokenPerson)
    ? tokenPerson
    : (event.headers['x-real-actor-id'] || '');

  const qs = event.rawQuery ? '?' + event.rawQuery : '';
  const isSystemUsers = /\/rest\/v1\/system_users\b/.test(path);
  return new Promise(resolve => {
    const doReq = (attempt) => {
      const req = https.request({
        hostname: SB, port: 443, path: path + qs, method: event.httpMethod, agent: sbAgent,
        // x-actor-id: the app's current EFFECTIVE user (the one being masqueraded
        // as, if any). x-real-actor-id: the human actually at the keyboard —
        // server-enforced from the session token whenever the two differ. Both are
        // forwarded so the DB audit trigger can read them from PostgREST's
        // request.headers GUC (sql/add_audit_log.sql).
        headers: {
          'Content-Type': 'application/json', 'apikey': KEY, 'Authorization': 'Bearer ' + KEY,
          'Prefer': event.headers['prefer'] || '',
          'X-Actor-Id': claimedActor || tokenPerson,
          'X-Real-Actor-Id': realActor,
        }
      }, res => {
        let d = ''; res.on('data', c => d += c);
        res.on('end', () => resolve({
          statusCode: res.statusCode,
          headers: { 'Content-Type': 'application/json', ...CORS },
          body: isSystemUsers ? scrubCredentials(d) : d
        }));
      });
      req.on('error', e => {
        // Stale keep-alive socket: Supabase's LB closes idle connections, and a
        // warm invocation that reuses one gets ECONNRESET / "socket hang up"
        // before the request was processed. Retry ONCE on a fresh socket — but
        // ONLY for GET (v7.8.87): a write whose socket died may still have
        // landed, and retrying it server-side is a duplicate-row machine.
        const stale = event.httpMethod === 'GET'
          && req.reusedSocket && (e.code === 'ECONNRESET' || /socket hang up/i.test(e.message));
        if (attempt === 0 && stale) return doReq(1);
        resolve({ statusCode: 500, body: JSON.stringify({ error: e.message }) });
      });
      if (event.body) req.write(event.body);
      req.end();
    };
    doReq(0);
  });
};
