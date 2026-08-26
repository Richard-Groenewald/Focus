-- Retire the 'Note' next action; add 'No Further Action' (Focus v7.8.85,
-- Richard 2026-08-25). Note was seeded 2026-05-22 with the original defaults
-- and became an escape hatch from the mandatory next action — 30 open
-- obligations that committed to nothing. NFA is the honest terminal option:
-- the UI forces due date = today and marks it complete on selection, so it can
-- never sit open. Historical Note rows keep rendering (legacy option handling).
-- Idempotent. Run on BOTH DBs (dev when it next releases).
begin;
update next_actions set active = false, updated_at = now()
where name = 'Note' and active = true;

insert into next_actions (name, description, active, sort_order, applies_to_opportunities, applies_to_leads)
select 'No Further Action',
       'Nothing owed after this engagement — saves as already complete, never an open obligation',
       true, 70, false, true
where not exists (select 1 from next_actions where lower(name) = 'no further action');
commit;

select id, name, active, sort_order, applies_to_leads, applies_to_opportunities
from next_actions order by active desc, sort_order nulls last, id;
