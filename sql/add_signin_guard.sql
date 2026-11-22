-- Sign-in guard and Authenticator code (Focus v7.10.58, Richard 2026-11-22: "go with
-- recommendations, start phase 1"). Scope: docs/microsoft/SCOPE.md, parts 0 and A.
--
-- What this installs
--   1. Schema focus_auth, which PostgREST does not serve: no REST request, direct or embedded, can
--      reach it. It holds each login's password hash and salt, its Authenticator secret (encrypted
--      by the proxy), its trusted devices, and the sign-in policy.
--   2. Functions public.auth_* (SECURITY DEFINER, EXECUTE for service_role only). They are the only
--      way in, and each refuses a request that does not carry the proxy's own internal mark, so a
--      signed-in user calling one through the proxy is refused even if a path rule were missed.
--   3. The move: every password hash and salt is copied into focus_auth and the two columns on
--      system_users are set to the marker '!vault', kept so by a trigger. The marker is deliberate:
--      an older copy of the proxy reads those columns, and an EMPTY column would tell it the
--      account is passwordless and let anyone choose its password. A marker matches no password.
--   4. user_sessions.method, so the Sign-in Log can say how a session was opened.
--
-- ORDER: deploy the new proxy (supabase/functions/sb) FIRST, then run this. The new proxy reads
-- the old columns until auth_read exists, so it runs before or after this file; the OLD proxy can
-- sign nobody in once this file has run.
--
-- Additive and re-runnable. Safe in the SQL editor and through the Supabase MCP. Nobody is signed
-- out by it. After a prod-to-dev clone (which recreates schema public) re-run it on DEV: it
-- re-makes the functions, the trigger and the link from focus_auth to system_users.
--
-- Last resort if every Admin is locked out, run as the database owner:
--   select auth_write(<system_users.id>, '{"totp_secret":null,"totp_confirmed_at":null,"clear_devices":true}');

create schema if not exists focus_auth;
revoke all on schema focus_auth from public;

create table if not exists focus_auth.credentials (
  system_user_id    bigint primary key,
  password_hash     text,
  password_salt     text,
  password_set_at   timestamptz,
  temp_expires_at   timestamptz,     -- set on a one-time password an admin issued; null otherwise
  totp_secret       text,            -- AES-GCM, encrypted by the proxy; never plain
  totp_confirmed_at timestamptz,     -- null while enrolment is pending
  totp_last_step    bigint,          -- the last 30-second step accepted (a code works once)
  updated_at        timestamptz not null default now()
);

create table if not exists focus_auth.trusted_devices (
  id             bigserial primary key,
  system_user_id bigint not null,
  token_hash     text not null unique,   -- SHA-256 of the token the browser keeps
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null,
  last_used_at   timestamptz,
  user_agent     text
);
create index if not exists trusted_devices_user_idx on focus_auth.trusted_devices (system_user_id);

create table if not exists focus_auth.config (
  key        text primary key,
  value      text,
  updated_at timestamptz not null default now(),
  updated_by bigint
);
insert into focus_auth.config (key, value) values ('code_required', 'false'), ('trust_days', '30')
on conflict (key) do nothing;

alter table public.user_sessions add column if not exists method text;

-- ── The internal mark ────────────────────────────────────────────────────────────────────────
-- A REST request reaches these functions only through the Focus proxy. The proxy stamps
-- x-focus-client on everything it forwards for a browser and x-focus-internal on its own sign-in
-- calls; a browser can set neither. No request headers at all means direct SQL by the database
-- owner, which is allowed.
create or replace function focus_auth.guard() returns void
language plpgsql
set search_path = pg_catalog
as $$
declare
  h text := current_setting('request.headers', true);
  j jsonb;
begin
  if h is null or h = '' then return; end if;
  begin
    j := h::jsonb;
  exception when others then
    raise exception 'auth: not allowed' using errcode = '42501';
  end;
  if coalesce(j->>'x-focus-internal', '') <> 'auth' or j ? 'x-focus-client' then
    raise exception 'auth: not allowed' using errcode = '42501';
  end if;
end;
$$;

create or replace function focus_auth.cfg(p_key text, p_default text) returns text
language sql stable
set search_path = pg_catalog
as $$
  select coalesce((select value from focus_auth.config where key = p_key), p_default)
$$;

-- ── Read one login, with its secrets and the policy ──────────────────────────────────────────
create or replace function public.auth_read(p_username text default null, p_user_id bigint default null)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog
as $$
declare
  u public.system_users%rowtype;
  c focus_auth.credentials%rowtype;
  days int;
begin
  perform focus_auth.guard();
  if p_user_id is not null then
    select * into u from public.system_users where id = p_user_id;
  elsif coalesce(btrim(p_username), '') <> '' then
    select * into u from public.system_users where lower(username) = lower(btrim(p_username)) order by id limit 1;
  end if;
  if u.id is null then return null; end if;
  select * into c from focus_auth.credentials where system_user_id = u.id;
  begin
    days := greatest(0, least(365, focus_auth.cfg('trust_days', '30')::int));
  exception when others then
    days := 30;
  end;
  return jsonb_build_object(
    'id', u.id, 'person_id', u.person_id, 'username', u.username, 'active', u.active,
    'must_set_password', u.must_set_password, 'failed_login_count', u.failed_login_count,
    'locked_until', u.locked_until, 'session_version', u.session_version,
    'password_hash', c.password_hash, 'password_salt', c.password_salt,
    'temp_expires_at', c.temp_expires_at,
    'totp_secret', c.totp_secret, 'totp_confirmed_at', c.totp_confirmed_at, 'totp_last_step', c.totp_last_step,
    'code_required', focus_auth.cfg('code_required', 'false') = 'true',
    'trust_days', days);
end;
$$;

-- ── Write: only the keys present in the patch change ─────────────────────────────────────────
--   system_users : failed_login_count, locked_until, must_set_password, bump (session_version + 1)
--   credentials  : password_hash, password_salt, temp_expires_at, totp_secret, totp_confirmed_at,
--                  totp_last_step
--   clear_devices: forget every trusted device
create or replace function public.auth_write(p_user_id bigint, p_patch jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog
as $$
begin
  perform focus_auth.guard();
  if p_patch is null or not exists (select 1 from public.system_users where id = p_user_id) then
    return null;
  end if;

  if p_patch ?| array['failed_login_count', 'locked_until', 'must_set_password', 'bump', 'password_hash'] then
    update public.system_users set
      failed_login_count = case when p_patch ? 'failed_login_count'
                                then coalesce((p_patch->>'failed_login_count')::int, 0) else failed_login_count end,
      locked_until       = case when p_patch ? 'locked_until'
                                then (p_patch->>'locked_until')::timestamptz else locked_until end,
      must_set_password  = case when p_patch ? 'must_set_password'
                                then coalesce((p_patch->>'must_set_password')::boolean, false) else must_set_password end,
      password_set_at    = case when p_patch ? 'password_hash'
                                then (case when p_patch->>'password_hash' is null then null else now() end)
                                else password_set_at end,
      session_version    = case when coalesce((p_patch->>'bump')::boolean, false)
                                then coalesce(session_version, 1) + 1 else session_version end
    where id = p_user_id;
  end if;

  if p_patch ?| array['password_hash', 'password_salt', 'temp_expires_at', 'totp_secret', 'totp_confirmed_at', 'totp_last_step'] then
    insert into focus_auth.credentials (system_user_id) values (p_user_id) on conflict (system_user_id) do nothing;
    update focus_auth.credentials set
      password_hash     = case when p_patch ? 'password_hash' then p_patch->>'password_hash' else password_hash end,
      password_salt     = case when p_patch ? 'password_salt' then p_patch->>'password_salt' else password_salt end,
      password_set_at   = case when p_patch ? 'password_hash'
                               then (case when p_patch->>'password_hash' is null then null else now() end)
                               else password_set_at end,
      temp_expires_at   = case when p_patch ? 'temp_expires_at' then (p_patch->>'temp_expires_at')::timestamptz else temp_expires_at end,
      totp_secret       = case when p_patch ? 'totp_secret' then p_patch->>'totp_secret' else totp_secret end,
      totp_confirmed_at = case when p_patch ? 'totp_confirmed_at' then (p_patch->>'totp_confirmed_at')::timestamptz else totp_confirmed_at end,
      totp_last_step    = case when p_patch ? 'totp_last_step' then (p_patch->>'totp_last_step')::bigint else totp_last_step end,
      updated_at        = now()
    where system_user_id = p_user_id;
  end if;

  if coalesce((p_patch->>'clear_devices')::boolean, false) then
    delete from focus_auth.trusted_devices where system_user_id = p_user_id;
  end if;

  return public.auth_read(null, p_user_id);
end;
$$;

-- A code works once: true only for the first caller to claim a step later than the last one.
create or replace function public.auth_totp_step(p_user_id bigint, p_step bigint)
returns boolean
language plpgsql security definer
set search_path = pg_catalog
as $$
declare n int;
begin
  perform focus_auth.guard();
  update focus_auth.credentials set totp_last_step = p_step, updated_at = now()
   where system_user_id = p_user_id and coalesce(totp_last_step, 0) < p_step;
  get diagnostics n = row_count;
  return n > 0;
end;
$$;

-- ── Trusted devices ──────────────────────────────────────────────────────────────────────────
create or replace function public.auth_device_add(p_user_id bigint, p_token_hash text, p_expires_at timestamptz, p_user_agent text default null)
returns boolean
language plpgsql security definer
set search_path = pg_catalog
as $$
begin
  perform focus_auth.guard();
  delete from focus_auth.trusted_devices where expires_at < now();
  insert into focus_auth.trusted_devices (system_user_id, token_hash, expires_at, user_agent)
  values (p_user_id, p_token_hash, p_expires_at, left(p_user_agent, 400));
  -- Ten devices a login at most: the oldest go.
  delete from focus_auth.trusted_devices d
   where d.system_user_id = p_user_id
     and d.id not in (select id from focus_auth.trusted_devices
                       where system_user_id = p_user_id order by created_at desc, id desc limit 10);
  return true;
end;
$$;

create or replace function public.auth_device_ok(p_user_id bigint, p_token_hash text)
returns boolean
language plpgsql security definer
set search_path = pg_catalog
as $$
declare n int;
begin
  perform focus_auth.guard();
  update focus_auth.trusted_devices set last_used_at = now()
   where system_user_id = p_user_id and token_hash = p_token_hash and expires_at > now();
  get diagnostics n = row_count;
  return n > 0;
end;
$$;

-- ── For the System Users page (the proxy checks manage_system_users before calling) ───────────
create or replace function public.auth_admin_list()
returns jsonb
language plpgsql security definer
set search_path = pg_catalog
as $$
begin
  perform focus_auth.guard();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', u.id,
             'has_password', c.password_hash is not null,
             'must_set_password', u.must_set_password,
             'temp_expires_at', c.temp_expires_at,
             'enrolled_at', c.totp_confirmed_at,
             'devices', (select count(*) from focus_auth.trusted_devices d
                          where d.system_user_id = u.id and d.expires_at > now()),
             'locked_until', u.locked_until) order by u.id)
      from public.system_users u
      left join focus_auth.credentials c on c.system_user_id = u.id), '[]'::jsonb);
end;
$$;

-- ── Policy ───────────────────────────────────────────────────────────────────────────────────
create or replace function public.auth_config_get()
returns jsonb
language plpgsql security definer
set search_path = pg_catalog
as $$
begin
  perform focus_auth.guard();
  return coalesce((select jsonb_object_agg(key, value) from focus_auth.config), '{}'::jsonb);
end;
$$;

create or replace function public.auth_config_set(p_key text, p_value text, p_actor bigint default null)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog
as $$
declare old_value text;
begin
  perform focus_auth.guard();
  if p_key not in ('code_required', 'trust_days') then
    raise exception 'auth: unknown setting %', p_key;
  end if;
  select value into old_value from focus_auth.config where key = p_key;
  insert into focus_auth.config (key, value, updated_at, updated_by) values (p_key, p_value, now(), p_actor)
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = excluded.updated_by;
  if old_value is distinct from p_value then
    insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, changes)
    values (p_actor, p_actor, 'settings', null, 'UPDATE',
            jsonb_build_object('signin_' || p_key, jsonb_build_object('o', old_value, 'n', p_value)));
  end if;
  return public.auth_config_get();
end;
$$;

-- An admin's reset leaves a line in the audit trail that says what it was (the secrets themselves
-- are never written there).
create or replace function public.auth_audit(p_actor bigint, p_user_id bigint, p_what text, p_old text, p_new text)
returns boolean
language plpgsql security definer
set search_path = pg_catalog
as $$
begin
  perform focus_auth.guard();
  insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, changes)
  values (p_actor, p_actor, 'system_users', p_user_id, 'UPDATE',
          jsonb_build_object(left(p_what, 60), jsonb_build_object('o', p_old, 'n', p_new)));
  return true;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'auth_read(text, bigint)', 'auth_write(bigint, jsonb)', 'auth_totp_step(bigint, bigint)',
    'auth_device_add(bigint, text, timestamptz, text)', 'auth_device_ok(bigint, text)',
    'auth_admin_list()', 'auth_config_get()', 'auth_config_set(text, text, bigint)',
    'auth_audit(bigint, bigint, text, text, text)']
  loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- ── Session version: a password change no longer shows on system_users ───────────────────────
-- The proxy bumps the version itself (auth_write, bump) when a password is set or reset. The
-- trigger keeps the two cases that still arrive as plain row changes.
create or replace function public.bump_session_version() returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if (old.active is not false and new.active is false)                        -- deactivated
     or (old.must_set_password is not true and new.must_set_password is true)  -- forced reset switched on
  then
    new.session_version := coalesce(old.session_version, 1) + 1;
  end if;
  return new;
end;
$$;

-- ── The move ─────────────────────────────────────────────────────────────────────────────────
insert into focus_auth.credentials (system_user_id, password_hash, password_salt, password_set_at)
select id, password_hash, password_salt, password_set_at
  from public.system_users
 where password_hash is not null and password_hash <> '!vault'
on conflict (system_user_id) do nothing;

-- The two old columns hold the marker from here on, whatever anything writes to them.
create or replace function public.system_users_vault_columns() returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  new.password_hash := '!vault';
  new.password_salt := '!vault';
  return new;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.system_users'::regclass and tgname = 'system_users_vault_columns') then
    create trigger system_users_vault_columns
      before insert or update on public.system_users
      for each row execute function public.system_users_vault_columns();
  end if;
end $$;

update public.system_users
   set password_hash = '!vault', password_salt = '!vault'
 where password_hash is distinct from '!vault' or password_salt is distinct from '!vault';

-- The link to system_users (lost when a clone recreates schema public): rows for logins that no
-- longer exist go first, then the constraint is made if it is not there.
delete from focus_auth.credentials c
 where not exists (select 1 from public.system_users u where u.id = c.system_user_id);
delete from focus_auth.trusted_devices d
 where not exists (select 1 from public.system_users u where u.id = d.system_user_id);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'credentials_system_user_fk'
                    and conrelid = 'focus_auth.credentials'::regclass) then
    alter table focus_auth.credentials
      add constraint credentials_system_user_fk
      foreign key (system_user_id) references public.system_users (id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'trusted_devices_system_user_fk'
                    and conrelid = 'focus_auth.trusted_devices'::regclass) then
    alter table focus_auth.trusted_devices
      add constraint trusted_devices_system_user_fk
      foreign key (system_user_id) references public.system_users (id) on delete cascade;
  end if;
end $$;

notify pgrst, 'reload schema';

-- Check: every login, whether it holds a password, and the policy.
select u.id, u.username, u.active, (c.password_hash is not null) as has_password,
       u.password_hash as old_column, c.totp_confirmed_at as enrolled_at,
       focus_auth.cfg('code_required', 'false') as code_required
  from public.system_users u
  left join focus_auth.credentials c on c.system_user_id = u.id
 order by u.id;
