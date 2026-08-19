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
  'Access-Control-Allow-Headers': 'Content-Type,Prefer,X-Actor-Id,X-Real-Actor-Id',
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

// 8+ characters. Any letters, digits or punctuation are allowed — no composition
// rules, on purpose: length is what matters and arbitrary rules push people to
// write passwords down. Tightened later with the wider permissions work.
const passwordAcceptable = (p) => typeof p === 'string' && p.length >= 8 && p.length <= 200;

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

const authReply = (statusCode, obj) => ({
  statusCode, headers: { 'Content-Type': 'application/json', ...CORS }, body: JSON.stringify(obj),
});

// POST /.netlify/functions/sb/auth
//   { action: 'check', userId }                        -> does this user still need to choose one?
//   { action: 'login', userId, password }              -> verify
//   { action: 'set',   userId, password, newPassword } -> first-time set (password ignored) or change
// Never returns a hash, a salt, or any hint about which half of a wrong pair was
// wrong. Failures are deliberately uniform.
async function handleAuth(event, key) {
  let body;
  try { body = JSON.parse(event.body || '{}'); } catch (e) { return authReply(400, { ok: false, error: 'Bad request' }); }
  const userId = parseInt(body.userId, 10);
  if (!userId) return authReply(400, { ok: false, error: 'Bad request' });

  let rows;
  try {
    rows = await sbRest(key, 'GET',
      `/system_users?id=eq.${userId}&select=id,active,password_hash,password_salt,must_set_password`);
  } catch (e) { return authReply(500, { ok: false, error: 'Sign-in is unavailable right now' }); }

  const user = rows && rows[0];
  if (!user || user.active === false) return authReply(200, { ok: false, error: 'Sign-in failed' });
  const mustSet = !!user.must_set_password || !user.password_hash;

  if (body.action === 'check') return authReply(200, { ok: true, mustSet });

  if (body.action === 'set') {
    // Changing an existing password requires the current one. A first-time set
    // (must_set_password, straight after the migration) does not.
    if (!mustSet && !passwordMatches(String(body.password || ''), user.password_salt, user.password_hash)) {
      return authReply(200, { ok: false, error: 'Current password is incorrect' });
    }
    const next = String(body.newPassword || '');
    if (!passwordAcceptable(next)) {
      return authReply(200, { ok: false, error: 'Password must be at least 8 characters' });
    }
    const salt = crypto.randomBytes(16).toString('hex');
    try {
      await sbRest(key, 'PATCH', `/system_users?id=eq.${userId}`, {
        password_hash: hashPassword(next, salt),
        password_salt: salt,
        password_set_at: new Date().toISOString(),
        must_set_password: false,
      });
    } catch (e) { return authReply(500, { ok: false, error: 'Could not save the password' }); }
    return authReply(200, { ok: true, set: true });
  }

  if (body.action === 'login') {
    if (mustSet) return authReply(200, { ok: false, mustSet: true, error: 'Choose a password to continue' });
    const ok = passwordMatches(String(body.password || ''), user.password_salt, user.password_hash);
    return authReply(200, ok ? { ok: true } : { ok: false, error: 'Sign-in failed' });
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

  const qs = event.rawQuery ? '?' + event.rawQuery : '';
  return new Promise(resolve => {
    const doReq = (attempt) => {
      const req = https.request({
        hostname: SB, port: 443, path: path + qs, method: event.httpMethod, agent: sbAgent,
        // x-actor-id: the app's current EFFECTIVE user (the one being masqueraded
        // as, if any). x-real-actor-id: the human actually at the keyboard, sent
        // only during a masquerade. Both are forwarded so the DB audit trigger can
        // read them from PostgREST's request.headers GUC (sql/add_audit_log.sql,
        // sql/add_passwords_and_masquerade.sql).
        headers: {
          'Content-Type': 'application/json', 'apikey': KEY, 'Authorization': 'Bearer ' + KEY,
          'Prefer': event.headers['prefer'] || '',
          'X-Actor-Id': event.headers['x-actor-id'] || '',
          'X-Real-Actor-Id': event.headers['x-real-actor-id'] || '',
        }
      }, res => {
        let d = ''; res.on('data', c => d += c);
        res.on('end', () => resolve({
          statusCode: res.statusCode,
          headers: { 'Content-Type': 'application/json', ...CORS },
          body: d
        }));
      });
      req.on('error', e => {
        // Stale keep-alive socket: Supabase's LB closes idle connections, and a
        // warm invocation that reuses one gets ECONNRESET / "socket hang up"
        // before the request was processed. Retry ONCE on a fresh socket —
        // only for reused-socket connection errors, so real outages still fail.
        const stale = req.reusedSocket && (e.code === 'ECONNRESET' || /socket hang up/i.test(e.message));
        if (attempt === 0 && stale) return doReq(1);
        resolve({ statusCode: 500, body: JSON.stringify({ error: e.message }) });
      });
      if (event.body) req.write(event.body);
      req.end();
    };
    doReq(0);
  });
};
