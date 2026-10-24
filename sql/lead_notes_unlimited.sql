-- Focus v7.10.21 (Richard 2026-10-24): "there can be any number of notes, not just 3... add a tick box
-- that says responsible leadership somewhere".
-- Lifts the three-per-lead cap on lead notes (lead_research_interviews.interview_no, v7.10.16) and adds
-- the Responsible leadership tick. Additive, re-runnable, SQL-editor safe. Run on DEV and PROD.
ALTER TABLE lead_research_interviews DROP CONSTRAINT IF EXISTS lead_research_interviews_interview_no_check;
ALTER TABLE lead_research_interviews ADD CONSTRAINT lead_research_interviews_interview_no_check CHECK (interview_no >= 1);
ALTER TABLE lead_research_interviews ADD COLUMN IF NOT EXISTS responsible_leadership BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN lead_research_interviews.interview_no IS 'Note number within the lead (1, 2, 3 …; was capped at 3 until v7.10.21)';
COMMENT ON COLUMN lead_research_interviews.responsible_leadership IS 'Responsible leadership tick (v7.10.21)';
NOTIFY pgrst, 'reload schema';
