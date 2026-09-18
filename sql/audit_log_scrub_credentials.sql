-- Audit log stops holding credentials (Focus v7.9.58, Richard 2026-09-18: "fix the
-- audit log password hashes"). Idempotent — safe to re-run on either database.
--
-- The audit triggers diff / snapshot the FULL row, so every password_hash and
-- password_salt write on system_users since v7.8.52 landed in audit_log.changes
-- (UPDATE) or audit_log.row_data (INSERT / DELETE): 29 rows on prod, 21 on dev
-- (counted 2026-09-17). audit_log is readable through the proxy by any signed-in
-- user, which re-opened the offline brute-force exposure v7.8.52 closed by
-- scrubbing system_users responses. Three parts:
--   1. audit_scrub(jsonb): drops password_hash / password_salt / password from a
--      document. Applied to whatever BOTH trigger functions record — audit_stmt()
--      (statement-level, system_users and most tables since v7.9.37) and
--      audit_row_change() (row-level, still on the tables without an id) — for
--      every table, so a future table with such a column is covered too.
--   2. Purge the keys from the historical rows (rows kept; only the keys go).
--   3. netlify/functions/sb.js strips the same keys from audit_log responses as
--      a backstop and keeps that endpoint plain (never gzip-passed-through).
-- Both functions also gain a pinned search_path (the Supabase advisor lint) —
-- bodies otherwise identical to the live definitions read off prod 2026-09-18.

begin;

create or replace function public.audit_scrub(p_doc jsonb) returns jsonb
language sql immutable
set search_path = pg_catalog, public
as $$
  select case when p_doc is null then null
              else p_doc - 'password_hash' - 'password_salt' - 'password' end
$$;

create or replace function public.audit_stmt() returns trigger
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
  v_actor bigint;
  v_real  bigint;
begin
  -- Actor from the PostgREST request headers (absent for direct SQL) — once per statement.
  begin
    v_actor := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-actor-id', '')::bigint;
  exception when others then v_actor := null;
  end;
  begin
    v_real := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-real-actor-id', '')::bigint;
  exception when others then v_real := null;
  end;
  if v_real is not null and v_real = v_actor then v_real := null; end if;

  if tg_op = 'INSERT' then
    insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, row_data)
    select v_actor, v_real, tg_table_name, nullif(to_jsonb(n)->>'id', '')::bigint, 'INSERT', public.audit_scrub(to_jsonb(n))
      from new_rows n;

  elsif tg_op = 'DELETE' then
    insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, row_data)
    select v_actor, v_real, tg_table_name, nullif(to_jsonb(o)->>'id', '')::bigint, 'DELETE', public.audit_scrub(to_jsonb(o))
      from old_rows o;

  else
    -- Only the fields that actually changed; updated_at alone is noise, skip it.
    -- Credential columns are dropped from the diff; a diff that held nothing
    -- else (a bare hash rewrite) is not recorded at all.
    insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, changes)
    select v_actor, v_real, tg_table_name, nullif(x.nj->>'id', '')::bigint, 'UPDATE', public.audit_scrub(d.changes)
      from (select to_jsonb(n) as nj, to_jsonb(o) as oj
              from new_rows n
              join old_rows o on o.id = n.id) x
      cross join lateral (
        select jsonb_object_agg(k, jsonb_build_object('o', x.oj->k, 'n', x.nj->k)) as changes
          from jsonb_object_keys(x.nj) k
         where k <> 'updated_at'
           and x.nj->k is distinct from x.oj->k) d
     where d.changes is not null
       and public.audit_scrub(d.changes) <> '{}'::jsonb;
  end if;
  return null;
end;
$$;

create or replace function public.audit_row_change() returns trigger
language plpgsql security definer
set search_path = pg_catalog, public
as $$
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
    v_changes := public.audit_scrub(v_changes);
    if v_changes = '{}'::jsonb then return new; end if;
    insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, changes)
    values (v_actor, v_real, tg_table_name, nullif(to_jsonb(new)->>'id','')::bigint, 'UPDATE', v_changes);
    return new;
  elsif tg_op = 'INSERT' then
    v_row := to_jsonb(new);
    insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, row_data)
    values (v_actor, v_real, tg_table_name, nullif(v_row->>'id','')::bigint, 'INSERT', public.audit_scrub(v_row));
    return new;
  else
    v_row := to_jsonb(old);
    insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, row_data)
    values (v_actor, v_real, tg_table_name, nullif(v_row->>'id','')::bigint, 'DELETE', public.audit_scrub(v_row));
    return old;
  end if;
end;
$$;

-- 2. Purge the historical rows. Rows stay (the change still happened); only the
--    credential keys go. audit_log has no update trigger and is not itself audited.
update public.audit_log
   set changes = public.audit_scrub(changes)
 where changes ?| array['password_hash', 'password_salt', 'password'];

update public.audit_log
   set row_data = public.audit_scrub(row_data)
 where row_data ?| array['password_hash', 'password_salt', 'password'];

commit;

-- Verify: both must be 0.
select count(*) as audit_rows_with_credentials_should_be_0
  from public.audit_log
 where changes ?| array['password_hash', 'password_salt', 'password']
    or row_data ?| array['password_hash', 'password_salt', 'password'];
select count(*) as audit_functions_without_search_path_should_be_0
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('audit_stmt', 'audit_row_change', 'audit_scrub')
   and (p.proconfig is null or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'));
