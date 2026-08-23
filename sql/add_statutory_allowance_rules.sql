-- Statutory allowance auto-rules + per-post ticks (2026-08-23). Run on BOTH databases.
--
-- Statutory allowances on a proposal post become tick boxes. Some tick THEMSELVES from the
-- shift schedule: Richard's rule for this round is that a post whose schedule includes a shift
-- CROSSING MIDNIGHT carries the Night Shift allowance. Which allowance carries which rule is
-- admin data, not code - the lookup gains an auto_rule field edited under Human Resources.
--
-- An auto tick can be overridden, but never silently: unticking a rule-applied allowance
-- requires a typed reason, stored on the link row and shown amber in the editor. The shape
-- leaves room for a formal validation step later ("possibly a validation request") without
-- another migration: the override row already carries who, when and why.

begin;

-- ── 1. The rule, on the allowance ────────────────────────────────────────────
alter table quote_statutory_allowances
  add column if not exists auto_rule text not null default 'none';
do $$ begin
  alter table quote_statutory_allowances
    add constraint quote_statutory_allowances_auto_rule_check
    check (auto_rule in ('none', 'night_shift'));
exception when duplicate_object then null; end $$;

-- Night Shift is the shift-derived one in the current data; every effective-dated row of the
-- code carries the rule, so a future rate row inherits it.
update quote_statutory_allowances set auto_rule = 'night_shift' where code = 'night_shift';

-- ── 2. The tick, on the post link ────────────────────────────────────────────
-- state 'on'  = ticked (manually, or an auto tick that was materialised)
-- state 'off' = an AUTO tick overridden away - override_reason says why, created_by says who.
alter table quote_post_statutory_allowances
  add column if not exists state text not null default 'on',
  add column if not exists override_reason text,
  add column if not exists created_by bigint references people(id);
do $$ begin
  alter table quote_post_statutory_allowances
    add constraint quote_post_statutory_allowances_state_check
    check (state in ('on', 'off'));
exception when duplicate_object then null; end $$;

do $$ begin
  execute 'create trigger audit_quote_post_statutory_allowances
           after insert or update or delete on quote_post_statutory_allowances
           for each row execute function audit_row_change()';
exception when duplicate_object then null; when undefined_function then null; end $$;

commit;

-- Verify:
--   select code, auto_rule from quote_statutory_allowances group by code, auto_rule order by 1;
--   select string_agg(column_name, ', ') from information_schema.columns
--    where table_name = 'quote_post_statutory_allowances';
