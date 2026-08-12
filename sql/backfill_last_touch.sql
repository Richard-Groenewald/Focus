-- ============================================================================
-- Focus v7.8.48 — Backfill leads.last_touch_date from engagement history
-- The app now recomputes last_touch_date from the lead's newest engagement on
-- every save, but leads whose engagements pre-date the bump bookkeeping (or
-- whose newest engagement was later edited to an older date) carry NULL or a
-- stale value. This sets every lead's last_touch_date to the true maximum
-- engagement date on record (NULL where a lead has no engagements).
--
-- Run on BOTH DBs (dev + prod). Idempotent — safe to re-run any time.
-- ============================================================================

BEGIN;

-- Preview: leads whose stored value disagrees with their engagement history
SELECT l.id, l.last_touch_date AS stored, e.max_date AS actual
FROM leads l
LEFT JOIN (
  SELECT lead_id, max(engagement_date) AS max_date
  FROM engagements
  WHERE lead_id IS NOT NULL
  GROUP BY lead_id
) e ON e.lead_id = l.id
WHERE l.last_touch_date IS DISTINCT FROM e.max_date
ORDER BY l.id;

UPDATE leads l
SET last_touch_date = e.max_date,
    updated_at      = now()
FROM (
  SELECT lead_id, max(engagement_date) AS max_date
  FROM engagements
  WHERE lead_id IS NOT NULL
  GROUP BY lead_id
) e
WHERE e.lead_id = l.id
  AND l.last_touch_date IS DISTINCT FROM e.max_date;

-- Leads with NO engagements at all: clear any stray stored value
UPDATE leads l
SET last_touch_date = NULL,
    updated_at      = now()
WHERE l.last_touch_date IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM engagements e WHERE e.lead_id = l.id);

-- Post-check: remaining mismatches should be zero
SELECT count(*) AS remaining_mismatches
FROM leads l
JOIN (
  SELECT lead_id, max(engagement_date) AS max_date
  FROM engagements
  WHERE lead_id IS NOT NULL
  GROUP BY lead_id
) e ON e.lead_id = l.id
WHERE l.last_touch_date IS DISTINCT FROM e.max_date;

COMMIT;
