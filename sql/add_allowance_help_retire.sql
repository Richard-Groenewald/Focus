-- Allowance help text + retirement windows (2026-08-23). Run on BOTH databases.
--
-- Every allowance and incentive gains, per Richard: a hover HELP TEXT defined under Human
-- Resources, and a RETIRED date closing its validity window. An item shows on a post only when
-- the quote falls inside [effective_date, retired_date) - judged by the CONTRACT START DATE,
-- falling back to the quote date. The per-post amounts for discretionary allowances and
-- incentives already had a home (rate_amount on the link tables); presence of an amount is
-- what includes the item.

begin;

alter table quote_statutory_allowances
  add column if not exists retired_date date,
  add column if not exists help_text text;
alter table quote_discretionary_allowances
  add column if not exists retired_date date,
  add column if not exists help_text text;
alter table quote_discretionary_incentives
  add column if not exists retired_date date,
  add column if not exists help_text text;

do $$ begin
  execute 'create trigger audit_quote_post_discretionary_allowances
           after insert or update or delete on quote_post_discretionary_allowances
           for each row execute function audit_row_change()';
exception when duplicate_object then null; when undefined_function then null; end $$;
do $$ begin
  execute 'create trigger audit_quote_post_discretionary_incentives
           after insert or update or delete on quote_post_discretionary_incentives
           for each row execute function audit_row_change()';
exception when duplicate_object then null; when undefined_function then null; end $$;

commit;

-- Verify:
--   select column_name from information_schema.columns
--    where table_name = 'quote_statutory_allowances' and column_name in ('retired_date','help_text');
