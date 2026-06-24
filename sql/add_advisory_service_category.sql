-- Focus CRM — extend the service taxonomy
-- ----------------------------------------------------------------------------
-- Adds the "Advisory & Design" major category and its supporting service lines.
--
-- WHY: the live taxonomy had Manpower + Technology only. The real offering also
-- includes supporting services (design consulting, risk reviews, process design).
-- Categories/lines are data-driven, so adding rows is all that's needed for them
-- to appear in the campaign / lead Service Focus pickers and the opportunity
-- stream builder.
--
-- NOTE: a recurring Technology line ALREADY exists in the live DBs as
-- "Maintenance" (Technology / Maintenance / recurring / 30%), so we do NOT add a
-- separate monitoring line — that would duplicate it.
--
-- ⚠️  default_margin for the Advisory lines is a PLACEHOLDER (40%). Confirm the
--     real margins with Richard, then adjust here or in Admin → Service Sub Categories.
--
-- Verified applied to Dev (rfazs…) 2026-06-24. Idempotent: safe to re-run.
-- Run on prod (kevrf…) when ready.
-- ----------------------------------------------------------------------------

-- 1. New major category --------------------------------------------------------
insert into service_major (name, active, created_at)
select 'Advisory & Design', true, now()
where not exists (select 1 from service_major where name = 'Advisory & Design');

-- 2. Advisory & Design lines (non-recurring, one-off engagements) ---------------
insert into service_sub (major_id, name, is_recurring, default_margin, active, default_duration, created_at)
select m.id, v.name, false, 40, true, 1, now()
from service_major m
cross join (values
  ('Design Consulting'),
  ('Risk Review'),
  ('Process Design & Definition')
) as v(name)
where m.name = 'Advisory & Design'
  and not exists (select 1 from service_sub s where s.name = v.name);

-- Verify -----------------------------------------------------------------------
-- select m.name as category, s.name as line, s.is_recurring, s.default_margin
-- from service_sub s join service_major m on m.id = s.major_id
-- order by m.id, s.id;
