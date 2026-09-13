-- Focus v7.9.53 — Workforce Support Items: quote-level adjustments (2026-09-13). Idempotent.
-- Run on BOTH databases, Test first.
--
-- The per-post ticks and the item's cost basis set the RULE total of each workforce support
-- item (per officer / per duty position / per post, summed over the posts that tick it). The
-- quote may depart from that total once per item — add to it, subtract from it, or override
-- it — with a recorded reason. The proposal prices the adjusted total; the posts keep their
-- ticks. One row per (quote, item); removing the adjustment deletes the row.

BEGIN;

CREATE TABLE IF NOT EXISTS quote_workforce_adjustments (
  quote_id     BIGINT      NOT NULL REFERENCES quote_quotes(id) ON DELETE CASCADE,
  accessory_id BIGINT      NOT NULL REFERENCES quote_accessories(id),
  mode         TEXT        NOT NULL CHECK (mode IN ('add','subtract','override')),
  quantity     INTEGER     NOT NULL CHECK (quantity >= 0),
  reason       TEXT        NOT NULL,
  created_by   BIGINT      REFERENCES people(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (quote_id, accessory_id)
);

DO $$ BEGIN
  EXECUTE 'CREATE TRIGGER audit_quote_workforce_adjustments
           AFTER INSERT OR UPDATE OR DELETE ON quote_workforce_adjustments
           FOR EACH ROW EXECUTE FUNCTION audit_row_change()';
EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_function THEN NULL; END $$;

COMMIT;

-- Verify:
--   SELECT column_name FROM information_schema.columns WHERE table_name = 'quote_workforce_adjustments' ORDER BY ordinal_position;
