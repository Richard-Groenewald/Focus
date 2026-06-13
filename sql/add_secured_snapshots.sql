-- Secured snapshots — write-only historical record of a deal's pipeline at the
-- moment it was secured. NEVER read for reporting or projection; the live
-- weighted pipeline (revenue_streams / revenue_stream_months) stays the single
-- source of truth. This is an audit trail of the securing event only.
--
-- Securing is an EVENT: selecting the Secured stage fires the "secured process"
-- (future: verification + authorisation). For now that process sets the deal's
-- probability to 100% and writes one row here. Reporting then continues against
-- the live weighted value (now 100%) until actuals replace months.
--
-- Run once per DB (psql or SQL editor). Safe to re-run.

begin;

create table if not exists secured_snapshots (
  id           bigserial primary key,
  deal_id      bigint not null references deals(id),
  pipeline     jsonb  not null default '[]'::jsonb,   -- [{month,revenue,margin}, …] frozen at securing
  secured_at   timestamptz default now(),
  secured_by   bigint references people(id),
  accepted_by  bigint references people(id),          -- future: authorisation step
  accepted_at  timestamptz,                            -- future
  created_at   timestamptz default now()
);

create index if not exists secured_snapshots_deal_idx on secured_snapshots (deal_id);

commit;

-- Verify:
--   select id, deal_id, secured_at, secured_by,
--          jsonb_array_length(pipeline) as months
--   from secured_snapshots order by created_at desc;
