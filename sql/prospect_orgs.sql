-- Prospect organisations (Focus v7.8.82) — organisations are born at capture.
-- Run BEFORE deploying the code, on each environment's DB.
-- Idempotent: safe to re-run; already-linked leads and already-created orgs are skipped.
--
-- 1. 'Prospect' joins the client_status vocabulary (capture-born orgs carry it;
--    securing flips it to Active). is_client stays a manual flag — untouched.
alter table organisations drop constraint if exists organisations_client_status_chk;
alter table organisations add constraint organisations_client_status_chk
  check (client_status = any (array['Prospect'::text, 'Active'::text, 'Standing'::text, 'Dormant'::text]));

-- 2. Pass A — open leads whose typed org name exact-matches (normalized) exactly
--    ONE existing organisation (name / trading / legal) link to it. Ambiguous
--    names (matching 2+ orgs) are left as text and appear in the report below.
begin;
with matches as (
  select l.id as lead_id, min(o.id) as org_id, count(distinct o.id) as n
  from leads l
  join organisations o
    on o.home_organisation is not true
   and lower(trim(l.target_org_name)) in (
         lower(trim(o.name)),
         lower(trim(coalesce(o.trading_name, ''))),
         lower(trim(coalesce(o.legal_name, ''))))
  where l.target_org_id is null
    and coalesce(trim(l.target_org_name), '') <> ''
    and l.status in ('New', 'Working', 'Qualified', 'Hold', 'Nurture')
  group by l.id
)
update leads l
set target_org_id = m.org_id, target_org_name = null
from matches m
where l.id = m.lead_id and m.n = 1;

-- 3. Pass B — every remaining distinct typed name on open leads that matches NO
--    existing organisation becomes a Prospect org; its leads then link to it.
with names as (
  select lower(trim(target_org_name)) as norm, min(trim(target_org_name)) as display
  from leads
  where target_org_id is null
    and coalesce(trim(target_org_name), '') <> ''
    and status in ('New', 'Working', 'Qualified', 'Hold', 'Nurture')
  group by 1
)
insert into organisations (name, client_status)
select n.display, 'Prospect'
from names n
where not exists (
  select 1 from organisations o
  where lower(trim(o.name)) = n.norm
     or lower(trim(coalesce(o.trading_name, ''))) = n.norm
     or lower(trim(coalesce(o.legal_name, ''))) = n.norm);

with m as (
  select l.id as lead_id, min(o.id) as org_id, count(distinct o.id) as n
  from leads l
  join organisations o
    on o.client_status = 'Prospect'
   and o.home_organisation is not true
   and lower(trim(o.name)) = lower(trim(l.target_org_name))
  where l.target_org_id is null
    and coalesce(trim(l.target_org_name), '') <> ''
    and l.status in ('New', 'Working', 'Qualified', 'Hold', 'Nurture')
  group by l.id
)
update leads l
set target_org_id = m.org_id, target_org_name = null
from m
where l.id = m.lead_id and m.n = 1;
commit;

-- 4. Report — review the created Prospects (merge near-duplicates with the new
--    Admin → Settings → Merge Organisations tool) and whatever stayed as text.
select 'created prospect' as what, id, name from organisations
where client_status = 'Prospect' order by name;

select 'still free-text (ambiguous or closed)' as what, id, status, target_org_name
from leads
where target_org_id is null and coalesce(trim(target_org_name), '') <> ''
order by status, target_org_name;
