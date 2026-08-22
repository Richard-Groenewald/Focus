-- Salary rate groups + the full published grid (2026-08-21). Step 1 of the build.
--
-- WHY. Sectoral wage tables are published as blocks: the NBCPSS agreement prints its columns as
-- "AREA 1 & AREA 2 (URBAN)" and "AREA 3 (RURAL)", and its grades as "A, B, C/D/E". Focus stored
-- only the distinct rates (Area 1 and Area 3, grades A/B/C), so the screen could not show the
-- four areas and five grades people actually work with, and nothing recorded WHICH areas or
-- grades were sharing a rate.
--
-- A rate GROUP is a block of cells that share one monthly and one hourly figure, under a label.
-- It belongs to a VERSION (an effective date), because the blocks change between determinations —
-- and it is declared rather than inferred, because equal figures are not proof of a shared rate.
--
-- Crucially the blocks are NOT the same shape in each area. In Areas 1 & 2, Grade B stands alone
-- and C/D/E share; in Areas 3 & 4, B joins C/D/E to make one rate for B–E. That has held in all
-- four captured determinations, and is why a group is a block of cells rather than a rule about
-- grades.
--
-- Underneath, quote_salary_rates is UNCHANGED in structure: still one row per area × grade ×
-- effective date. This script fills in the rows that were previously implied (Areas 2 and 4,
-- Grades D and E) so every published cell exists, with a group's figures repeated across its
-- members. 4 versions × 4 areas × 5 grades = 80 rows, holding 5 distinct rates per version.
--
-- Idempotent / transactional: safe to re-run.

begin;

-- ── 1. Area 4 ────────────────────────────────────────────────────────────────
-- Areas 1–3 exist; the published table's fourth area has never been captured because it has
-- always shared Area 3's rate.
insert into quote_areas (code, description, display_order)
select 'area_4', 'Area 4 (Other)', 40
where not exists (select 1 from quote_areas where code = 'area_4');

-- ── 2. The groups ────────────────────────────────────────────────────────────
create table if not exists quote_rate_groups (
  id             bigserial primary key,
  effective_date date    not null,
  -- NULL label = generated from the members ("Areas 1 & 2 · Grades C/D/E") and kept in step as
  -- membership changes. Typing one sets label_is_auto false and it stops tracking.
  label          text,
  label_is_auto  boolean not null default true,
  created_at     timestamptz not null default now(),
  created_by     bigint references people(id),
  -- Lets the cell table foreign-key the PAIR, so a cell can never point at a group belonging to
  -- a different version.
  unique (id, effective_date)
);

create table if not exists quote_rate_group_cells (
  group_id       bigint not null,
  effective_date date   not null,
  area_id        bigint not null references quote_areas(id),
  grade_id       bigint not null references quote_grades(id),
  primary key (group_id, area_id, grade_id),
  -- One group per cell per version: a cell cannot be in two blocks at once.
  unique (effective_date, area_id, grade_id),
  foreign key (group_id, effective_date)
    references quote_rate_groups(id, effective_date) on delete cascade
);

create index if not exists quote_rate_groups_version_idx on quote_rate_groups (effective_date);
create index if not exists quote_rate_group_cells_version_idx on quote_rate_group_cells (effective_date);

do $$ begin
  execute 'create trigger audit_quote_rate_groups after insert or update or delete on quote_rate_groups
           for each row execute function audit_row_change()';
exception when duplicate_object then null; when undefined_function then null; end $$;
do $$ begin
  execute 'create trigger audit_quote_rate_group_cells after insert or update or delete on quote_rate_group_cells
           for each row execute function audit_row_change()';
exception when duplicate_object then null; when undefined_function then null; end $$;

-- ── 3. Fill in every published cell ──────────────────────────────────────────
-- Area 2 takes Area 1's rate, Area 4 takes Area 3's; Grades D and E take Grade C's. That is the
-- arrangement the agreement prints, and it has held for every captured determination — where it
-- ever stops holding, the figures are simply captured separately and the group is split.
insert into quote_salary_rates (effective_date, grade_id, area_id, monthly_salary, hourly_rate)
select v.effective_date, g.id, a.id, src.monthly_salary, src.hourly_rate
  from (select distinct effective_date from quote_salary_rates) v
  cross join quote_areas a
  cross join quote_grades g
  join quote_areas  sa on sa.code = case when a.code in ('area_1','area_2') then 'area_1' else 'area_3' end
  join quote_grades sg on sg.code = case when g.code in ('A','B','C') then g.code else 'C' end
  join quote_salary_rates src
    on src.effective_date = v.effective_date and src.area_id = sa.id and src.grade_id = sg.id
on conflict (effective_date, grade_id, area_id) do nothing;

-- ── 4. Seed the groups for the versions already captured ─────────────────────
-- The seed key rides in `label` while the cells are attached, then is cleared so the labels go
-- back to auto — the app generates the display name from the members.
with defs(gkey, area_codes, grade_codes) as (values
  ('seed:urban_A',    array['area_1','area_2'], array['A']),
  ('seed:urban_B',    array['area_1','area_2'], array['B']),
  ('seed:urban_CDE',  array['area_1','area_2'], array['C','D','E']),
  ('seed:rural_A',    array['area_3','area_4'], array['A']),
  ('seed:rural_BCDE', array['area_3','area_4'], array['B','C','D','E'])
)
insert into quote_rate_groups (effective_date, label, label_is_auto)
select v.effective_date, d.gkey, true
  from (select distinct effective_date from quote_salary_rates) v
  cross join defs d
 where not exists (
   select 1 from quote_rate_group_cells c
   where c.effective_date = v.effective_date
 );

with defs(gkey, area_codes, grade_codes) as (values
  ('seed:urban_A',    array['area_1','area_2'], array['A']),
  ('seed:urban_B',    array['area_1','area_2'], array['B']),
  ('seed:urban_CDE',  array['area_1','area_2'], array['C','D','E']),
  ('seed:rural_A',    array['area_3','area_4'], array['A']),
  ('seed:rural_BCDE', array['area_3','area_4'], array['B','C','D','E'])
)
insert into quote_rate_group_cells (group_id, effective_date, area_id, grade_id)
select gr.id, gr.effective_date, a.id, g.id
  from quote_rate_groups gr
  join defs d on d.gkey = gr.label
  join quote_areas  a on a.code = any(d.area_codes)
  join quote_grades g on g.code = any(d.grade_codes)
on conflict do nothing;

update quote_rate_groups set label = null where label like 'seed:%';

-- ── 5. The version pointer on quotes ─────────────────────────────────────────
-- A quote records WHICH determination priced it, so re-opening an issued quote shows what the
-- client was actually quoted even after a past version is corrected. Nothing writes it yet —
-- no code prices off salary rates today — so it stays nullable, and the re-price action lands
-- with the pricing engine.
alter table quote_quotes
  add column if not exists salary_rate_effective_date date;

comment on column quote_quotes.salary_rate_effective_date is
  'Version of quote_salary_rates this quote was priced on. NULL = never priced from salary rates.';

commit;

-- Verify:
--   select effective_date, count(*) from quote_salary_rates group by 1 order by 1;   -- 20 each
--   select gr.effective_date, count(distinct gr.id) groups, count(c.*) cells
--     from quote_rate_groups gr left join quote_rate_group_cells c on c.group_id = gr.id
--    group by 1 order by 1;                                                          -- 5 / 20 each
--   -- every cell in exactly one group, and every group internally consistent:
--   select gr.id, count(distinct r.monthly_salary) distinct_rates
--     from quote_rate_groups gr
--     join quote_rate_group_cells c on c.group_id = gr.id
--     join quote_salary_rates r on r.effective_date = c.effective_date
--      and r.area_id = c.area_id and r.grade_id = c.grade_id
--    group by 1 having count(distinct r.monthly_salary) > 1;                         -- expect 0 rows
