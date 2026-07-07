-- Repair (2026-07-07, PROD): restore lead names wiped by the autosave bug fixed in v7.7.78.
--
-- Bug: populateLeadForm() cleared the hidden target-org inputs and only restored
-- them when the lead had a site_id / site_name. For free-text new-org leads with
-- no site, the next autosave (typically the first qualification-dot click)
-- round-tripped the empty input as target_org_name NULL, so the lead's headline
-- disappeared from every list.
--
-- Old values recovered from audit_log (leads UPDATE diffs, 2026-07-05 + 2026-07-07).
-- Guarded: only writes where the name is still missing and no site has since been set.
-- Lead 4039 (Ruyterplaats Mountain Estate) is deliberately excluded — the user
-- already repaired it manually by pointing it at site 65.
--
-- Idempotent: safe to re-run.

begin;

update leads set target_org_name = v.name, updated_at = now()
from (values
  (4026, 'Suikerbos'),
  (4027, 'Huntsman, The'),
  (4028, 'Water Club, The'),
  (4036, 'Bel Aire Estate'),
  (4037, 'Helderberg Village'),
  (4038, 'Clara Anna Fontein')
) as v(id, name)
where leads.id = v.id
  and leads.target_org_name is null
  and leads.target_org_id   is null
  and leads.site_id         is null
  and (leads.site_name is null or leads.site_name = '');

commit;
