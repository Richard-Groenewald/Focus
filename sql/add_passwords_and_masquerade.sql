-- Passwords + masquerade (v7.8.52).
-- Run on BOTH databases (prod first at release, per the release recipe).
--
-- Until now Focus had no authentication at all: the login screen was a user
-- picker, and system_users.password held plaintext ('test', 'admin', 'none').
-- This is the deliberately rudimentary first pass — a real password per user,
-- hashed, verified server-side in the Netlify function. It is NOT a full auth
-- system: no sessions, no lockout, no reset-by-email, no rotation policy. Those
-- come with the wider permissions work (see the permissions-model revisit).
--
-- WHAT CHANGES FOR USERS: everybody is asked to set a password the next time they
-- sign in, and nobody gets in without one afterwards. Sessions live only in
-- memory today, so the deploy itself is the forced logout.

-- ── 1. Hashed credentials on system_users ────────────────────────────────────
-- PBKDF2-SHA256, 120k iterations, 16-byte salt, 32-byte key — computed and
-- verified in netlify/functions/sb.js. The hash never reaches the browser.
ALTER TABLE system_users ADD COLUMN password_hash     TEXT;
ALTER TABLE system_users ADD COLUMN password_salt     TEXT;
ALTER TABLE system_users ADD COLUMN password_set_at   TIMESTAMPTZ;
ALTER TABLE system_users ADD COLUMN must_set_password BOOLEAN NOT NULL DEFAULT TRUE;

-- Wipe the plaintext. The column stays (NOT NULL, and the audit history refers to
-- it) but nothing reads or writes it from here on — the app no longer sends it,
-- so it needs a default or creating a user would fail on the NOT NULL.
UPDATE system_users SET password = '';
ALTER TABLE system_users ALTER COLUMN password SET DEFAULT '';

-- Everyone starts out having to choose one.
UPDATE system_users SET must_set_password = TRUE, password_hash = NULL, password_salt = NULL;

-- ── 2. The audit trail learns who was really at the keyboard ─────────────────
-- actor_id stays the EFFECTIVE user — the person the work is attributed to, so
-- every existing query, filter and report is unchanged. real_actor_id is filled
-- only while somebody is masquerading, and names the human who actually typed it.
ALTER TABLE audit_log ADD COLUMN real_actor_id BIGINT REFERENCES people(id);
CREATE INDEX idx_audit_real_actor ON audit_log(real_actor_id) WHERE real_actor_id IS NOT NULL;

-- Same trigger, one more header. x-real-actor-id is sent by the app only while a
-- masquerade is active (see api() in index.html), forwarded by sb.js.
CREATE OR REPLACE FUNCTION public.audit_row_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_actor   bigint;
  v_real    bigint;
  v_changes jsonb;
  v_row     jsonb;
begin
  -- Actor from the PostgREST request headers (absent for direct SQL).
  begin
    v_actor := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-actor-id', '')::bigint;
  exception when others then v_actor := null;
  end;
  -- The human behind the masquerade, when there is one.
  begin
    v_real := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-real-actor-id', '')::bigint;
  exception when others then v_real := null;
  end;
  if v_real is not null and v_real = v_actor then v_real := null; end if;

  if tg_op = 'UPDATE' then
    -- Only the fields that actually changed; updated_at alone is noise, skip it.
    select coalesce(jsonb_object_agg(n.key, jsonb_build_object('o', o.value, 'n', n.value)), '{}'::jsonb)
      into v_changes
      from jsonb_each(to_jsonb(new)) n
      join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.key <> 'updated_at';
    if v_changes = '{}'::jsonb then return new; end if;
    insert into audit_log (actor_id, real_actor_id, table_name, row_id, op, changes)
    values (v_actor, v_real, tg_table_name, nullif(to_jsonb(new)->>'id','')::bigint, 'UPDATE', v_changes);
    return new;
  elsif tg_op = 'INSERT' then
    v_row := to_jsonb(new);
    insert into audit_log (actor_id, real_actor_id, table_name, row_id, op, row_data)
    values (v_actor, v_real, tg_table_name, nullif(v_row->>'id','')::bigint, 'INSERT', v_row);
    return new;
  else
    v_row := to_jsonb(old);
    insert into audit_log (actor_id, real_actor_id, table_name, row_id, op, row_data)
    values (v_actor, v_real, tg_table_name, nullif(v_row->>'id','')::bigint, 'DELETE', v_row);
    return old;
  end if;
end;
$function$;

-- ── 3. The masquerade capability ─────────────────────────────────────────────
-- A named permission, granted to one person through user_permission_overrides —
-- the table has existed since the permissions build but was never wired up; the
-- app now applies it (grant TRUE adds, grant FALSE removes, on top of the role's
-- permissions). Nothing else is in that table, so nobody else's rights change.
INSERT INTO permissions (name, description)
VALUES ('masquerade_user', 'Sign in as another user. Work is attributed to that user; the audit trail records who was really acting.')
ON CONFLICT (name) DO NOTHING;

INSERT INTO user_permission_overrides (user_id, permission_id, granted)
SELECT su.id, p.id, TRUE
FROM system_users su, permissions p
WHERE su.username = 'richard' AND p.name = 'masquerade_user'
  AND NOT EXISTS (
    SELECT 1 FROM user_permission_overrides o
    WHERE o.user_id = su.id AND o.permission_id = p.id);

-- ── Verify ───────────────────────────────────────────────────────────────────
-- SELECT id, username, must_set_password, password_hash IS NULL AS no_hash, password FROM system_users ORDER BY id;
--   -> every row: must_set_password = t, no_hash = t, password = '' (blank)
-- SELECT su.username, p.name, o.granted
--   FROM user_permission_overrides o
--   JOIN system_users su ON su.id = o.user_id
--   JOIN permissions p ON p.id = o.permission_id;      -- richard | masquerade_user | t
