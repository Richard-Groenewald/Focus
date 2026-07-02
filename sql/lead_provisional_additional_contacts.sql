-- Additional lead contacts become PROVISIONAL: captured as text on the lead
-- (leads.additional_contacts jsonb) until the lead is promoted, mirroring how the
-- primary target contact is already deferred. No people / affiliations /
-- deal_contacts are created for lead contacts until promotion.
--
-- Reverses the "lead contacts are real people immediately" part of Increment B
-- (v7.7.36). deal_contacts stays the real, person-based, post-promote store.

alter table leads add column if not exists additional_contacts jsonb not null default '[]'::jsonb;

-- Migrate any already-materialised lead-scoped deal_contacts back to provisional
-- JSON on their lead, then remove those rows. The underlying people/affiliations
-- are left in place (harmless — they simply become "known people" again).
update leads l
set additional_contacts = coalesce(l.additional_contacts, '[]'::jsonb) || sub.arr
from (
  select dc.lead_id,
    jsonb_agg(jsonb_build_object(
      'person_id',   dc.person_id,
      'name',        nullif(trim(coalesce(p.first_name,'') || ' ' || coalesce(p.last_name,'')), ''),
      'email',       p.email,
      'phone',       p.phone,
      'job_title',   por.job_title,
      'dmu_role_id', dc.dmu_role_id
    )) as arr
  from deal_contacts dc
  join people p on p.id = dc.person_id
  left join person_organisation_roles por
    on por.person_id = dc.person_id
   and por.org_id = (select target_org_id from leads where id = dc.lead_id)
   and por.end_date is null
  where dc.lead_id is not null
  group by dc.lead_id
) sub
where l.id = sub.lead_id;

delete from deal_contacts where lead_id is not null;
