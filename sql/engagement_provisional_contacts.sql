-- Provisional "people involved" for LEAD engagements. A lead's contacts are
-- provisional (no person row until promote), so an engagement can't always link
-- to engagement_people. This holds the involved lead-contacts as refs until the
-- lead is promoted, when they materialise into engagement_people.
--   entry: { cid, person_id?, name }   (cid = the lead contact's stable local id)
-- Deal / standalone engagements continue to use engagement_people directly.
alter table engagements add column if not exists contacts jsonb not null default '[]'::jsonb;
