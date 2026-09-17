-- Job title / position for the lead's PRIMARY target contact, mirroring
-- source_person_title. Provisional text on the lead (no person until promote);
-- carried into the primary contact's affiliation as job_title on promotion.
alter table leads add column if not exists target_person_title text;
