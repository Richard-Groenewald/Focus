// Focus API proxy as a Supabase Edge Function (v7.10.21).
//
// A port of netlify/functions/sb.js with the SAME wire contract — routes, headers,
// session tokens, error bodies — so index.html, time.html and Focus.html only had to
// change the base path. Why it exists: every Focus call used to travel browser (SA)
// → Netlify Lambda (AWS us-east-1) → Supabase (eu-west-1) → back, two Atlantic
// crossings per request (~600 ms of pure network for an 18 ms query). Running the
// proxy here, pinned to the database's own region by the `x-region` header on the
// Netlify rewrite (netlify.toml), removes the second crossing. The Netlify function
// stays deployed as the rollback: point FN_URL back at it and redeploy.
//
// Deployed per Supabase project (prod and test each run their own copy against
// their own database — SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected by the
// platform), with verify_jwt OFF: the session gate below is the authentication,
// exactly as it was on Netlify. Deploy with the Supabase MCP / CLI, not Netlify.
//
// Behavioural differences from sb.js, all deliberate:
//   • gzip is produced here (CompressionStream) rather than passed through from the
//     gateway, because Deno's fetch inflates upstream bodies transparently; same
//     X-Focus-Gzip / X-Focus-Encoding contract, bodies under 1 KB stay plain;
//   • the PostgREST total also rides in X-Focus-Content-Range, a private twin of
//     Content-Range, in case an intermediary drops the standard header on a 200;
//   • no keep-alive agent / stale-socket retry: Deno pools connections itself (a GET
//     whose fetch throws is still retried once).

const te = new TextEncoder();
const td = new TextDecoder();
const env = (k: string): string => {
  try { if (typeof Deno !== 'undefined' && Deno.env) return Deno.env.get(k) || ''; } catch (_e) { /* no env permission */ }
  const p = (globalThis as any).process;
  return (p && p.env && p.env[k]) || '';
};

// Service key: the platform injects the project's own service_role JWT. The session
// signing key is DERIVED from it (see sessionKey), so tokens issued by the Netlify
// function — same JWT under SUPABASE_SECRET_KEY — stay valid across the cutover.
const KEY = env('FOCUS_SERVICE_KEY') || env('SUPABASE_SERVICE_ROLE_KEY') || env('SUPABASE_SECRET_KEY');
const SB = (() => {
  if (env('SUPABASE_HOST')) return env('SUPABASE_HOST');
  try { return new URL(env('SUPABASE_URL')).hostname; } catch (_e) { return 'kevrfdjqyuhmgziqxuvs.supabase.co'; }
})();

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type,Prefer,Range,Range-Unit,X-Actor-Id,X-Real-Actor-Id,X-Focus-Token,X-Focus-Gzip',
  'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS',
  'Access-Control-Expose-Headers': 'Content-Range,X-Focus-Content-Range,X-Focus-Encoding',
};

// ── Byte helpers ─────────────────────────────────────────────────────────────
const hex = (buf: ArrayBuffer | Uint8Array): string =>
  Array.from(buf instanceof Uint8Array ? buf : new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
// Strict hex → bytes; null on anything malformed (Node's Buffer.from(…,'hex') would
// silently truncate instead — either way the compare below fails, which is the point).
function unhex(s: unknown): Uint8Array | null {
  const str = String(s == null ? '' : s);
  if (!str || str.length % 2 || /[^0-9a-fA-F]/.test(str)) return null;
  const out = new Uint8Array(str.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(str.substr(i * 2, 2), 16);
  return out;
}
function timingSafeEqual(a: Uint8Array | null, b: Uint8Array | null): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}
const bytesToB64 = (bytes: Uint8Array): string => {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
};
const b64ToBytes = (b64: string): Uint8Array => {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
};

// ── Password hashing ─────────────────────────────────────────────────────────
// PBKDF2-SHA256, 120k iterations, 32 bytes, hex — byte-identical to the Node
// crypto.pbkdf2Sync(password, salt, …) call in sb.js (string salt = its UTF-8 bytes).
const PBKDF2_ITER = 120000, PBKDF2_BITS = 256;
export async function hashPassword(password: unknown, salt: unknown): Promise<string> {
  const km = await crypto.subtle.importKey('raw', te.encode(String(password)), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt: te.encode(String(salt)), iterations: PBKDF2_ITER }, km, PBKDF2_BITS);
  return hex(bits);
}

export async function passwordMatches(password: unknown, salt: unknown, expectedHex: unknown): Promise<boolean> {
  if (!salt || !expectedHex) return false;
  const pw = String(password == null ? '' : password);
  if (!pw) return false;   // the policy never produced a hash of '' — and an empty PBKDF2 key is runtime-dependent
  try {
    const actual = unhex(await hashPassword(pw, salt));
    return timingSafeEqual(actual, unhex(expectedHex));
  } catch (_e) { return false; }
}

// Password policy (Richard, 2026-08-26) — enforced HERE; index.html's copy only
// drives the wording. Rate limiting (2026-08-27): 5 wrong passwords lock the
// account for 15 minutes (system_users.failed_login_count / locked_until).
const MAX_LOGIN_FAILURES = 5, LOCK_MINUTES = 15;
const PASSWORD_POLICY_MSG = 'Password needs at least 8 characters, with a lowercase letter, an uppercase letter, a number and a special character';
export function passwordPolicyError(p: unknown): string | null {
  if (typeof p !== 'string' || p.length > 200) return PASSWORD_POLICY_MSG;
  if (p.length < 8) return PASSWORD_POLICY_MSG;
  if (!/[a-z]/.test(p) || !/[A-Z]/.test(p) || !/[0-9]/.test(p) || !/[^A-Za-z0-9]/.test(p)) return PASSWORD_POLICY_MSG;
  return null;
}

// ── Sessions ─────────────────────────────────────────────────────────────────
// Stateless token v2.<payload>.<hmac>; the signing key is HMAC(service key,
// 'focus-session-v1'). Payload carries u (user id), p (person id), e (expiry),
// v (session_version at sign-in, confirmed against the row on every request).
const SESSION_TTL_MS = 24 * 60 * 60 * 1000;
async function hmacSha256(keyBytes: Uint8Array, data: string): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey('raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, te.encode(data)));
}
const _sessionKeys = new Map<string, Promise<Uint8Array>>();
function sessionKey(key: string): Promise<Uint8Array> {
  let p = _sessionKeys.get(key);
  if (!p) { p = hmacSha256(te.encode(String(key)), 'focus-session-v1'); _sessionKeys.set(key, p); }
  return p;
}

export const b64url = (s: string): string =>
  bytesToB64(te.encode(s)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
export const unb64url = (s: unknown): string => {
  let t = String(s).replace(/-/g, '+').replace(/_/g, '/');
  while (t.length % 4) t += '=';
  return td.decode(b64ToBytes(t));
};

export async function issueToken(key: string, userId: unknown, personId: unknown, version: unknown): Promise<string> {
  const payload = JSON.stringify({ u: +(userId as any), p: personId == null ? null : +(personId as any), e: Date.now() + SESSION_TTL_MS, v: +(version as any) || 1 });
  const body = b64url(payload);
  const sig = hex(await hmacSha256(await sessionKey(key), body));
  return 'v2.' + body + '.' + sig;
}

export type Session = { userId: number; personId: number | null; version: number };
export async function verifyToken(key: string, token: unknown): Promise<Session | null> {
  try {
    const parts = String(token || '').split('.');
    if (parts.length !== 3 || parts[0] !== 'v2') return null;
    const expect = await hmacSha256(await sessionKey(key), parts[1]);
    if (!timingSafeEqual(unhex(parts[2]), expect)) return null;
    const payload = JSON.parse(unb64url(parts[1]));
    if (!payload || !payload.u || !payload.e || Date.now() > +payload.e) return null;
    if (typeof payload.v !== 'number' || !(payload.v >= 1)) return null;
    return { userId: +payload.u, personId: payload.p == null ? null : +payload.p, version: payload.v };
  } catch (_e) { return null; }
}

// ── Session revocation ──
// Every proxied request also confirms the account is still active and that its
// session_version still matches the token's (bumped by a DB trigger on password
// change / forced reset / deactivation). Cached per warm isolate for
// SESSION_CHECK_MS; a write to system_users through this proxy clears the cache.
const SESSION_CHECK_MS = 60 * 1000;
const sessionCache = new Map<number, { active: boolean; version: number; at: number }>();

async function sessionLive(session: Session): Promise<'ok' | 'revoked' | 'error'> {
  const now = Date.now();
  let entry = sessionCache.get(session.userId);
  if (!entry || now - entry.at > SESSION_CHECK_MS) {
    let rows: any;
    try { rows = await sbRest('GET', `/system_users?id=eq.${session.userId}&select=active,session_version`); }
    catch (_e) { return 'error'; }
    const row = rows && rows[0];
    entry = { active: !!row && row.active !== false, version: row ? +row.session_version : -1, at: now };
    sessionCache.set(session.userId, entry);
  }
  return (entry.active && entry.version === session.version) ? 'ok' : 'revoked';
}

// Minimal REST helper against this project's PostgREST, service key, for the
// auth / files / session paths (the data proxy below forwards the raw request).
async function sbRest(method: string, path: string, body?: unknown): Promise<any> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json', 'apikey': KEY, 'Authorization': 'Bearer ' + KEY };
  if (method === 'PATCH' || method === 'POST') headers['Prefer'] = 'return=representation';
  const res = await fetch(`https://${SB}/rest/v1${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const d = await res.text();
  if (res.status >= 400) throw new Error(`HTTP ${res.status}: ${d.slice(0, 200)}`);
  return d ? JSON.parse(d) : null;
}

async function sbStorage(method: string, path: string, body?: unknown): Promise<any> {
  const res = await fetch(`https://${SB}/storage/v1${path}`, {
    method, headers: { 'Content-Type': 'application/json', 'apikey': KEY, 'Authorization': 'Bearer ' + KEY },
    body: JSON.stringify(body || {}),
  });
  const d = await res.text();
  if (res.status >= 400) throw new Error(`HTTP ${res.status}: ${d.slice(0, 200)}`);
  return d ? JSON.parse(d) : null;
}

// Credential columns never leave this function: Focus has no RLS, so anything
// PostgREST will serve is reachable by anyone who can call it; a hash + salt is an
// offline brute-force target. Stripped from every system_users response.
const CREDENTIAL_COLUMNS = ['password_hash', 'password_salt', 'password'];
export function scrubCredentials(bodyText: string): string {
  let parsed: any;
  try { parsed = JSON.parse(bodyText); } catch (_e) { return bodyText; }   // errors, empties: untouched
  const strip = (o: any) => {
    if (!o || typeof o !== 'object') return o;
    CREDENTIAL_COLUMNS.forEach(c => { if (c in o) delete o[c]; });
    return o;
  };
  const out = Array.isArray(parsed) ? parsed.map(strip) : strip(parsed);
  return JSON.stringify(out);
}

// The audit trail is the side door: the same keys are stripped one level down
// inside each audit_log row's changes / row_data documents (backstop for
// sql/audit_log_scrub_credentials.sql).
export function scrubAuditCredentials(bodyText: string): string {
  let parsed: any;
  try { parsed = JSON.parse(bodyText); } catch (_e) { return bodyText; }
  const strip = (row: any) => {
    if (!row || typeof row !== 'object') return row;
    ['changes', 'row_data'].forEach(k => {
      const doc = row[k];
      if (doc && typeof doc === 'object') CREDENTIAL_COLUMNS.forEach(c => { if (c in doc) delete doc[c]; });
    });
    return row;
  };
  const out = Array.isArray(parsed) ? parsed.map(strip) : strip(parsed);
  return JSON.stringify(out);
}

// ── Sign-in log ──
// Every attempt against a real account becomes a user_sessions row: 'ok' opens the
// session the app keeps alive through log_activity(); 'failed' / 'locked' record
// refused attempts. Best effort — an absent table never blocks a sign-in.
function clientIp(req: Request): string | null {
  const h = req.headers;
  return h.get('x-nf-client-connection-ip')
    || String(h.get('x-forwarded-for') || '').split(',')[0].trim()
    || h.get('cf-connecting-ip')
    || null;
}
async function logSignIn(req: Request, user: any, outcome: string): Promise<number | null> {
  try {
    const rows = await sbRest('POST', '/user_sessions', {
      system_user_id: +user.id, person_id: user.person_id == null ? null : +user.person_id, outcome,
      user_agent: String(req.headers.get('user-agent') || '').slice(0, 400) || null, ip: clientIp(req),
    });
    return rows && rows[0] ? +rows[0].id : null;
  } catch (_e) { return null; }
}

const json = (status: number, obj: unknown, extra?: Record<string, string>) =>
  new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json', ...CORS, ...(extra || {}) } });
const authReply = json;

// ── Files ────────────────────────────────────────────────────────────────────
// Attachments live in the PRIVATE Storage bucket 'attachments'. This route never
// carries a file's bytes — it signs:
//   POST /files { action:'upload', owner:'deal', owner_id, file_name, size }
//        -> { ok, path, uploadUrl }  a one-time URL the browser PUTs the file to
//   GET  /files?download=<attachments.id>
//        -> { ok, url }              a 5-minute URL that downloads under the file's name
const FILE_BUCKET = 'attachments';
const FILE_MAX_BYTES = 50 * 1024 * 1024;
const FILE_OWNERS: Record<string, string> = { deal: 'deals' };   // a contract or project is the same deals row once secured
const encPath = (p: string) => String(p).split('/').map(encodeURIComponent).join('/');

async function handleFiles(req: Request, url: URL): Promise<Response> {
  if (req.method === 'GET') {
    const id = parseInt(url.searchParams.get('download') || '', 10);
    if (!id) return authReply(400, { ok: false, error: 'Bad request' });
    let rows: any;
    try { rows = await sbRest('GET', `/attachments?id=eq.${id}&removed_at=is.null&select=storage_path,file_name`); }
    catch (_e) { return authReply(500, { ok: false, error: 'Files are unavailable right now' }); }
    const f = rows && rows[0];
    if (!f) return authReply(404, { ok: false, error: 'File not found' });
    let signed: any;
    try { signed = await sbStorage('POST', `/object/sign/${FILE_BUCKET}/${encPath(f.storage_path)}`, { expiresIn: 300 }); }
    catch (_e) { return authReply(502, { ok: false, error: 'File storage is unavailable right now' }); }
    const rel = signed && (signed.signedURL || signed.signedUrl);
    if (!rel) return authReply(502, { ok: false, error: 'File storage is unavailable right now' });
    return authReply(200, { ok: true, url: 'https://' + SB + '/storage/v1' + rel + '&download=' + encodeURIComponent(f.file_name) });
  }
  if (req.method !== 'POST') return authReply(405, { ok: false, error: 'Bad request' });
  let body: any;
  try { body = JSON.parse((await req.text()) || '{}'); } catch (_e) { return authReply(400, { ok: false, error: 'Bad request' }); }
  if (body.action !== 'upload') return authReply(400, { ok: false, error: 'Bad request' });
  const table = FILE_OWNERS[body.owner];
  const ownerId = parseInt(body.owner_id, 10);
  const size = Number(body.size);
  if (!table || !ownerId) return authReply(400, { ok: false, error: 'Bad request' });
  if (!(size >= 0) || size > FILE_MAX_BYTES) return authReply(400, { ok: false, error: 'Files are limited to 50 MB' });
  try {
    const owner = await sbRest('GET', `/${table}?id=eq.${ownerId}&select=id`);
    if (!owner || !owner.length) return authReply(404, { ok: false, error: 'Record not found' });
  } catch (_e) { return authReply(500, { ok: false, error: 'Files are unavailable right now' }); }
  // The stored name is only a path segment; the real name lives on the row.
  const safe = String(body.file_name || 'file').normalize('NFKD')
    .replace(/[^\w.\- ]+/g, '_').replace(/\s+/g, '_').slice(-120) || 'file';
  const path = `${body.owner}/${ownerId}/${crypto.randomUUID()}/${safe}`;
  let signed: any;
  try { signed = await sbStorage('POST', `/object/upload/sign/${FILE_BUCKET}/${encPath(path)}`, {}); }
  catch (_e) { return authReply(502, { ok: false, error: 'File storage is unavailable right now' }); }
  const rel = signed && (signed.url || (signed.token ? `/object/upload/sign/${FILE_BUCKET}/${encPath(path)}?token=${signed.token}` : null));
  if (!rel) return authReply(502, { ok: false, error: 'File storage is unavailable right now' });
  return authReply(200, { ok: true, path, uploadUrl: 'https://' + SB + '/storage/v1' + rel });
}

// ── Auth ─────────────────────────────────────────────────────────────────────
// POST /auth
//   { action: 'env' }                                    -> the environment label
//   { action: 'check', username|userId }                 -> does this user still need to choose one?
//   { action: 'login', username|userId, password }       -> verify; returns a session token
//   { action: 'set',   username|userId, password, newPassword }
//                                                        -> first-time set (password ignored) or
//                                                           change; returns a fresh token
// Sign-in is by TYPED username (= first name, case-insensitive); nothing pre-login
// enumerates accounts. Never returns a hash, a salt, or any hint about which half
// of a wrong pair was wrong. Failures are deliberately uniform.
// MAINTENANCE MODE (2026-10-07): Focus is on-line for the system_users ids below only
// (4 = Richard, 12 = Lesley-Anne); everyone else is turned away at sign-in and on every
// proxied call, and the client sends them to /maintenance.html. To open Focus to all,
// set MAINTENANCE_ON to false and redeploy this function (prod AND test).
const MAINTENANCE_ON = true;
const MAINTENANCE_ALLOW = [4, 12];
const maintenanceBlocks = (userId: unknown) => MAINTENANCE_ON && !MAINTENANCE_ALLOW.includes(+(userId as any));

async function handleAuth(req: Request): Promise<Response> {
  let body: any;
  try { body = JSON.parse((await req.text()) || '{}'); } catch (_e) { return authReply(400, { ok: false, error: 'Bad request' }); }

  // The one pre-login lookup the login screen still needs.
  if (body.action === 'env') {
    try {
      const rows = await sbRest('GET', '/settings?key=eq.environment&select=value');
      return authReply(200, { ok: true, environment: (rows && rows[0] && rows[0].value) || '' });
    } catch (_e) { return authReply(200, { ok: true, environment: '' }); }
  }

  const SELECT = 'select=id,person_id,active,password_hash,password_salt,must_set_password,failed_login_count,locked_until,session_version';
  let rows: any;
  try {
    const uname = String(body.username || '').trim();
    if (uname) {
      if (uname.length > 80) return authReply(400, { ok: false, error: 'Bad request' });
      // ilike without wildcards = case-insensitive equality.
      rows = await sbRest('GET', `/system_users?username=ilike.${encodeURIComponent(uname)}&${SELECT}`);
    } else {
      const userId = parseInt(body.userId, 10);
      if (!userId) return authReply(400, { ok: false, error: 'Bad request' });
      rows = await sbRest('GET', `/system_users?id=eq.${userId}&${SELECT}`);
    }
  } catch (_e) { return authReply(500, { ok: false, error: 'Sign-in is unavailable right now' }); }

  const user = rows && rows[0];
  if (!user || user.active === false) return authReply(200, { ok: false, error: 'Sign-in failed' });
  const userId = +user.id;
  if (body.action !== 'check' && maintenanceBlocks(userId)) return authReply(200, { ok: false, maintenance: true, error: 'Focus is off-line for maintenance' });
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
    try { await sbRest('PATCH', `/system_users?id=eq.${userId}`, patch); } catch (_e) { /* best effort */ }
    await logSignIn(req, user, fails >= MAX_LOGIN_FAILURES ? 'locked' : 'failed');
  };
  const clearFailures = async () => {
    if (!(+user.failed_login_count || 0) && !user.locked_until) return;
    try { await sbRest('PATCH', `/system_users?id=eq.${userId}`, { failed_login_count: 0, locked_until: null }); } catch (_e) { /* best effort */ }
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
    if (hasPw && !(await passwordMatches(String(body.password || ''), user.password_salt, user.password_hash))) {
      await registerFailure();
      return authReply(200, { ok: false, error: 'Current password is incorrect' });
    }
    const next = String(body.newPassword || '');
    const policyError = passwordPolicyError(next);
    if (policyError) return authReply(200, { ok: false, error: policyError });
    const salt = hex(crypto.getRandomValues(new Uint8Array(16)));
    let updated: any;
    try {
      updated = await sbRest('PATCH', `/system_users?id=eq.${userId}`, {
        password_hash: await hashPassword(next, salt),
        password_salt: salt,
        password_set_at: new Date().toISOString(),
        must_set_password: false,
        failed_login_count: 0,
        locked_until: null,
      });
    } catch (_e) { return authReply(500, { ok: false, error: 'Could not save the password' }); }
    // The hash write bumped session_version (DB trigger), so every OTHER session
    // this user held is now dead. Sign the new session with the version the row
    // carries after the write, and drop this isolate's cached verdict.
    const fresh = updated && updated[0] && updated[0].session_version != null
      ? +updated[0].session_version : (+user.session_version || 1) + 1;
    sessionCache.delete(userId);
    // Setting a password IS proving you hold it — sign the session straight away.
    // From the login screen (username) that is a sign-in; an in-app change keeps its session.
    const sessionId = String(body.username || '').trim() ? await logSignIn(req, user, 'ok') : null;
    return authReply(200, { ok: true, set: true,
      token: await issueToken(KEY, userId, user.person_id, fresh), userId, personId: user.person_id, sessionId });
  }

  if (body.action === 'login') {
    if (locked) { await logSignIn(req, user, 'locked'); return authReply(200, { ok: false, error: LOCK_MSG }); }
    if (mustSet && !hasPw) return authReply(200, { ok: false, mustSet: true, error: 'Choose a password to continue' });
    const ok = await passwordMatches(String(body.password || ''), user.password_salt, user.password_hash);
    if (!ok) { await registerFailure(); return authReply(200, { ok: false, error: 'Sign-in failed' }); }
    if (mustSet) {
      // Temp (or pre-reset) password verified — now they choose their own.
      // No session yet: the token comes from completing 'set'.
      await clearFailures();
      return authReply(200, { ok: false, mustSet: true, error: 'Choose your own password to continue' });
    }
    await clearFailures();
    const sessionId = await logSignIn(req, user, 'ok');
    return authReply(200, { ok: true, token: await issueToken(KEY, userId, user.person_id, user.session_version), userId, personId: user.person_id, sessionId });
  }

  return authReply(400, { ok: false, error: 'Bad request' });
}

// ── The proxy ────────────────────────────────────────────────────────────────
const GZIP_MIN_BYTES = 1024;
async function gzipBytes(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('gzip'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

// The function is served at /functions/v1/sb/… and sees its own name as the first
// path segment (the gateway strips /functions/v1; tolerated here in case it ever
// does not); everything after it is the PostgREST path (or /auth, /files).
function restPath(url: URL): string {
  let p = url.pathname.replace(/^\/functions\/v1(?=\/)/, '').replace(/^\/sb(?=\/|$)/, '');
  if (!p.startsWith('/')) p = '/' + p;
  return p;
}

export async function handler(req: Request): Promise<Response> {
  if (!KEY) return new Response('Missing service key', { status: 500, headers: { 'Access-Control-Allow-Origin': '*' } });
  if (req.method === 'OPTIONS') return new Response('', { status: 200, headers: CORS });

  const url = new URL(req.url);
  const rel = restPath(url);
  // Auth is handled here, not proxied: the browser must never be able to read
  // password_hash / password_salt, and PostgREST would happily serve them.
  if (/^\/auth\/?$/.test(rel)) {
    if (req.method !== 'POST') return authReply(405, { ok: false, error: 'Bad request' });
    return handleAuth(req);
  }

  // ── The session gate ──
  // Everything else requires a valid token. 401 carries a stable marker the app
  // recognises to drop back to the sign-in screen.
  const session = await verifyToken(KEY, req.headers.get('x-focus-token'));
  if (!session) return json(401, { error: 'auth', message: 'Sign in required' });
  if (maintenanceBlocks(session.userId)) return json(401, { error: 'auth', reason: 'maintenance', message: 'Off-line for maintenance' });
  // A genuine token is no longer enough on its own: the account must still be
  // active and the session not revoked (password changed/reset, deactivation).
  const live = await sessionLive(session);
  if (live !== 'ok') {
    // Could not reach the row — a transient, NOT a sign-out. 503 lets the client's
    // GET retry absorb it instead of dropping the user to the login screen.
    if (live === 'error') return json(503, { error: 'session_check', message: 'Could not confirm the session — try again' });
    return json(401, { error: 'auth', reason: 'revoked', message: 'Session ended' });
  }

  // Audit attribution is not taken on trust: whenever the claimed actor differs
  // from the person the TOKEN belongs to, the real-actor header is overwritten with
  // the token's person — the audit trail always records who held the session.
  const claimedActor = req.headers.get('x-actor-id') || '';
  const tokenPerson = session.personId == null ? '' : String(session.personId);
  const realActor = (claimedActor && tokenPerson && claimedActor !== tokenPerson)
    ? tokenPerson
    : (req.headers.get('x-real-actor-id') || '');

  // File signing — after the gate, never proxied to PostgREST.
  if (/^\/files\/?$/.test(rel)) return handleFiles(req, url);

  const isSystemUsers = /^\/system_users\b/.test(rel);
  const isAuditLog = /^\/audit_log\b/.test(rel);
  const wantGzip = String(env('SB_GZIP') || '') !== '0' && !isSystemUsers && !isAuditLog;
  const clientInflates = wantGzip && String(req.headers.get('x-focus-gzip') || '') === '1';

  const upstreamHeaders: Record<string, string> = {
    'Content-Type': 'application/json', 'apikey': KEY, 'Authorization': 'Bearer ' + KEY,
    // x-actor-id: the app's current EFFECTIVE user (the one being masqueraded as, if
    // any). x-real-actor-id: the human at the keyboard — server-enforced above. Both
    // are forwarded so the DB audit trigger can read them (sql/add_audit_log.sql).
    'X-Actor-Id': claimedActor || tokenPerson,
    'X-Real-Actor-Id': realActor,
  };
  for (const h of ['prefer', 'range', 'range-unit']) { const v = req.headers.get(h); if (v) upstreamHeaders[h] = v; }
  const reqBody = (req.method === 'GET' || req.method === 'HEAD') ? undefined : new Uint8Array(await req.arrayBuffer());
  const target = `https://${SB}/rest/v1${rel}${url.search}`;

  let up: Response;
  try {
    try { up = await fetch(target, { method: req.method, headers: upstreamHeaders, body: reqBody && reqBody.length ? reqBody : undefined }); }
    catch (e) {
      // A GET may be retried once on a fresh connection; a write whose connection
      // died may still have landed, and retrying it is a duplicate-row machine.
      if (req.method !== 'GET') throw e;
      up = await fetch(target, { method: req.method, headers: upstreamHeaders });
    }
  } catch (e) {
    return json(500, { error: (e && (e as Error).message) || 'Upstream request failed' });
  }

  // A write to system_users may have revoked somebody (Active tick, Reset
  // password): forget every cached verdict so it bites now.
  if (isSystemUsers && req.method !== 'GET') sessionCache.clear();

  const raw = new Uint8Array(await up.arrayBuffer());   // Deno's fetch has already inflated it
  const headers: Record<string, string> = { 'Content-Type': 'application/json', ...CORS };
  const cr = up.headers.get('content-range');
  if (cr) { headers['Content-Range'] = cr; headers['X-Focus-Content-Range'] = cr; }
  // 204 / 205 / 304 (PostgREST's return=minimal writes) may not carry a body at all —
  // the Response constructor throws on one, even empty.
  const nullBody = up.status === 204 || up.status === 205 || up.status === 304;
  const reply = (body: Uint8Array | string, h: Record<string, string>) =>
    new Response(nullBody || !body.length ? null : body, { status: up.status, headers: h });

  if (isSystemUsers || isAuditLog) {
    const text = td.decode(raw);
    return reply(isSystemUsers ? scrubCredentials(text) : scrubAuditCredentials(text), headers);
  }
  if (clientInflates && !nullBody && up.status >= 200 && up.status < 300 && raw.length >= GZIP_MIN_BYTES) {
    try {
      const gz = await gzipBytes(raw);
      return reply(gz, { ...headers, 'Content-Type': 'application/octet-stream', 'X-Focus-Encoding': 'gzip' });
    } catch (_e) { /* fall through to plain */ }
  }
  return reply(raw, headers);
}

if (typeof Deno !== 'undefined' && (Deno as any).serve) {
  (Deno as any).serve((req: Request) => handler(req).catch((e: unknown) =>
    json(500, { error: (e && (e as Error).message) || 'Unhandled error' })));
}
