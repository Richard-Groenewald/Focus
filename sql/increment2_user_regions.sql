-- Increment 2 — Manager → region assignment
-- Run once against Supabase (SQL editor). Safe to re-run.
--
-- A system user (typically a Sales Manager) can hold one or more regions.
-- Used by canEditRecord() in increment 3 to scope a manager's override
-- permissions to records in their own region(s). Admins ignore this (all).

create table if not exists system_user_regions (
  id              bigserial primary key,
  system_user_id  bigint not null references system_users(id) on delete cascade,
  region_id       bigint not null references regions(id)       on delete cascade,
  created_at      timestamptz not null default now(),
  created_by      bigint references people(id),
  unique (system_user_id, region_id)
);

create index if not exists idx_system_user_regions_user
  on system_user_regions (system_user_id);

-- Verify:
--   select su.id as user_id, p.first_name || ' ' || p.last_name as person,
--          r.name as region
--   from system_user_regions sur
--   join system_users su on su.id = sur.system_user_id
--   join people p        on p.id  = su.person_id
--   join regions r       on r.id  = sur.region_id
--   order by person, region;
