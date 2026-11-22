// Focus API proxy as a Supabase Edge Function (v7.10.21).
//
// A port of netlify/functions/sb.js with the SAME wire contract — routes, headers,
// session tokens, error bodies — so index.html, time.html and Focus.html only had to
// change the base path. Why it exists: every Focus call used to travel browser (SA)
// → Netlify Lambda (AWS us-east-1) → Supabase (eu-west-1) → back, two Atlantic
// crossings per request (~600 ms of pure network for an 18 ms query). Running the
// proxy here, pinned to the database's own region by the `x-region` header on the
// Netlify rewrite (netlify.toml), removes the second crossing. The Netlify function
// stayed deployed as the rollback until v7.10.58, when it was retired: a second proxy
// without the sign-in guard below would be a way round it.
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

// ── Authenticator code (v7.10.58) ────────────────────────────────────────────
// The regular sign-in's second step: a time-based one-time code (RFC 6238 — HMAC-SHA1,
// 6 digits, a new code every 30 seconds), which is what Microsoft Authenticator and
// every other code-generator app produce. The code for the step either side of now is
// accepted too (a phone's clock drifts); a step already used is refused by the
// database (auth_totp_step), so a code works once.
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
export function base32Encode(bytes: Uint8Array): string {
  let bits = 0, value = 0, out = '';
  for (let i = 0; i < bytes.length; i++) {
    value = (value << 8) | bytes[i]; bits += 8;
    while (bits >= 5) { out += B32[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}
export function base32Decode(s: unknown): Uint8Array | null {
  const str = String(s == null ? '' : s).replace(/[\s=-]+/g, '').toUpperCase();
  if (!str || /[^A-Z2-7]/.test(str)) return null;
  const out: number[] = [];
  let bits = 0, value = 0;
  for (let i = 0; i < str.length; i++) {
    value = ((value << 5) | B32.indexOf(str[i])) & 0xfff; bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; }
  }
  return new Uint8Array(out);
}
const TOTP_STEP_S = 30, TOTP_DIGITS = 6, TOTP_WINDOW = 1;
export async function totpAt(secret: Uint8Array, step: number): Promise<string> {
  const msg = new Uint8Array(8);
  let s = step;
  for (let i = 7; i >= 0; i--) { msg[i] = s % 256; s = Math.floor(s / 256); }
  const k = await crypto.subtle.importKey('raw', secret, { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  const h = new Uint8Array(await crypto.subtle.sign('HMAC', k, msg));
  const o = h[h.length - 1] & 0x0f;
  const bin = ((h[o] & 0x7f) * 0x1000000) + (h[o + 1] << 16) + (h[o + 2] << 8) + h[o + 3];
  return String(bin % 10 ** TOTP_DIGITS).padStart(TOTP_DIGITS, '0');
}
// The step whose code this is, or null. Every candidate is computed and compared, so
// the time taken says nothing about which one matched.
export async function totpMatch(secret: Uint8Array, code: unknown, nowMs: number): Promise<number | null> {
  const typed = String(code == null ? '' : code).replace(/\s+/g, '');
  if (!/^\d{6}$/.test(typed)) return null;
  const now = Math.floor(nowMs / 1000 / TOTP_STEP_S);
  let hit: number | null = null;
  for (let d = -TOTP_WINDOW; d <= TOTP_WINDOW; d++) {
    const want = await totpAt(secret, now + d);
    if (timingSafeEqual(te.encode(want), te.encode(typed)) && hit == null) hit = now + d;
  }
  return hit;
}

const bytesToB64url = (bytes: Uint8Array): string =>
  bytesToB64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const b64urlToBytes = (s: string): Uint8Array => {
  let t = String(s).replace(/-/g, '+').replace(/_/g, '/');
  while (t.length % 4) t += '=';
  return b64ToBytes(t);
};
export async function sha256Hex(s: string): Promise<string> {
  return hex(await crypto.subtle.digest('SHA-256', te.encode(s)));
}

// The Authenticator secret is stored encrypted (AES-256-GCM, bound to the login it
// belongs to). The key is derived from the service key, like the session key, so
// there is nothing extra to provision and a copy of the table alone gives no codes.
let _totpKey: Promise<CryptoKey> | null = null;
function totpKey(): Promise<CryptoKey> {
  if (!_totpKey) {
    _totpKey = hmacSha256(te.encode(String(KEY)), 'focus-totp-v1')
      .then(raw => crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']));
  }
  return _totpKey;
}
export async function sealSecret(userId: number, secret: Uint8Array): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: te.encode('u' + userId) }, await totpKey(), secret));
  return 'v1.' + bytesToB64url(iv) + '.' + bytesToB64url(ct);
}
export async function openSecret(userId: number, sealed: unknown): Promise<Uint8Array | null> {
  try {
    const parts = String(sealed || '').split('.');
    if (parts.length !== 3 || parts[0] !== 'v1') return null;
    const pt = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: b64urlToBytes(parts[1]), additionalData: te.encode('u' + userId) },
      await totpKey(), b64urlToBytes(parts[2]));
    return new Uint8Array(pt);
  } catch (_e) { return null; }
}

// A one-time password an admin hands over: three groups of four, no look-alike
// characters, always meeting the policy (the hyphen is its special character).
const OTP_UPPER = 'ABCDEFGHJKLMNPQRSTUVWXYZ', OTP_LOWER = 'abcdefghijkmnpqrstuvwxyz', OTP_DIGIT = '23456789';
function randomPick(alphabet: string): string {
  const limit = 256 - (256 % alphabet.length);
  const b = new Uint8Array(1);
  do { crypto.getRandomValues(b); } while (b[0] >= limit);
  return alphabet[b[0] % alphabet.length];
}
export function oneTimePassword(): string {
  const all = OTP_UPPER + OTP_LOWER + OTP_DIGIT;
  for (;;) {
    let s = '';
    for (let i = 0; i < 12; i++) s += randomPick(all);
    if (/[A-Z]/.test(s) && /[a-z]/.test(s) && /[0-9]/.test(s)) return s.slice(0, 4) + '-' + s.slice(4, 8) + '-' + s.slice(8);
  }
}
const TEMP_PASSWORD_DAYS = 7;

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
// v7.10.58: the same read also brings the login's permissions (the embed index.html's
// buildUserContext uses), so the proxy can refuse a write to the access tables that
// the login may not make. perms is null when only the plain row could be read.
type SessionEntry = { active: boolean; version: number; perms: string[] | null; admin: boolean; at: number };
const sessionCache = new Map<number, SessionEntry>();
const SESSION_EMBED = 'active,session_version,'
  + 'user_roles(roles(name,role_permissions(permissions(name)))),'
  + 'user_permission_overrides(granted,permissions(name))';

// Roles' permissions, then the per-user overrides: granted TRUE adds, FALSE removes.
export function permsOf(row: any): { perms: string[]; admin: boolean } {
  let perms: string[] = [];
  let admin = false;
  (row.user_roles || []).forEach((ur: any) => {
    const r = ur && ur.roles; if (!r) return;
    if (r.name === 'Admin') admin = true;
    (r.role_permissions || []).forEach((rp: any) => {
      const nm = rp && rp.permissions && rp.permissions.name;
      if (nm && !perms.includes(nm)) perms.push(nm);
    });
  });
  (row.user_permission_overrides || []).forEach((o: any) => {
    const nm = o && o.permissions && o.permissions.name; if (!nm) return;
    if (o.granted) { if (!perms.includes(nm)) perms.push(nm); }
    else perms = perms.filter(x => x !== nm);
  });
  return { perms, admin };
}

async function sessionEntry(userId: number): Promise<SessionEntry | null> {
  const now = Date.now();
  let entry = sessionCache.get(userId);
  if (!entry || now - entry.at > SESSION_CHECK_MS) {
    let row: any = null, withPerms = true;
    try {
      const rows = await sbRest('GET', `/system_users?id=eq.${userId}&select=${SESSION_EMBED}`);
      row = rows && rows[0];
    } catch (_e) {
      // The embed could not be read (a relationship PostgREST cannot resolve): the
      // session check must still work, so fall back to the plain row.
      withPerms = false;
      try {
        const rows = await sbRest('GET', `/system_users?id=eq.${userId}&select=active,session_version`);
        row = rows && rows[0];
      } catch (_e2) { return null; }
    }
    const p = row && withPerms ? permsOf(row) : null;
    entry = { active: !!row && row.active !== false, version: row ? +row.session_version : -1,
              perms: p ? p.perms : null, admin: !!(p && p.admin), at: now };
    sessionCache.set(userId, entry);
  }
  return entry;
}

async function sessionLive(session: Session): Promise<'ok' | 'revoked' | 'error'> {
  const entry = await sessionEntry(session.userId);
  if (!entry) return 'error';
  return (entry.active && entry.version === session.version) ? 'ok' : 'revoked';
}

// May this session's login do what the permission names? The rule is index.html's
// can(): the Admin role, or the 'all' permission, or the permission itself.
// null = the permissions could not be read just now.
async function sessionCan(session: Session, permission: string): Promise<boolean | null> {
  const entry = await sessionEntry(session.userId);
  if (!entry || entry.perms == null) return null;
  return entry.admin || entry.perms.includes('all') || entry.perms.includes(permission);
}

// A valid, live session from the request's token, or null.
async function requestSession(req: Request): Promise<Session | null> {
  const session = await verifyToken(KEY, req.headers.get('x-focus-token'));
  if (!session) return null;
  return (await sessionLive(session)) === 'ok' ? session : null;
}

// ── The sign-in store (v7.10.58) ─────────────────────────────────────────────
// Password hashes, Authenticator secrets, trusted devices and the sign-in policy live
// in schema focus_auth, which PostgREST does not serve, behind the auth_* functions
// (sql/add_signin_guard.sql). Those functions answer only a request carrying
// X-Focus-Internal, which this proxy adds to its OWN calls here and to nothing it
// forwards for a browser. VaultMissing = the database has not run that file yet
// (PGRST202): the caller falls back to the old columns on system_users.
class VaultMissing extends Error {}
async function authRpc(name: string, args: Record<string, unknown>, actor?: number | null): Promise<any> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json', 'apikey': KEY, 'Authorization': 'Bearer ' + KEY, 'X-Focus-Internal': 'auth',
  };
  if (actor) { headers['X-Actor-Id'] = String(actor); headers['X-Real-Actor-Id'] = String(actor); }
  const res = await fetch(`https://${SB}/rest/v1/rpc/${name}`, { method: 'POST', headers, body: JSON.stringify(args || {}) });
  const d = await res.text();
  if (res.status === 404) {
    let code = '';
    try { code = (JSON.parse(d) || {}).code || ''; } catch (_e) { /* not PostgREST's body */ }
    if (code === 'PGRST202') throw new VaultMissing('sign-in store not installed');
  }
  if (res.status >= 400) throw new Error(`HTTP ${res.status}: ${d.slice(0, 200)}`);
  return d ? JSON.parse(d) : null;
}
const NOT_INSTALLED = { ok: false, notInstalled: true, error: 'This database has not had the sign-in upgrade yet (sql/add_signin_guard.sql)' };

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
// method (v7.10.58) says how: 'password', 'password+code', 'password+device', and on a
// refused attempt which step failed ('password' or 'code'). Sent only by the sign-in
// path that knows the column exists (it arrives with sql/add_signin_guard.sql).
async function logSignIn(req: Request, user: any, outcome: string, method?: string): Promise<number | null> {
  try {
    const row: Record<string, unknown> = {
      system_user_id: +user.id, person_id: user.person_id == null ? null : +user.person_id, outcome,
      user_agent: String(req.headers.get('user-agent') || '').slice(0, 400) || null, ip: clientIp(req),
    };
    if (method) row.method = method;
    const rows = await sbRest('POST', '/user_sessions', row);
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
// POST /auth — sign-in, never proxied to PostgREST.
//   Before a session exists:
//   { action: 'env' }                                     -> the environment label
//   { action: 'check', username }                         -> may this account still choose a password unverified?
//   { action: 'login', username, password [, code] [, device] [, trust] }
//                                                         -> a session token; or needCode / enrol / mustSet
//   { action: 'set',   username|userId, password, newPassword }
//                                                         -> choose or change a password
//   { action: 'totp-begin',   username, password }        -> a new Authenticator secret to scan
//   { action: 'totp-confirm', username, password, code [, trust] }
//                                                         -> confirms it and signs in
//   With a session (X-Focus-Token), checked HERE against the login's permissions:
//   { action: 'admin-list' }                              -> each login's sign-in state   (manage_system_users)
//   { action: 'admin-reset-password', targetUserId }      -> a one-time password, shown once
//   { action: 'admin-reset-authenticator', targetUserId } -> the user enrols again
//   { action: 'policy-get' } / { action: 'policy-set', codeRequired, trustDays }   (manage_settings)
// Sign-in is by TYPED username (= first name, case-insensitive); nothing pre-login
// enumerates accounts. Never returns a hash, a salt, or any hint about which half
// of a wrong pair was wrong.
//
// Two stores (v7.10.58). Where sql/add_signin_guard.sql has run, credentials come from
// the auth_* functions and the rules are the new ones (handleAuthVault): no account
// may be claimed from the login screen, and the Authenticator code applies when the
// policy says so. Where it has not, handleAuthLegacy is the previous behaviour on the
// old columns, unchanged.
// MAINTENANCE MODE: while MAINTENANCE_ON is true, Focus is on-line for the system_users
// ids in MAINTENANCE_ALLOW only (4 = Richard, 12 = Lesley-Anne); everyone else is turned
// away at sign-in and on every proxied call, and the client sends them to /maintenance.html.
// Switched on 2026-10-07; switched OFF 2026-11-05 on Richard's "take away maintenance
// screen for everyone" (v7.10.27). Flip it and redeploy this function (prod AND test).
const MAINTENANCE_ON = false;
const MAINTENANCE_ALLOW = [4, 12];
const maintenanceBlocks = (userId: unknown) => MAINTENANCE_ON && !MAINTENANCE_ALLOW.includes(+(userId as any));

const LOCK_MSG = 'Too many failed attempts — try again in a few minutes';
const ADMIN_ACTIONS: Record<string, string> = {
  'admin-list': 'manage_system_users', 'admin-reset-password': 'manage_system_users',
  'admin-reset-authenticator': 'manage_system_users',
  'policy-get': 'manage_settings', 'policy-set': 'manage_settings',
};

async function handleAuth(req: Request): Promise<Response> {
  let body: any;
  try { body = JSON.parse((await req.text()) || '{}'); } catch (_e) { return authReply(400, { ok: false, error: 'Bad request' }); }
  if (!body || typeof body !== 'object') return authReply(400, { ok: false, error: 'Bad request' });

  // The one pre-login lookup the login screen still needs.
  if (body.action === 'env') {
    try {
      const rows = await sbRest('GET', '/settings?key=eq.environment&select=value');
      return authReply(200, { ok: true, environment: (rows && rows[0] && rows[0].value) || '' });
    } catch (_e) { return authReply(200, { ok: true, environment: '' }); }
  }

  if (ADMIN_ACTIONS[body.action]) return handleAuthAdmin(req, body);

  const uname = String(body.username || '').trim();
  const byId = uname ? 0 : parseInt(body.userId, 10);
  if (uname.length > 80 || (!uname && !byId)) return authReply(400, { ok: false, error: 'Bad request' });

  let user: any, vault = true;
  try {
    user = await authRpc('auth_read', { p_username: uname || null, p_user_id: uname ? null : byId });
  } catch (e) {
    if (!(e instanceof VaultMissing)) return authReply(500, { ok: false, error: 'Sign-in is unavailable right now' });
    vault = false;
    const SELECT = 'select=id,person_id,active,password_hash,password_salt,must_set_password,failed_login_count,locked_until,session_version';
    try {
      // ilike without wildcards = case-insensitive equality.
      const rows = uname
        ? await sbRest('GET', `/system_users?username=ilike.${encodeURIComponent(uname)}&${SELECT}`)
        : await sbRest('GET', `/system_users?id=eq.${byId}&${SELECT}`);
      user = rows && rows[0];
    } catch (_e) { return authReply(500, { ok: false, error: 'Sign-in is unavailable right now' }); }
  }

  if (!user || user.active === false) return authReply(200, { ok: false, error: 'Sign-in failed' });
  if (body.action !== 'check' && maintenanceBlocks(user.id)) return authReply(200, { ok: false, maintenance: true, error: 'Focus is off-line for maintenance' });
  return vault ? handleAuthVault(req, body, user, uname) : handleAuthLegacy(req, body, user);
}

// ── Sign-in on the new store ─────────────────────────────────────────────────
async function handleAuthVault(req: Request, body: any, user: any, uname: string): Promise<Response> {
  const userId = +user.id;
  const action = String(body.action || '');
  // Nothing may be chosen unverified any more, so the login card never opens the
  // set panel on a bare username.
  if (action === 'check') return authReply(200, { ok: true, mustSet: false });
  if (!['login', 'set', 'totp-begin', 'totp-confirm'].includes(action)) return authReply(400, { ok: false, error: 'Bad request' });

  const write = (patch: Record<string, unknown>) => authRpc('auth_write', { p_user_id: userId, p_patch: patch });
  const unavailable = () => authReply(500, { ok: false, error: 'Sign-in is unavailable right now' });
  const codeRequired = !!user.code_required;
  const trustDays = Math.max(0, Math.min(365, +user.trust_days || 0));
  const enrolled = !!user.totp_secret && !!user.totp_confirmed_at;

  // Account lock: MAX_LOGIN_FAILURES wrong passwords OR wrong codes lock the account
  // for LOCK_MINUTES; any completed sign-in clears the slate.
  const locked = user.locked_until && Date.parse(user.locked_until) > Date.now();
  const registerFailure = async (step: string) => {
    const fails = (+user.failed_login_count || 0) + 1;
    const lockNow = fails >= MAX_LOGIN_FAILURES;
    try {
      await write(lockNow
        ? { failed_login_count: 0, locked_until: new Date(Date.now() + LOCK_MINUTES * 60000).toISOString() }
        : { failed_login_count: fails });
    } catch (_e) { /* best effort */ }
    await logSignIn(req, user, lockNow ? 'locked' : 'failed', step);
  };
  const clearFailures = async () => {
    if (!(+user.failed_login_count || 0) && !user.locked_until) return;
    try { await write({ failed_login_count: 0, locked_until: null }); } catch (_e) { /* best effort */ }
  };

  if (locked) {
    if (action === 'login') await logSignIn(req, user, 'locked', 'password');
    return authReply(200, { ok: false, error: LOCK_MSG });
  }

  // Every action here starts by proving the password.
  if (!(await passwordMatches(String(body.password || ''), user.password_salt, user.password_hash))) {
    await registerFailure('password');
    return authReply(200, { ok: false, error: action === 'set' ? 'Current password is incorrect' : 'Sign-in failed' });
  }
  const mustSet = !!user.must_set_password;
  if (mustSet && user.temp_expires_at && Date.parse(user.temp_expires_at) < Date.now()) {
    return authReply(200, { ok: false, error: 'That one-time password has expired — ask an administrator for a new one' });
  }

  // A trusted-device token for this sign-in, when asked for and allowed.
  const trustDevice = async (): Promise<string | null> => {
    if (!body.trust || !(trustDays > 0)) return null;
    const token = bytesToB64url(crypto.getRandomValues(new Uint8Array(32)));
    try {
      await authRpc('auth_device_add', {
        p_user_id: userId, p_token_hash: await sha256Hex(token),
        p_expires_at: new Date(Date.now() + trustDays * 86400000).toISOString(),
        p_user_agent: String(req.headers.get('user-agent') || '').slice(0, 400) || null,
      });
      return token;
    } catch (_e) { return null; }   // the sign-in stands; the device is simply not remembered
  };
  const signedIn = async (method: string, version: unknown, device: string | null) => {
    await clearFailures();
    const sessionId = await logSignIn(req, user, 'ok', method);
    const out: Record<string, unknown> = {
      ok: true, token: await issueToken(KEY, userId, user.person_id, version), userId, personId: user.person_id, sessionId };
    if (device) { out.device = device; out.trustDays = trustDays; }
    return authReply(200, out);
  };

  if (action === 'set') {
    const next = String(body.newPassword || '');
    const policyError = passwordPolicyError(next);
    if (policyError) return authReply(200, { ok: false, error: policyError });
    if (next === String(body.password || '')) return authReply(200, { ok: false, error: 'Choose a password different from the current one' });
    const salt = hex(crypto.getRandomValues(new Uint8Array(16)));
    let after: any;
    try {
      after = await write({
        password_hash: await hashPassword(next, salt), password_salt: salt, temp_expires_at: null,
        must_set_password: false, failed_login_count: 0, locked_until: null,
        bump: true,            // every other session this login held ends here
        clear_devices: true,   // and every trusted device is forgotten
      });
    } catch (_e) { return authReply(500, { ok: false, error: 'Could not save the password' }); }
    sessionCache.delete(userId);
    const fresh = after && after.session_version != null ? +after.session_version : (+user.session_version || 1) + 1;
    // A change made from inside the app keeps its session: the caller holds a live
    // session for this same login, which already passed the code.
    const live = await verifyToken(KEY, req.headers.get('x-focus-token'));
    const inApp = !!live && live.userId === userId && live.version === +user.session_version;
    if (inApp) return authReply(200, { ok: true, set: true, token: await issueToken(KEY, userId, user.person_id, fresh), userId, personId: user.person_id, sessionId: null });
    // From the login screen, a password alone is a sign-in only where no code is
    // required. Otherwise the card signs in with the new password, which asks for it.
    if (codeRequired) return authReply(200, { ok: true, set: true });
    const sessionId = uname ? await logSignIn(req, user, 'ok', 'password') : null;
    return authReply(200, { ok: true, set: true, token: await issueToken(KEY, userId, user.person_id, fresh), userId, personId: user.person_id, sessionId });
  }

  if (mustSet) {
    // A one-time (or pre-reset) password verified: now they choose their own.
    await clearFailures();
    return authReply(200, { ok: false, mustSet: true, error: 'Choose your own password to continue' });
  }

  if (action === 'totp-begin') {
    if (!codeRequired) return authReply(200, { ok: false, error: 'An authenticator code is not required for Focus at present' });
    if (enrolled) return authReply(200, { ok: false, error: 'An authenticator is already set up for this login — ask an administrator to reset it' });
    const secret = crypto.getRandomValues(new Uint8Array(20));
    try { await write({ totp_secret: await sealSecret(userId, secret), totp_confirmed_at: null, totp_last_step: null }); }
    catch (_e) { return unavailable(); }
    let envName = '';
    try {
      const rows = await sbRest('GET', '/settings?key=eq.environment&select=value');
      envName = String((rows && rows[0] && rows[0].value) || '');
    } catch (_e) { /* the label is cosmetic */ }
    // The name the app lists the account under. Anything but production says so, so a
    // person holding both does not read the wrong one.
    const issuer = !envName || /^prod/i.test(envName) ? 'Focus' : 'Focus ' + envName.replace(/[^A-Za-z0-9 ]/g, '').trim();
    const account = String(user.username || uname || 'user');
    const b32 = base32Encode(secret);
    const uri = 'otpauth://totp/' + encodeURIComponent(issuer) + ':' + encodeURIComponent(account)
      + '?secret=' + b32 + '&issuer=' + encodeURIComponent(issuer) + '&algorithm=SHA1&digits=6&period=30';
    return authReply(200, { ok: true, secret: b32, uri, issuer, account, trustDays });
  }

  if (action === 'totp-confirm') {
    if (!codeRequired) return authReply(200, { ok: false, error: 'An authenticator code is not required for Focus at present' });
    if (enrolled || !user.totp_secret) return authReply(200, { ok: false, restart: true, error: 'Start the set-up again' });
    const secret = await openSecret(userId, user.totp_secret);
    if (!secret) return authReply(200, { ok: false, restart: true, error: 'Start the set-up again' });
    const step = await totpMatch(secret, body.code, Date.now());
    if (step == null) {
      await registerFailure('code');
      return authReply(200, { ok: false, badCode: true, error: 'That code is not right. Check the authenticator app and try again' });
    }
    let after: any;
    try { after = await write({ totp_confirmed_at: new Date().toISOString(), totp_last_step: step }); }
    catch (_e) { return unavailable(); }
    return signedIn('password+code', after && after.session_version != null ? after.session_version : user.session_version, await trustDevice());
  }

  // action === 'login'
  if (!codeRequired) return signedIn('password', user.session_version, null);
  if (!enrolled) {
    await clearFailures();
    return authReply(200, { ok: false, enrol: true, trustDays, error: 'Set up your authenticator app to continue' });
  }
  // A device this login chose to trust skips the code until its token lapses.
  if (body.device && trustDays > 0) {
    let known = false;
    try { known = !!(await authRpc('auth_device_ok', { p_user_id: userId, p_token_hash: await sha256Hex(String(body.device).slice(0, 200)) })); }
    catch (_e) { known = false; }
    if (known) return signedIn('password+device', user.session_version, null);
  }
  const typed = String(body.code == null ? '' : body.code).replace(/\s+/g, '');
  if (!typed) return authReply(200, { ok: false, needCode: true, trustDays, error: 'Enter the 6-digit code from your authenticator app' });
  const secret = await openSecret(userId, user.totp_secret);
  if (!secret) return unavailable();
  const step = await totpMatch(secret, typed, Date.now());
  if (step == null) {
    await registerFailure('code');
    return authReply(200, { ok: false, needCode: true, badCode: true, trustDays, error: 'That code is not right. Check the authenticator app and try again' });
  }
  let firstUse = false;
  try { firstUse = !!(await authRpc('auth_totp_step', { p_user_id: userId, p_step: step })); }
  catch (_e) { return unavailable(); }
  if (!firstUse) return authReply(200, { ok: false, needCode: true, badCode: true, trustDays, error: 'That code has already been used. Wait for the next one' });
  return signedIn('password+code', user.session_version, await trustDevice());
}

// ── Sign-in administration, checked on the server ────────────────────────────
async function handleAuthAdmin(req: Request, body: any): Promise<Response> {
  const session = await requestSession(req);
  if (!session) return json(401, { error: 'auth', message: 'Sign in required' });
  if (maintenanceBlocks(session.userId)) return json(401, { error: 'auth', reason: 'maintenance', message: 'Off-line for maintenance' });
  const allowed = await sessionCan(session, ADMIN_ACTIONS[body.action]);
  if (allowed == null) return authReply(503, { ok: false, error: 'Could not confirm your permissions — try again' });
  if (!allowed) return authReply(403, { ok: false, error: 'You do not have permission to do that' });
  const actor = session.personId;

  try {
    if (body.action === 'admin-list') {
      return authReply(200, { ok: true, users: (await authRpc('auth_admin_list', {})) || [] });
    }

    if (body.action === 'policy-get' || body.action === 'policy-set') {
      if (body.action === 'policy-set') {
        if (typeof body.codeRequired === 'boolean') {
          await authRpc('auth_config_set', { p_key: 'code_required', p_value: body.codeRequired ? 'true' : 'false', p_actor: actor });
        }
        if (body.trustDays != null) {
          const days = Math.round(Number(body.trustDays));
          if (!(days >= 0 && days <= 365)) return authReply(200, { ok: false, error: 'Trusted days must be between 0 and 365' });
          await authRpc('auth_config_set', { p_key: 'trust_days', p_value: String(days), p_actor: actor });
        }
      }
      const cfg = (await authRpc('auth_config_get', {})) || {};
      const days = parseInt(cfg.trust_days, 10);
      return authReply(200, { ok: true, codeRequired: cfg.code_required === 'true', trustDays: days >= 0 ? Math.min(365, days) : 30 });
    }

    const targetId = parseInt(body.targetUserId, 10);
    if (!targetId) return authReply(400, { ok: false, error: 'Bad request' });
    const target = await authRpc('auth_read', { p_username: null, p_user_id: targetId });
    if (!target) return authReply(200, { ok: false, error: 'User not found' });

    if (body.action === 'admin-reset-password') {
      // The admin hands this over; it works once, for TEMP_PASSWORD_DAYS, and the
      // user must choose their own before anything else. The old password, every
      // session and every trusted device stop here.
      const password = oneTimePassword();
      const salt = hex(crypto.getRandomValues(new Uint8Array(16)));
      await authRpc('auth_write', { p_user_id: targetId, p_patch: {
        password_hash: await hashPassword(password, salt), password_salt: salt,
        temp_expires_at: new Date(Date.now() + TEMP_PASSWORD_DAYS * 86400000).toISOString(),
        must_set_password: true, failed_login_count: 0, locked_until: null, bump: true, clear_devices: true,
      } }, actor);
      await authRpc('auth_audit', { p_actor: actor, p_user_id: targetId, p_what: 'password',
        p_old: target.password_hash ? 'set' : 'none', p_new: 'one-time password issued' }).catch(() => null);
      sessionCache.delete(targetId);
      return authReply(200, { ok: true, password, days: TEMP_PASSWORD_DAYS });
    }

    if (body.action === 'admin-reset-authenticator') {
      await authRpc('auth_write', { p_user_id: targetId, p_patch: {
        totp_secret: null, totp_confirmed_at: null, totp_last_step: null, bump: true, clear_devices: true,
      } }, actor);
      await authRpc('auth_audit', { p_actor: actor, p_user_id: targetId, p_what: 'authenticator',
        p_old: target.totp_confirmed_at ? 'enrolled' : 'none', p_new: 'reset' }).catch(() => null);
      sessionCache.delete(targetId);
      return authReply(200, { ok: true });
    }
  } catch (e) {
    if (e instanceof VaultMissing) return authReply(200, NOT_INSTALLED);
    return authReply(500, { ok: false, error: 'Sign-in settings are unavailable right now' });
  }
  return authReply(400, { ok: false, error: 'Bad request' });
}

// ── Sign-in on the old columns (a database without sql/add_signin_guard.sql) ──
// The behaviour before v7.10.58, kept whole so the proxy can be deployed ahead of the
// SQL. Once that file has run, the columns read here hold a marker that matches no
// password, so this path signs nobody in.
async function handleAuthLegacy(req: Request, body: any, user: any): Promise<Response> {
  const userId = +user.id;
  if (['totp-begin', 'totp-confirm'].includes(body.action)) return authReply(200, NOT_INSTALLED);
  const hasPw = !!user.password_hash;
  const mustSet = !!user.must_set_password || !hasPw;

  // Account lock: MAX_LOGIN_FAILURES wrong passwords lock the account for
  // LOCK_MINUTES. Counted on login AND on a wrong current-password in 'set'
  // (both are guessing surfaces); any successful verify clears the slate.
  const locked = user.locked_until && Date.parse(user.locked_until) > Date.now();
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

// Writes to these tables decide who may sign in and what a login may do. The value is
// the permission that guards the admin page each belongs to (MENU in index.html).
const GUARDED_TABLES: Record<string, string> = {
  system_users: 'manage_system_users', user_roles: 'manage_system_users',
  system_user_regions: 'manage_system_users', system_user_branches: 'manage_system_users',
  user_permission_overrides: 'manage_system_users',
  roles: 'manage_roles', role_permissions: 'manage_roles',
  permissions: 'manage_permissions',
};

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

  // ── What a browser may ask PostgREST for (v7.10.58) ──
  // A table, or rpc/<function>, spelled plainly: a path that needs decoding is refused
  // outright, so no encoding can slip a name past the two rules below.
  const shape = /^\/([A-Za-z0-9_]+)(?:\/([A-Za-z0-9_]+))?\/?$/.exec(rel);
  if (!shape || (shape[1] === 'rpc') !== !!shape[2]) return json(404, { error: 'path', message: 'Not found' });
  const resource = shape[1], fn = shape[2] || '';
  // The sign-in functions belong to this proxy alone (authRpc). No browser calls them.
  if (resource === 'rpc' && /^auth_/i.test(fn)) return json(403, { error: 'forbidden', message: 'Not allowed' });
  // The access tables: reading stays open (the app builds a login's rights from them),
  // but a write needs the permission that guards the page it belongs to, checked HERE.
  const guardPerm = GUARDED_TABLES[resource] || '';
  const isWrite = req.method !== 'GET' && req.method !== 'HEAD';
  if (guardPerm && isWrite) {
    const may = await sessionCan(session, guardPerm);
    if (may == null) return json(503, { error: 'permission_check', message: 'Could not confirm your permissions — try again' });
    if (!may) return json(403, { error: 'forbidden', message: 'You do not have permission to change that' });
  }

  const isSystemUsers = resource === 'system_users';
  const isAuditLog = resource === 'audit_log';
  const wantGzip = String(env('SB_GZIP') || '') !== '0' && !isSystemUsers && !isAuditLog;
  const clientInflates = wantGzip && String(req.headers.get('x-focus-gzip') || '') === '1';

  const upstreamHeaders: Record<string, string> = {
    'Content-Type': 'application/json', 'apikey': KEY, 'Authorization': 'Bearer ' + KEY,
    // x-actor-id: the app's current EFFECTIVE user (the one being masqueraded as, if
    // any). x-real-actor-id: the human at the keyboard — server-enforced above. Both
    // are forwarded so the DB audit trigger can read them (sql/add_audit_log.sql).
    'X-Actor-Id': claimedActor || tokenPerson,
    'X-Real-Actor-Id': realActor,
    // Everything forwarded for a browser says so. The auth_* functions refuse a request
    // carrying this mark, whatever path it arrived by.
    'X-Focus-Client': '1',
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

  // A write to an access table may have revoked somebody (Active tick) or changed
  // what a login may do (a role, a permission): forget every cached verdict so it
  // bites now.
  if (guardPerm && isWrite) sessionCache.clear();

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
