-- Lead Lifecycle rework — Increment 3 (Dead oversight + reopen + Executive
-- red-flag review). Per LEAD_LIFECYCLE_RULES.md. Run on BOTH DBs (dev first).
-- Verified before writing: neither DB has any Dead leads or lead_red_flags rows,
-- so no backfill is needed.

-- 1) Dead oversight stamps (Q6: a dead request moves the lead to Dead
--    IMMEDIATELY, where it sits awaiting sales-management oversight — these are
--    null while awaiting, stamped on confirm; an Executive red-flag Kill stamps
--    them directly, Executive outranking sales management).
ALTER TABLE leads ADD COLUMN dead_reviewed_by BIGINT REFERENCES people(id);
ALTER TABLE leads ADD COLUMN dead_reviewed_at TIMESTAMPTZ;

-- 2) dead_reason gains 'red_flag' (Executive Kill verdict closes the lead with
--    the flag preserved on the record).
ALTER TABLE leads DROP CONSTRAINT leads_dead_reason_valid;
ALTER TABLE leads ADD CONSTRAINT leads_dead_reason_valid
  CHECK (dead_reason IS NULL OR dead_reason IN ('not_qualified', 'declined', 'red_flag'));

-- 3) lead_stage_requests grows two request types: 'dead' (the post-hoc oversight
--    row written at decline time) and 'reopen' (SM/Executive reopen, always
--    pre-approved — recorded for the audit trail + Approvals widget).
ALTER TABLE lead_stage_requests DROP CONSTRAINT lead_stage_requests_request_type_check;
ALTER TABLE lead_stage_requests ADD CONSTRAINT lead_stage_requests_request_type_check
  CHECK (request_type IN ('hold', 'nurture', 'dead', 'reopen'));

-- 4) Red-flag review verdicts (Q6b: Executive reviews — Kill or Ignore, reason
--    mandatory; on Ignore the flag can be left visible or cleared. A pending
--    uncleared flag blocks promotion; the lead itself is NOT frozen).
ALTER TABLE lead_red_flags ADD COLUMN review_status TEXT NOT NULL DEFAULT 'pending'
  CHECK (review_status IN ('pending', 'ignored', 'killed'));
ALTER TABLE lead_red_flags ADD COLUMN cleared       BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE lead_red_flags ADD COLUMN reviewed_by   BIGINT REFERENCES people(id);
ALTER TABLE lead_red_flags ADD COLUMN reviewed_at   TIMESTAMPTZ;
ALTER TABLE lead_red_flags ADD COLUMN review_reason TEXT;
