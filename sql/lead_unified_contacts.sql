-- Unify lead contacts into ONE provisional list: leads.contacts jsonb.
-- The primary contact is simply the entry with is_primary=true; there is no
-- separate "target contact" concept. target_person_* columns are kept as a
-- synced projection of the primary (many downstream readers depend on them:
-- the New->Working gate, promote, list/pipeline views, campaign promote).
--
-- Each entry: { person_id?, name, job_title?, email?, phone?, is_primary, moved? }
--   moved: for an existing person not affiliated to the org — "yes" moves their
--   affiliation on promote, "no" leaves it; null when not applicable.

alter table leads add column if not exists contacts jsonb not null default '[]'::jsonb;

-- Backfill from the current split storage (primary columns + additional_contacts).
update leads set contacts =
  (case
     when target_person_id is not null or coalesce(trim(target_person_name), '') <> '' then
       jsonb_build_array(jsonb_build_object(
         'person_id', target_person_id,
         'name',      target_person_name,
         'job_title', target_person_title,
         'email',     target_person_email,
         'phone',     target_person_phone,
         'is_primary', true,
         'moved',     null))
     else '[]'::jsonb
   end)
  || coalesce(additional_contacts, '[]'::jsonb)
where contacts = '[]'::jsonb;
