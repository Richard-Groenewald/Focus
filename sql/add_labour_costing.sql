-- Labour costing: the manpower calc engine's three premium choices per post (v7.10.28, 2026-11-07).
-- Additive, re-runnable, SQL-editor safe. Run on BOTH databases, before or after the code:
-- a database without these columns prices every post on the derived rule (below) and the
-- Costing section's three ticks are disabled naming this file.
--
-- The engine itself (pbLabourCalc in index.html) reads the rate cards Focus already holds —
-- quote_salary_rates (approved versions), quote_statutory_allowances, quote_extraordinary_hour_rates,
-- quote_shared_salary_options, quote_leave_allocations, quote_calculation_ratios — and needs no
-- other schema. The calculation snapshot goes into quote_snapshots.rate_data as before.
--
-- The three columns mirror the old Xone quote tool's per-post "Overtime / Sunday Time / Public
-- Holidays" ticks (ManpowerDetailHeader.Overtime / SundayOvertime / PublicHoliday). NULL means
-- "follow the rule": overtime off; Sunday premium when the post is staffed on Sundays; public
-- holiday premium when the post is staffed on public holidays. true / false is an explicit choice.
begin;

alter table quote_posts add column if not exists overtime_premium       boolean;
alter table quote_posts add column if not exists sunday_premium         boolean;
alter table quote_posts add column if not exists public_holiday_premium boolean;

comment on column quote_posts.overtime_premium       is 'Price the overtime premium on this post (NULL = rule: off).';
comment on column quote_posts.sunday_premium         is 'Price the Sunday premium on this post (NULL = rule: on when staffed on Sundays).';
comment on column quote_posts.public_holiday_premium is 'Price the public-holiday premium on this post (NULL = rule: on when staffed on public holidays).';

notify pgrst, 'reload schema';
commit;

select column_name, data_type
from information_schema.columns
where table_name = 'quote_posts' and column_name in ('overtime_premium', 'sunday_premium', 'public_holiday_premium')
order by column_name;
