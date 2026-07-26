-- Lead Lifecycle rework — Increment 2 (approval framework + Hold/Nurture entry).
-- Per LEAD_LIFECYCLE_RULES.md. Run on BOTH DBs (dev first).

-- 1) Stage-change requests: owner (or SM) initiates Hold / Nurture; sales
--    management approves. Self-approval collapses to an already-approved row so
--    the audit trail stays complete. Declines record the approver's chosen
--    outcome ('stay' = lead keeps its stage, 'dead' = closed) + mandatory reason.
CREATE TABLE lead_stage_requests (
  id               BIGSERIAL PRIMARY KEY,
  lead_id          BIGINT NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  request_type     TEXT   NOT NULL CHECK (request_type IN ('hold', 'nurture')),
  status           TEXT   NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'declined')),
  wake_date        DATE,              -- hold requests: mandatory wake date
  cadence_days     INTEGER,           -- nurture requests: touch cadence (per lead)
  note             TEXT,              -- requester's optional context
  requested_by     BIGINT REFERENCES people(id),
  requested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_by       BIGINT REFERENCES people(id),
  decided_at       TIMESTAMPTZ,
  decision_reason  TEXT,              -- mandatory on decline
  decline_outcome  TEXT CHECK (decline_outcome IN ('stay', 'dead')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_lead_stage_requests_lead    ON lead_stage_requests(lead_id);
CREATE INDEX idx_lead_stage_requests_pending ON lead_stage_requests(status) WHERE status = 'pending';

-- Audit like the other 17 tables (audit_row_change from sql/add_audit_log.sql).
CREATE TRIGGER audit_lead_stage_requests
  AFTER INSERT OR UPDATE OR DELETE ON lead_stage_requests
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

-- 2) Per-lead Nurture cadence (Q9: recurring cadence set per lead; each reminder
--    creates a next-action obligation — the engagement modal pre-fills the next
--    touch date from this).
ALTER TABLE leads ADD COLUMN nurture_cadence_days INTEGER;
ALTER TABLE leads ADD COLUMN nurture_started_at   TIMESTAMPTZ;

-- NOTE: peer_review_status / peer_review_at / peer_review_by / qualification_demoted
-- columns stay for history, but the app stops writing them — the simulated peer
-- review panel is retired in favour of the real approval flows.
