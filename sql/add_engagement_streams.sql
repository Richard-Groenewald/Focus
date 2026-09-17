-- ============================================================
-- Engagement streams (Focus v7.7.95)
-- Every engagement belongs to a STREAM — a thread of engagements pursuing one
-- objective on a lead or deal. A stream's identity is the id of its first
-- (root) engagement; the root row also carries the editable stream_label.
-- Going forward the app keeps the invariant: a stream has at most one OPEN
-- next action (logging a continuation supersedes the previous one).
--
-- Run on Dev first; run on Prod BEFORE deploying the code that selects the
-- new columns (the dashboard widget names them explicitly).
-- ============================================================

ALTER TABLE engagements ADD COLUMN IF NOT EXISTS stream_id BIGINT REFERENCES engagements(id);
ALTER TABLE engagements ADD COLUMN IF NOT EXISTS stream_label TEXT;
CREATE INDEX IF NOT EXISTS idx_engagements_stream_id ON engagements(stream_id);

-- Backfill runs with triggers off: the audit trigger would log every row and
-- refresh_lead_next_action would fire pointlessly (we only touch stream cols).
SET session_replication_role = replica;

-- ── Backfill 1: stream membership ────────────────────────────────────────────
-- Existing related_interaction_id chains become streams (root = top of chain);
-- every unchained engagement becomes its own single-row stream.
WITH RECURSIVE chain AS (
  SELECT id, id AS root
  FROM engagements
  WHERE related_interaction_id IS NULL
  UNION ALL
  SELECT e.id, c.root
  FROM engagements e
  JOIN chain c ON e.related_interaction_id = c.id
)
UPDATE engagements e
SET stream_id = c.root
FROM chain c
WHERE e.id = c.id AND e.stream_id IS NULL;

-- Safety net: rows whose related_interaction_id points at a deleted row.
UPDATE engagements SET stream_id = id WHERE stream_id IS NULL;

-- ── Backfill 2: label the stream roots ───────────────────────────────────────
-- Same category rule the Engagement History view uses (_engHistCat).
UPDATE engagements
SET stream_label = 'Outreach'
WHERE id = stream_id AND lead_id IS NOT NULL AND stream_label IS NULL;

UPDATE engagements e
SET stream_label = CASE
    WHEN d.stage_id IN (5,7,8) AND ss.is_recurring = false THEN 'Project'
    WHEN d.stage_id IN (5,7,8)                             THEN 'Contract'
    ELSE 'Sales'
  END
FROM deals d
LEFT JOIN service_sub ss ON ss.id = d.service_sub_id
WHERE e.deal_id = d.id AND e.id = e.stream_id AND e.stream_label IS NULL;

-- ── Backfill 3: de-duplicate labels within a parent ──────────────────────────
-- Second and later same-labelled streams on one lead/deal get a " #n" suffix.
WITH numbered AS (
  SELECT id,
         ROW_NUMBER() OVER (PARTITION BY lead_id, deal_id, stream_label ORDER BY id) AS rn
  FROM engagements
  WHERE id = stream_id
)
UPDATE engagements e
SET stream_label = e.stream_label || ' #' || n.rn
FROM numbered n
WHERE e.id = n.id AND n.rn > 1;

SET session_replication_role = DEFAULT;

NOTIFY pgrst, 'reload schema';
