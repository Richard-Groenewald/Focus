-- Audit log (2026-07-05, DEV ONLY for now).
-- One generic append-only log + a row-change trigger on the business tables:
-- every INSERT / UPDATE / DELETE records who, when, what changed (old→new diff).
--
-- Actor: the app sends its current user via an X-Actor-Id request header
-- (api() → sb.js proxy → PostgREST, which exposes headers to the transaction as
-- the request.headers GUC). Direct psql/SQL work has no header → actor NULL,
-- which the admin UI renders as "System / SQL". NOTE: the actor is app-reported
-- (login has no real auth yet) — this is an audit trail, not a security control.
-- Idempotent: safe to re-run; re-attaches triggers to the current table list.

begin;

create table if not exists audit_log (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  actor_id   bigint,                  -- people.id as reported by the app; NULL = direct SQL/trigger
  table_name text not null,
  row_id     bigint,                  -- NULL for tables without a bigint id
  op         text not null check (op in ('INSERT','UPDATE','DELETE')),
  changes    jsonb,                   -- UPDATE: { col: { o: old, n: new }, ... }
  row_data   jsonb                    -- INSERT/DELETE: full row snapshot
);

create index if not exists audit_log_at_idx    on audit_log (at desc);
create index if not exists audit_log_row_idx   on audit_log (table_name, row_id);
create index if not exists audit_log_actor_idx on audit_log (actor_id);

create or replace function audit_row_change() returns trigger
language plpgsql security definer as $$
declare
  v_actor   bigint;
  v_changes jsonb;
  v_row     jsonb;
begin
  -- Actor from the PostgREST request headers (absent for direct SQL).
  begin
    v_actor := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-actor-id', '')::bigint;
  exception when others then v_actor := null;
  end;

  if tg_op = 'UPDATE' then
    -- Only the fields that actually changed; updated_at alone is noise, skip it.
    select coalesce(jsonb_object_agg(n.key, jsonb_build_object('o', o.value, 'n', n.value)), '{}'::jsonb)
      into v_changes
      from jsonb_each(to_jsonb(new)) n
      join jsonb_each(to_jsonb(old)) o on o.key = n.key
     where n.value is distinct from o.value
       and n.key <> 'updated_at';
    if v_changes = '{}'::jsonb then return new; end if;
    insert into audit_log (actor_id, table_name, row_id, op, changes)
    values (v_actor, tg_table_name, nullif(to_jsonb(new)->>'id','')::bigint, 'UPDATE', v_changes);
    return new;
  elsif tg_op = 'INSERT' then
    v_row := to_jsonb(new);
    insert into audit_log (actor_id, table_name, row_id, op, row_data)
    values (v_actor, tg_table_name, nullif(v_row->>'id','')::bigint, 'INSERT', v_row);
    return new;
  else
    v_row := to_jsonb(old);
    insert into audit_log (actor_id, table_name, row_id, op, row_data)
    values (v_actor, tg_table_name, nullif(v_row->>'id','')::bigint, 'DELETE', v_row);
    return old;
  end if;
end;
$$;

-- Attach to the business tables (append-only history tables like
-- secured_snapshots / lead_description_log audit themselves by design; the
-- quote prototype tables are excluded for now to keep noise down).
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
    execute format('drop trigger if exists audit_%I on %I', t, t);
    execute format('create trigger audit_%I after insert or update or delete on %I for each row execute function audit_row_change()', t, t);
  end loop;
end $$;

commit;
