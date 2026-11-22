// An in-memory stand-in for the Supabase REST gateway, for the proxy's tests and the local
// sign-in server (tests/signin-server.js). It answers what supabase/functions/sb/index.ts asks:
//   • rpc/auth_*          the functions of sql/add_signin_guard.sql, re-stated here in JS, with
//                          the same refusal of any request that lacks the proxy's internal mark;
//   • system_users        reads (plain, or the permissions embed), PATCH with the triggers of
//                          sql/add_session_version.sql (before) / add_signin_guard.sql (after);
//   • user_sessions       the sign-in log;  settings: the environment label;
//   • anything else       an empty list, recorded in db.calls.
// `vault: false` is a database that has not run add_signin_guard.sql: the auth_* functions are
// absent (404 PGRST202) and passwords sit on system_users, as before v7.10.58.
// Keep the rules here in step with the SQL file: this is what the tests judge the proxy against.

function makeFake(opts) {
  opts = opts || {};
  const db = {
    vault: opts.vault !== false,
    environment: opts.environment || 'Test',
    users: [],          // public.system_users
    creds: new Map(),   // focus_auth.credentials, by system_user_id
    devices: [],        // focus_auth.trusted_devices
    config: { code_required: 'false', trust_days: '30' },
    roles: [{ id: 1, name: 'Admin' }, { id: 2, name: 'Sales' }, { id: 3, name: 'User Admin' }, { id: 4, name: 'Settings' }],
    rolePerms: [{ role_id: 3, name: 'manage_system_users' }, { role_id: 4, name: 'manage_settings' }],
    userRoles: [],      // { user_id, role_id }
    overrides: [],      // { user_id, name, granted }
    sessions: [], audit: [], calls: [],
    failNext: 0,        // the next n requests die on the wire
    failEmbed: false,   // the permissions embed answers 400
  };

  db.addUser = function (u, cred) {
    const row = Object.assign({ person_id: null, active: true, must_set_password: false, failed_login_count: 0,
      locked_until: null, session_version: 1, password_set_at: null,
      password_hash: db.vault ? '!vault' : null, password_salt: db.vault ? '!vault' : null }, u);
    db.users.push(row);
    if (cred) {
      if (db.vault) db.creds.set(row.id, Object.assign({ password_hash: null, password_salt: null, temp_expires_at: null,
        totp_secret: null, totp_confirmed_at: null, totp_last_step: null }, cred));
      else Object.assign(row, { password_hash: cred.password_hash, password_salt: cred.password_salt });
    }
    return row;
  };
  const cred = (id) => db.creds.get(id) || {};
  const credFor = (id) => {
    if (!db.creds.has(id)) db.creds.set(id, { password_hash: null, password_salt: null, temp_expires_at: null,
      totp_secret: null, totp_confirmed_at: null, totp_last_step: null });
    return db.creds.get(id);
  };

  // ── the auth_* functions ──
  function authRead(id) {
    const u = db.users.find(x => x.id === id);
    if (!u) return null;
    const c = cred(u.id);
    let days = parseInt(db.config.trust_days, 10);
    days = days >= 0 ? Math.min(365, days) : 30;
    return { id: u.id, person_id: u.person_id, username: u.username, active: u.active,
      must_set_password: u.must_set_password, failed_login_count: u.failed_login_count, locked_until: u.locked_until,
      session_version: u.session_version, password_hash: c.password_hash || null, password_salt: c.password_salt || null,
      temp_expires_at: c.temp_expires_at || null, totp_secret: c.totp_secret || null,
      totp_confirmed_at: c.totp_confirmed_at || null, totp_last_step: c.totp_last_step == null ? null : c.totp_last_step,
      code_required: db.config.code_required === 'true', trust_days: days };
  }
  const rpc = {
    auth_read(a) {
      if (a.p_user_id != null) return authRead(+a.p_user_id);
      const name = String(a.p_username || '').trim().toLowerCase();
      if (!name) return null;
      const u = db.users.filter(x => String(x.username).toLowerCase() === name).sort((x, y) => x.id - y.id)[0];
      return u ? authRead(u.id) : null;
    },
    auth_write(a) {
      const u = db.users.find(x => x.id === +a.p_user_id);
      const p = a.p_patch;
      if (!u || !p) return null;
      const has = (k) => Object.prototype.hasOwnProperty.call(p, k);
      const before = { must_set_password: u.must_set_password, session_version: u.session_version };
      if (has('failed_login_count')) u.failed_login_count = p.failed_login_count == null ? 0 : +p.failed_login_count;
      if (has('locked_until')) u.locked_until = p.locked_until;
      if (has('must_set_password')) u.must_set_password = !!p.must_set_password;
      if (has('password_hash')) u.password_set_at = p.password_hash == null ? null : new Date().toISOString();
      // The explicit bump and the trigger (a forced reset switched on) both give old + 1.
      if (p.bump === true || (!before.must_set_password && u.must_set_password)) u.session_version = (before.session_version || 1) + 1;
      if (['password_hash', 'password_salt', 'temp_expires_at', 'totp_secret', 'totp_confirmed_at', 'totp_last_step'].some(has)) {
        const c = credFor(u.id);
        ['password_hash', 'password_salt', 'temp_expires_at', 'totp_secret', 'totp_confirmed_at', 'totp_last_step']
          .forEach(k => { if (has(k)) c[k] = p[k]; });
      }
      if (p.clear_devices === true) db.devices = db.devices.filter(d => d.system_user_id !== u.id);
      return authRead(u.id);
    },
    auth_totp_step(a) {
      const c = db.creds.get(+a.p_user_id);
      if (!c || !((c.totp_last_step || 0) < +a.p_step)) return false;
      c.totp_last_step = +a.p_step;
      return true;
    },
    auth_device_add(a) {
      const now = Date.now();
      db.devices = db.devices.filter(d => Date.parse(d.expires_at) >= now);
      db.devices.push({ system_user_id: +a.p_user_id, token_hash: a.p_token_hash, expires_at: a.p_expires_at,
        created_at: now + db.devices.length, user_agent: a.p_user_agent || null, last_used_at: null });
      const mine = db.devices.filter(d => d.system_user_id === +a.p_user_id).sort((x, y) => y.created_at - x.created_at);
      const drop = new Set(mine.slice(10));
      db.devices = db.devices.filter(d => !drop.has(d));
      return true;
    },
    auth_device_ok(a) {
      const d = db.devices.find(x => x.system_user_id === +a.p_user_id && x.token_hash === a.p_token_hash
        && Date.parse(x.expires_at) > Date.now());
      if (d) d.last_used_at = new Date().toISOString();
      return !!d;
    },
    auth_admin_list() {
      return db.users.slice().sort((x, y) => x.id - y.id).map(u => {
        const c = cred(u.id);
        return { id: u.id, has_password: !!c.password_hash, must_set_password: u.must_set_password,
          temp_expires_at: c.temp_expires_at || null, enrolled_at: c.totp_confirmed_at || null,
          devices: db.devices.filter(d => d.system_user_id === u.id && Date.parse(d.expires_at) > Date.now()).length,
          locked_until: u.locked_until };
      });
    },
    auth_config_get() { return Object.assign({}, db.config); },
    auth_config_set(a) {
      if (!['code_required', 'trust_days'].includes(a.p_key)) return { __error: [400, { code: 'P0001', message: 'auth: unknown setting ' + a.p_key }] };
      const old = db.config[a.p_key];
      db.config[a.p_key] = a.p_value;
      if (old !== a.p_value) db.audit.push({ actor_id: a.p_actor, table_name: 'settings', row_id: null, op: 'UPDATE',
        changes: { ['signin_' + a.p_key]: { o: old, n: a.p_value } } });
      return Object.assign({}, db.config);
    },
    auth_audit(a) {
      db.audit.push({ actor_id: a.p_actor, table_name: 'system_users', row_id: a.p_user_id, op: 'UPDATE',
        changes: { [a.p_what]: { o: a.p_old, n: a.p_new } } });
      return true;
    },
  };

  // ── system_users through REST ──
  function embedRow(u) {
    return { active: u.active, session_version: u.session_version,
      user_roles: db.userRoles.filter(r => r.user_id === u.id).map(r => {
        const role = db.roles.find(x => x.id === r.role_id) || {};
        return { roles: { name: role.name, role_permissions: db.rolePerms.filter(p => p.role_id === r.role_id).map(p => ({ permissions: { name: p.name } })) } };
      }),
      user_permission_overrides: db.overrides.filter(o => o.user_id === u.id).map(o => ({ granted: o.granted, permissions: { name: o.name } })) };
  }
  function patchUser(u, patch) {
    const before = Object.assign({}, u);
    Object.assign(u, patch);
    if (db.vault) {
      // add_signin_guard.sql: the two old columns always hold the marker; the version moves on
      // deactivation and on a forced reset being switched on.
      u.password_hash = '!vault'; u.password_salt = '!vault';
      if ((before.active !== false && u.active === false) || (!before.must_set_password && u.must_set_password === true)) {
        u.session_version = (before.session_version || 1) + 1;
      }
    } else if ((before.active !== false && u.active === false) || u.password_hash !== before.password_hash
        || (!before.must_set_password && u.must_set_password === true)) {
      u.session_version = (before.session_version || 1) + 1;   // add_session_version.sql
    }
  }

  const reply = (status, body) => new Response(body == null ? 'null' : (typeof body === 'string' ? body : JSON.stringify(body)),
    { status, headers: { 'Content-Type': 'application/json' } });

  async function fetchStub(input, init) {
    init = init || {};
    const url = new URL(typeof input === 'string' ? input : input.url);
    const method = String(init.method || 'GET').toUpperCase();
    const headers = {};
    Object.keys(init.headers || {}).forEach(k => { headers[k.toLowerCase()] = String(init.headers[k]); });
    let bodyText = '';
    if (init.body != null) bodyText = typeof init.body === 'string' ? init.body : new TextDecoder().decode(init.body);
    const path = url.pathname.replace(/^\/rest\/v1/, '');
    db.calls.push({ method, path, search: url.search, headers, body: bodyText });
    if (db.failNext > 0) { db.failNext--; throw new TypeError('fetch failed'); }

    const m = /^\/rpc\/([a-z_0-9]+)$/.exec(path);
    if (m && /^auth_/.test(m[1])) {
      if (!db.vault || !rpc[m[1]]) return reply(404, { code: 'PGRST202', message: 'Could not find the function public.' + m[1] + ' in the schema cache' });
      // focus_auth.guard(): the proxy's own mark, and never the mark of a forwarded request.
      if (headers['x-focus-internal'] !== 'auth' || 'x-focus-client' in headers) return reply(403, { code: '42501', message: 'auth: not allowed' });
      const out = rpc[m[1]](bodyText ? JSON.parse(bodyText) : {});
      if (out && out.__error) return reply(out.__error[0], out.__error[1]);
      return reply(200, out);
    }

    const q = url.searchParams;
    if (path === '/system_users') {
      const idm = /^eq\.(\d+)$/.exec(q.get('id') || '');
      const um = /^ilike\.(.+)$/.exec(q.get('username') || '');
      const rows = db.users.filter(u => idm ? u.id === +idm[1] : um ? String(u.username).toLowerCase() === um[1].toLowerCase() : true);
      if (method === 'PATCH') rows.forEach(u => patchUser(u, JSON.parse(bodyText || '{}')));
      const select = q.get('select') || '*';
      if (/user_roles\(/.test(select)) {
        if (db.failEmbed) return reply(400, { code: 'PGRST200', message: 'Could not find a relationship' });
        return reply(200, rows.map(embedRow));
      }
      const cols = select.split(',');
      return reply(200, rows.map(u => cols[0] === '*' ? Object.assign({}, u) : Object.fromEntries(cols.map(c => [c, u[c]]))));
    }
    if (path === '/user_sessions' && method === 'POST') {
      const row = JSON.parse(bodyText || '{}');
      if ('method' in row && !db.vault) return reply(400, { code: 'PGRST204', message: "Could not find the 'method' column" });
      row.id = db.sessions.length + 1;
      db.sessions.push(row);
      return reply(201, [{ id: row.id }]);
    }
    if (path === '/settings') return reply(200, [{ value: db.environment }]);
    if (method === 'GET') return reply(200, []);
    return reply(method === 'POST' ? 201 : 200, []);
  }

  return { db, fetch: fetchStub };
}

module.exports = { makeFake };
