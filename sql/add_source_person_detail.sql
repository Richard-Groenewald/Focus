-- Referrer capture for leads sourced via Referral.
--
-- When the referrer is an existing person we link them via source_person_id.
-- When they are NOT yet known, we store the typed name + contact details on the
-- lead and defer creating the people row until the lead is promoted to an
-- opportunity (mirrors the existing target_person_name deferral). On promote,
-- savePromoteAll() creates the people row from these fields, sets
-- source_person_id, and nulls them out.

ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS source_person_name  text,
  ADD COLUMN IF NOT EXISTS source_person_title text,
  ADD COLUMN IF NOT EXISTS source_person_email text,
  ADD COLUMN IF NOT EXISTS source_person_phone text;
