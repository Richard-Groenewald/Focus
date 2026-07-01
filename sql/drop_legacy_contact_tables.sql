-- CONTRACT phase — retire the legacy contact tables after the app is cut over
-- to deal_contacts (Increment B). Run ONLY once the new index.html is deployed.
-- Pairs with add_person_affiliation_and_deal_contacts.sql (the EXPAND phase).

begin;

-- Safety re-sync: copy any opportunity_contacts rows the still-deployed old app
-- may have written since the expand migration and that aren't in deal_contacts yet.
insert into deal_contacts (person_id, deal_id, dmu_role_id, is_primary, note, created_at)
select oc.person_id, oc.deal_id, oc.dmu_role_id, false, oc.note, oc.created_at
from opportunity_contacts oc
where oc.person_id is not null
  and not exists (
    select 1 from deal_contacts dc
    where dc.deal_id = oc.deal_id and dc.person_id = oc.person_id
  );

-- lead_contacts is empty on Dev; guard anyway. Only rows that already reference a
-- real person can be carried (deal_contacts.person_id is NOT NULL by design).
insert into deal_contacts (person_id, lead_id, is_primary, created_at, created_by)
select lc.person_id, lc.lead_id, coalesce(lc.is_primary, false), lc.created_at, lc.created_by
from lead_contacts lc
where lc.person_id is not null
  and not exists (
    select 1 from deal_contacts dc
    where dc.lead_id = lc.lead_id and dc.person_id = lc.person_id
  );

drop table if exists opportunity_contacts;
drop table if exists lead_contacts;

commit;
