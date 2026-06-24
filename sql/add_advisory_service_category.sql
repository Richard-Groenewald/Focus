-- Focus CRM — extend the service taxonomy
-- ----------------------------------------------------------------------------
-- Adds the "Advisory & Design" major category and its supporting service lines,
-- plus a recurring "Monitoring & Maintenance" line under Technology Works.
--
-- WHY: the live taxonomy only had Manpower + Technology Works (Project). The real
-- offering includes supporting services (design consulting, risk reviews, process
-- design) and recurring technology (monitoring), which the flat list could not
-- represent. Categories/lines are data-driven, so adding rows is all that's needed
-- for them to appear in the campaign / lead Service Focus pickers and the
-- opportunity stream builder.
--
-- ⚠️  default_margin values for the NEW lines are PLACEHOLDERS (40% advisory,
--     30% tech monitoring). Confirm the real margins with Richard, then adjust
--     here or in Admin → Service Sub Categories.
--
-- Idempotent: safe to re-run. Run on Dev first; promote to prod when ready.
-- ----------------------------------------------------------------------------

-- 1. New major category --------------------------------------------------------
insert into service_major (name, active, created_at)
select 'Advisory & Design', true, now()
where not exists (select 1 from service_major where name = 'Advisory & Design');

-- 2. Recurring technology line -------------------------------------------------
--    (corrects the gap where monitoring/maintenance had to be logged as the
--     non-recurring "Project" line)
insert into service_sub (major_id, name, is_recurring, default_margin, active, default_duration, created_at)
select (select id from service_major where name = 'Technology Works'),
       'Monitoring & Maintenance', true, 30, true, 12, now()
where not exists (select 1 from service_sub where name = 'Monitoring & Maintenance');

-- 3. Advisory & Design lines (non-recurring, one-off engagements) ---------------
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
