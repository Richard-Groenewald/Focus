-- Lead stage events (2026-08-20). Run on BOTH databases, prod first.
--
-- WHY. Reporting on "leads qualified this month" currently has to read
-- leads.qualified_at, which is a single overwritable column, not an event. A
-- lead that is qualified, pushed back to Working, and re-qualified keeps only
-- the LATEST timestamp — every earlier entry is silently lost. On prod today
-- the audit trail holds 27 entries into 'Qualified' while just 10 leads carry a
-- qualified_at: 17 events invisible to any count built on the column. Three
-- leads currently sitting in Working still carry a qualified_at, which is the
-- same fault seen from the other side.
--
-- WHAT. An append-only log of every lead status transition, backfilled from
-- audit_log and maintained from here on by a trigger — no app change needed,
-- so this works regardless of which build is deployed.
--
-- COVERAGE FLOOR. audit_log on prod begins 2026-07-05. Transitions before that
-- date are not recoverable from the trail; step 3 recovers what it can from the
-- lifecycle timestamp columns instead. Every known prod qualification falls
-- inside the audited window, so nothing is lost there today.
--
-- Idempotent / transactional: safe to re-run.

begin;

-- ── 1. The log ────────────────────────────────────────────────────────────────
create table if not exists lead_stage_events (
  id          bigserial primary key,
  lead_id     bigint not null references leads(id) on delete cascade,
  from_status text,                        -- null = lead created at to_status
  to_status   text not null,
  at          timestamptz not null default now(),
  actor_id    bigint references people(id),-- app-reported, as with audit_log
  source      text not null default 'app'
              check (source in ('app', 'backfill', 'backfill_timestamps'))
);

create index if not exists lead_stage_events_lead_idx on lead_stage_events (lead_id, at);
create index if not exists lead_stage_events_to_idx   on lead_stage_events (to_status, at);

-- One row per lead+transition+instant. Lets every backfill and the trigger
-- re-run without doubling up.
create unique index if not exists lead_stage_events_uniq
  on lead_stage_events (lead_id, to_status, at);

-- ── 2. Backfill from audit_log ────────────────────────────────────────────────
insert into lead_stage_events (lead_id, from_status, to_status, at, actor_id, source)
select a.row_id,
       nullif(a.changes->'status'->>'o', ''),
       a.changes->'status'->>'n',
       a.at,
       a.actor_id,
       'backfill'
  from audit_log a
  join leads l on l.id = a.row_id
 where a.table_name = 'leads'
   and a.op = 'UPDATE'
   and a.changes ? 'status'
   and coalesce(a.changes->'status'->>'n', '') <> ''
on conflict do nothing;

insert into lead_stage_events (lead_id, from_status, to_status, at, actor_id, source)
select a.row_id, null, a.row_data->>'status', a.at, a.actor_id, 'backfill'
  from audit_log a
  join leads l on l.id = a.row_id
 where a.table_name = 'leads'
   and a.op = 'INSERT'
   and coalesce(a.row_data->>'status', '') <> ''
on conflict do nothing;

-- ── 3. Recover pre-audit transitions from the lifecycle columns ───────────────
-- Only where the trail has no event for that lead+status at all, so an audited
-- transition always wins. Marked with its own source so these stay identifiable
-- as reconstructed rather than observed.
insert into lead_stage_events (lead_id, from_status, to_status, at, actor_id, source)
select l.id, null, v.status, v.ts, null, 'backfill_timestamps'
  from leads l
  cross join lateral (values ('Working',   l.working_at),
                             ('Qualified', l.qualified_at),
                             ('Promoted',  l.promoted_at)) as v(status, ts)
 where v.ts is not null
   and not exists (select 1 from lead_stage_events e
                    where e.lead_id = l.id and e.to_status = v.status)
on conflict do nothing;

-- ── 4. Maintain it from here on ───────────────────────────────────────────────
-- Actor comes from the PostgREST request headers, same mechanism (and same
-- app-reported caveat) as audit_row_change().
create or replace function trg_leads_log_stage_event() returns trigger
language plpgsql security definer as $$
declare v_actor bigint;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;

  begin
    v_actor := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-actor-id', '')::bigint;
  exception when others then v_actor := null;
  end;

  insert into lead_stage_events (lead_id, from_status, to_status, at, actor_id, source)
  values (new.id,
          case when tg_op = 'UPDATE' then old.status else null end,
          new.status, now(), v_actor, 'app')
  on conflict do nothing;

  return new;
end;
$$;

drop trigger if exists leads_log_stage_event on leads;
create trigger leads_log_stage_event
  after insert or update of status on leads
  for each row when (new.status is not null)
  execute function trg_leads_log_stage_event();

commit;

-- Verify (expected on prod as at 2026-08-20: 13 distinct leads qualified,
-- 7 in July and 6 in August — matching the audit-trail extract):
--   select to_char(at,'YYYY-MM') as month,
--          count(*) as events, count(distinct lead_id) as distinct_leads
--     from lead_stage_events where to_status = 'Qualified'
--    group by 1 order by 1;
--   select source, count(*) from lead_stage_events group by 1;
