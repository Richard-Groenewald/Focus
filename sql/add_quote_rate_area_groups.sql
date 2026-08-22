-- Area groups for the salary rate grid (2026-08-22). Additive; run on BOTH databases.
--
-- The rate grid's combining model is two-level: AREAS combine into column groups (the published
-- "AREA 1 & AREA 2 (URBAN)"), and within each area group, GRADES combine into row blocks. The
-- cell blocks in quote_rate_groups express the intersection; what they cannot hold is the
-- AREA-group itself and its description - "Urban" spanning Areas 1 & 2 - which Richard wants
-- shown and edited as its own header row, per version, standalone areas included.
--
-- Every area belongs to exactly one area group per version (a standalone area is a group of
-- one), so the description row always has somewhere to write.

begin;

create table if not exists quote_rate_area_groups (
  id             bigserial primary key,
  effective_date date not null,
  description    text,
  created_at     timestamptz not null default now(),
  created_by     bigint references people(id),
  unique (id, effective_date)
);

create table if not exists quote_rate_area_group_members (
  group_id       bigint not null,
  effective_date date   not null,
  area_id        bigint not null references quote_areas(id),
  primary key (group_id, area_id),
  -- One group per area per version.
  unique (effective_date, area_id),
  foreign key (group_id, effective_date)
    references quote_rate_area_groups(id, effective_date) on delete cascade
);

create index if not exists quote_rate_area_groups_version_idx on quote_rate_area_groups (effective_date);

do $$ begin
  execute 'create trigger audit_quote_rate_area_groups after insert or update or delete on quote_rate_area_groups
           for each row execute function audit_row_change()';
exception when duplicate_object then null; when undefined_function then null; end $$;
do $$ begin
  execute 'create trigger audit_quote_rate_area_group_members after insert or update or delete on quote_rate_area_group_members
           for each row execute function audit_row_change()';
exception when duplicate_object then null; when undefined_function then null; end $$;

-- Seed every captured version with the arrangement the agreement publishes: Areas 1 & 2 as
-- "Urban", Areas 3 & 4 as "Rural". Only versions with no area groups yet are touched.
with defs(gkey, area_codes, descr) as (values
  ('seed:urban', array['area_1','area_2'], 'Urban'),
  ('seed:rural', array['area_3','area_4'], 'Rural')
)
insert into quote_rate_area_groups (effective_date, description)
select v.effective_date, d.gkey
  from (select distinct effective_date from quote_salary_rates) v
  cross join defs d
 where not exists (select 1 from quote_rate_area_group_members m where m.effective_date = v.effective_date);

with defs(gkey, area_codes, descr) as (values
  ('seed:urban', array['area_1','area_2'], 'Urban'),
  ('seed:rural', array['area_3','area_4'], 'Rural')
)
insert into quote_rate_area_group_members (group_id, effective_date, area_id)
select g.id, g.effective_date, a.id
  from quote_rate_area_groups g
  join defs d on d.gkey = g.description
  join quote_areas a on a.code = any(d.area_codes)
on conflict do nothing;

update quote_rate_area_groups g
   set description = case g.description when 'seed:urban' then 'Urban' when 'seed:rural' then 'Rural' end
 where g.description like 'seed:%';

commit;

-- Verify (expect 2 groups / 4 members per version, descriptions Urban + Rural):
--   select g.effective_date, g.description, count(m.area_id)
--     from quote_rate_area_groups g
--     left join quote_rate_area_group_members m on m.group_id = g.id
--    group by 1, 2 order by 1, 2;
