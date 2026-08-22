-- Review-and-lock for salary rate versions (2026-08-22). Run on BOTH databases.
--
-- Maker-checker, at Richard's instruction: one senior person enters a determination's values
-- when they become available, and a DIFFERENT senior person formally checks and approves.
--
-- The lifecycle is the status on this row:
--   draft      editable in the grid; the enterer works here, then submits
--   submitted  locked; awaiting review - the approver (holding approve_salary_rates, and NOT
--              the person who submitted) approves, or declines with a note back to draft
--   approved   locked; "Reopen for correction" drops it back to draft and the cycle repeats
--
-- Existing determinations are backfilled as approved: they are the rates in force, captured
-- before this mechanism existed, and making someone re-approve history would be ceremony.
-- The different-person rule is app-layer, like all Focus authorisation.

begin;

create table if not exists quote_rate_versions (
  effective_date date primary key,
  status         text not null default 'draft'
                 check (status in ('draft', 'submitted', 'approved')),
  entered_by     bigint references people(id),
  submitted_by   bigint references people(id),
  submitted_at   timestamptz,
  approved_by    bigint references people(id),
  approved_at    timestamptz,
  note           text,
  updated_at     timestamptz not null default now()
);

do $$ begin
  execute 'create trigger audit_quote_rate_versions after insert or update or delete on quote_rate_versions
           for each row execute function audit_row_change()';
exception when duplicate_object then null; when undefined_function then null; end $$;

-- The checker's right. Grant it to the senior people who approve; entering needs no new
-- permission beyond reaching the screen.
insert into permissions (name, description)
select 'approve_salary_rates',
       'May approve or decline a submitted salary rate version. The approver must be a '
       'different person from the submitter (enforced in the app).'
where not exists (select 1 from permissions where name = 'approve_salary_rates');

-- Backfill: every captured determination is approved history.
insert into quote_rate_versions (effective_date, status, note)
select distinct effective_date, 'approved', 'Historic determination - captured before the review mechanism'
  from quote_salary_rates
on conflict (effective_date) do nothing;

commit;

-- Verify:
--   select * from quote_rate_versions order by effective_date;
--   select name from permissions where name = 'approve_salary_rates';
