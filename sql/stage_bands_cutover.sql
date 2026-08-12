-- ============================================================================
-- Focus v7.8.48 — Stage bands revision cutover (LEAD_LIFECYCLE_RULES.md 2026-08-12)
-- Hold/Nurture entry no longer requires approval. Any lead_stage_requests rows
-- still PENDING for hold/nurture are executed directly here, carrying their
-- wake date / cadence — the approval they were waiting for no longer exists.
--
-- No schema changes. Run on BOTH DBs (dev + prod) at release. Idempotent:
-- re-running matches no pending rows and does nothing.
--
-- Notes:
-- * Hold entry now downgrades a green Trigger (2) to Weak (1) — "the moment
--   isn't now" — mirrored here for executed holds.
-- * status is written directly (the app normally recomputes it on open, but
--   these leads may not be opened for a while).
-- * Where a lead somehow has more than one pending row of a type, the LATEST
--   request wins; every pending row is still closed out.
-- ============================================================================

BEGIN;

-- Preview what will be executed (informational)
SELECT r.id AS request_id, r.lead_id, r.request_type, r.wake_date, r.cadence_days,
       r.requested_by, r.requested_at
FROM lead_stage_requests r
WHERE r.status = 'pending' AND r.request_type IN ('hold', 'nurture')
ORDER BY r.lead_id, r.requested_at;

-- 1. Execute pending HOLD requests: wake date onto the lead, Trigger 2 -> 1,
--    status Hold. Latest pending request per lead wins.
WITH latest AS (
  SELECT DISTINCT ON (lead_id) lead_id, wake_date
  FROM lead_stage_requests
  WHERE status = 'pending' AND request_type = 'hold'
  ORDER BY lead_id, requested_at DESC
)
UPDATE leads l
SET wake_date     = latest.wake_date,
    trigger_score = CASE WHEN l.trigger_score = 2 THEN 1 ELSE l.trigger_score END,
    status        = 'Hold',
    updated_at    = now()
FROM latest
WHERE l.id = latest.lead_id
  AND l.promoted_at IS NULL AND l.dead_reason IS NULL;

-- 2. Execute pending NURTURE requests: sticky status + cadence. Latest wins.
WITH latest AS (
  SELECT DISTINCT ON (lead_id) lead_id, cadence_days
  FROM lead_stage_requests
  WHERE status = 'pending' AND request_type = 'nurture'
  ORDER BY lead_id, requested_at DESC
)
UPDATE leads l
SET status              = 'Nurture',
    nurture_cadence_days = latest.cadence_days,
    nurture_started_at   = now(),
    updated_at           = now()
FROM latest
WHERE l.id = latest.lead_id
  AND l.promoted_at IS NULL AND l.dead_reason IS NULL
  AND l.status <> 'Hold';   -- a simultaneous pending hold (executed above) outranks nurture

-- 3. Close out ALL pending hold/nurture rows as approved (system decision).
UPDATE lead_stage_requests
SET status          = 'approved',
    decided_at      = now(),
    decision_reason = 'Auto-executed at v7.8.48 cutover — Hold/Nurture entry no longer requires approval'
WHERE status = 'pending' AND request_type IN ('hold', 'nurture');

-- Post-check: how many were executed
SELECT request_type, count(*) AS executed
FROM lead_stage_requests
WHERE decision_reason LIKE 'Auto-executed at v7.8.48 cutover%'
GROUP BY request_type;

COMMIT;
