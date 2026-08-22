-- Statutory salary rates, reconciled to source (2026-08-21). Data only, no schema change.
--
-- SOURCE. NBCPSS Illustrative Pricing Guide 2023–2027, built on the Main Collective
-- Agreement for the Private Security Sector:
--   https://nbcpss.org.za/wp-content/uploads/2026/03/Illustrative-Pricing-Guide-2023-2027.pdf
-- The guide publishes one table per period, each running 01 March to 28 February, with the
-- columns combined as "AREA 1 & AREA 2 (URBAN)" / "AREA 3 (RURAL)" and grades as A, B, C/D/E.
-- Focus's existing convention is followed here: the Area 1 row carries the Areas 1 & 2 rate,
-- the Area 3 row carries the Area 3 rate, and the Grade C row carries the C/D/E rate. The
-- four-area / five-grade grid with explicit merge groups is a separate, later piece of work.
--
-- WHY. Every one of the 16 rates already stored matched this source on the MONTHLY figure
-- exactly, which is what made it trustworthy. Three things did not line up:
--
--   1. HOURLY RATES WERE ROUNDED to 2 decimals on entry, always in the same direction on the
--      worst case: Grade A / Area 1 / 2025 was stored as 37.0000 where the agreement says
--      36.9952. Small per hour, but it multiplies across every officer-hour quoted. The column
--      is numeric(8,4) and the agreement publishes 4 decimals, so the precision was always
--      available. Richard's instruction: store whatever is published, correct what exists.
--
--   2. 2025 WAS INCOMPLETE — Area 3 grades B and C were absent entirely (4 rows where 2023 and
--      2024 each held 6). Both are R 6 256.00 / 30.0769.
--
--   3. THE CURRENT DETERMINATION WAS MISSING. 01 Mar 2026 – 28 Feb 2027 came into force nearly
--      six months ago and was not captured at all, so anything priced today would have used
--      last year's wages.
--
-- Lookups are matched by CODE, never by hardcoded id. Idempotent: re-running re-asserts the
-- published figures and changes nothing else.

begin;

with published (effective_date, grade_code, area_code, monthly_salary, hourly_rate) as (values
  -- 01 Mar 2023 – 28 Feb 2024
  ('2023-03-01'::date, 'A', 'area_1',  6907.00, 33.2067),
  ('2023-03-01'::date, 'B', 'area_1',  6330.00, 30.4327),
  ('2023-03-01'::date, 'C', 'area_1',  5726.00, 27.5288),
  ('2023-03-01'::date, 'A', 'area_3',  5915.00, 28.4375),
  ('2023-03-01'::date, 'B', 'area_3',  5499.00, 26.4375),
  ('2023-03-01'::date, 'C', 'area_3',  5499.00, 26.4375),
  -- 01 Mar 2024 – 28 Feb 2025
  ('2024-03-01'::date, 'A', 'area_1',  7277.00, 34.9856),
  ('2024-03-01'::date, 'B', 'area_1',  6700.00, 32.2115),
  ('2024-03-01'::date, 'C', 'area_1',  6096.00, 29.3077),
  ('2024-03-01'::date, 'A', 'area_3',  6271.00, 30.1490),
  ('2024-03-01'::date, 'B', 'area_3',  5855.00, 28.1490),
  ('2024-03-01'::date, 'C', 'area_3',  5855.00, 28.1490),
  -- 01 Mar 2025 – 28 Feb 2026   (Area 3 B and C were the missing rows)
  ('2025-03-01'::date, 'A', 'area_1',  7695.00, 36.9952),
  ('2025-03-01'::date, 'B', 'area_1',  7118.00, 34.2212),
  ('2025-03-01'::date, 'C', 'area_1',  6514.00, 31.3173),
  ('2025-03-01'::date, 'A', 'area_3',  6672.00, 32.0769),
  ('2025-03-01'::date, 'B', 'area_3',  6256.00, 30.0769),
  ('2025-03-01'::date, 'C', 'area_3',  6256.00, 30.0769),
  -- 01 Mar 2026 – 28 Feb 2027   (the determination currently in force)
  ('2026-03-01'::date, 'A', 'area_1',  8184.00, 39.3462),
  ('2026-03-01'::date, 'B', 'area_1',  7607.00, 36.5721),
  ('2026-03-01'::date, 'C', 'area_1',  7003.00, 33.6683),
  ('2026-03-01'::date, 'A', 'area_3',  7142.00, 34.3365),
  ('2026-03-01'::date, 'B', 'area_3',  6726.00, 32.3365),
  ('2026-03-01'::date, 'C', 'area_3',  6726.00, 32.3365)
)
insert into quote_salary_rates (effective_date, grade_id, area_id, monthly_salary, hourly_rate)
select p.effective_date, g.id, a.id, p.monthly_salary, p.hourly_rate
  from published p
  join quote_grades g on g.code = p.grade_code
  join quote_areas  a on a.code = p.area_code
on conflict (effective_date, grade_id, area_id) do update
   set monthly_salary = excluded.monthly_salary,
       hourly_rate    = excluded.hourly_rate,
       updated_at     = now()
 where quote_salary_rates.monthly_salary is distinct from excluded.monthly_salary
    or quote_salary_rates.hourly_rate    is distinct from excluded.hourly_rate;

commit;

-- Verify — expect 4 periods x 6 rates = 24 rows, none rounded to 2 decimals any more:
--   select effective_date, count(*) from quote_salary_rates group by 1 order by 1;
--   select r.effective_date, g.code, a.code, r.monthly_salary, r.hourly_rate
--     from quote_salary_rates r
--     join quote_grades g on g.id = r.grade_id
--     join quote_areas  a on a.id = r.area_id
--    order by r.effective_date desc, g.code, a.code;
