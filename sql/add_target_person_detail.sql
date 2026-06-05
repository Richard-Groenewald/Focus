-- Contact detail for a lead's free-text target contact person.
--
-- When the target contact is an existing person we link them via
-- target_person_id. When they are NOT yet known, we store the typed name on the
-- lead (target_person_name) and now also their phone/email, deferring creation
-- of the people row until the lead is promoted (mirrors the source_person /
-- referrer pattern in add_source_person_detail.sql). On promote,
-- savePromoteAll() creates the people row from these fields and nulls them out.

ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS target_person_phone text,
  ADD COLUMN IF NOT EXISTS target_person_email text;
