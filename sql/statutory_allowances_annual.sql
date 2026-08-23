-- Statutory allowances go annual, like salaries (2026-08-23). Run on BOTH databases.
--
-- The admin screen becomes a table per year (version tabs by effective date). A NEW year
-- clones the current items with EMPTY rates - typed when the determination publishes - so
-- rate becomes nullable; NULL renders as a red "missing", never as a figure.
--
-- Obsolescence: retired_date is captured as the LAST ACTIVE date (inclusive) - the item still
-- applies ON that date and stops showing on posts after it. Retired items do not clone into
-- new years.

begin;

alter table quote_statutory_allowances alter column rate drop not null;

commit;

-- Verify:
--   select column_name, is_nullable from information_schema.columns
--    where table_name = 'quote_statutory_allowances' and column_name = 'rate';
