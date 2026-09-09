-- Focus CRM performance review, September 2026 — proposal 1.4
-- (findings TRG-A1, TRG-A4, OPP-11, PW-11 in findings-catalogue.md)
--
-- audit_row_change (sql/add_audit_log.sql) runs FOR EACH ROW: it re-parses the
-- request headers, builds two full jsonb documents and does a jsonb_each hash
-- join per row, then inserts one audit_log row maintaining three indexes. A
-- 36-month forecast save or a 150-row bulk shift runs it 36 / 150 times inside
-- the user's transaction. This replaces it with ONE call per statement using
-- transition tables. Same audit_log rows, same x-actor-id attribution.
--
-- Run on test first. Requires Postgres 10+ (transition tables); Supabase is fine.

begin;

create or replace function public.audit_stmt() returns trigger
language plpgsql security definer as $$
declare v_actor bigint;
begin
  begin
    v_actor := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-actor-id', '')::bigint;
  exception when others then v_actor := null;
  end;

  if tg_op = 'INSERT' then
    insert into public.audit_log (actor_id, table_name, row_id, op, row_data)
    select v_actor, tg_table_name, nullif(to_jsonb(n)->>'id', '')::bigint, 'INSERT', to_jsonb(n)
      from new_rows n;

  elsif tg_op = 'DELETE' then
    insert into public.audit_log (actor_id, table_name, row_id, op, row_data)
    select v_actor, tg_table_name, nullif(to_jsonb(o)->>'id', '')::bigint, 'DELETE', to_jsonb(o)
      from old_rows o;

  else
    insert into public.audit_log (actor_id, table_name, row_id, op, changes)
    select v_actor, tg_table_name, nullif(x.nj->>'id', '')::bigint, 'UPDATE', d.changes
      from (select to_jsonb(n) as nj, to_jsonb(o) as oj
              from new_rows n
              join old_rows o on o.id = n.id) x
      cross join lateral (
        select jsonb_object_agg(k, jsonb_build_object('o', x.oj->k, 'n', x.nj->k)) as changes
          from jsonb_object_keys(x.nj) k
         where k not in ('updated_at', 'last_seen_at')
           and x.nj->k is distinct from x.oj->k) d
     where d.changes is not null;
  end if;
  return null;
end $$;

-- Re-attach: drop the row-level trigger and create three statement-level ones
-- (REFERENCING is per event). Same table list as add_audit_log.sql.
do $$
declare t text;
begin
  foreach t in array array[
    'leads','deals','organisations','people','sites','engagements',
    'revenue_streams','revenue_stream_months',
    'deal_contacts','deal_collaborators','person_organisation_roles',
    'promotion_requests','lead_red_flags',
    'settings','system_users','user_roles','role_permissions'
  ] loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('drop trigger if exists audit_%I on public.%I', t, t);
    execute format('drop trigger if exists audit_ins_%I on public.%I', t, t);
    execute format('drop trigger if exists audit_upd_%I on public.%I', t, t);
    execute format('drop trigger if exists audit_del_%I on public.%I', t, t);
    execute format('create trigger audit_ins_%1$I after insert on public.%1$I referencing new table as new_rows for each statement execute function public.audit_stmt()', t);
    execute format('create trigger audit_upd_%1$I after update on public.%1$I referencing old table as old_rows new table as new_rows for each statement execute function public.audit_stmt()', t);
    execute format('create trigger audit_del_%1$I after delete on public.%1$I referencing old table as old_rows for each statement execute function public.audit_stmt()', t);
  end loop;
end $$;

commit;

-- ── Optional (TRG-A4): retention. audit_log grows without bound today.
-- pg_cron is available on Supabase; keep 18 months:
--   create extension if not exists pg_cron;
--   select cron.schedule('focus_audit_retention', '15 2 * * *',
--     $$delete from public.audit_log where at < now() - interval '18 months'$$);
--
-- Consider dropping revenue_stream_months, engagement_people and deal_collaborators
-- from the audited list and auditing the parent row instead: a forecast save then
-- costs 1 audit row instead of 36-72.
