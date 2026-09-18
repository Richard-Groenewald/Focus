-- Uniform Types (Focus v7.9.64, Richard 2026-09-18: "uniform is individual, and
-- common per post" -- one uniform choice applies to whoever works a post, picked
-- from an admin-managed list rather than typed free text. Idempotent; run on
-- BOTH databases before the code (the client reads quote_posts.uniform_id and
-- the Proposal Builder → Uniform Types admin page as soon as it loads).
--
-- Mirrors quote_standard_post_names exactly (sql/quote_tool_phase_b3.sql):
-- id/name/display_order/active/created_by/created_at/updated_at, statement-level
-- audit like every other quote lookup table since the v7.9.37 conversion, RLS
-- deny-wall per sql/enable_rls_lockdown.sql (every new table's migration must
-- enable it -- CLAUDE.md).
--
-- quote_posts.uniform (TEXT) is replaced by quote_posts.uniform_id (a real FK,
-- like grade_id -- Richard asked for a DROPDOWN, a constrained pick, not typed
-- text). It was never wired to any input anywhere in the app (grep confirms:
-- only ever read back in the printed proposal and copied by Duplicate) and
-- holds zero rows on either database, so there is nothing to migrate off it.

BEGIN;

CREATE TABLE IF NOT EXISTS quote_uniform_types (
  id            BIGSERIAL    PRIMARY KEY,
  name          TEXT         NOT NULL UNIQUE,
  display_order SMALLINT,
  active        BOOLEAN      NOT NULL DEFAULT true,
  created_by    BIGINT       REFERENCES people(id),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- A short starting list -- Richard's own to rename, reorder, retire or add to
-- from Proposal Builder → Uniform Types; nothing here is meant to be final.
INSERT INTO quote_uniform_types (name, display_order) VALUES
  ('Standard',              1),
  ('Formal / No.1 Dress',   2),
  ('Tactical / Response',   3),
  ('Reception / Front of House', 4)
ON CONFLICT (name) DO NOTHING;

ALTER TABLE quote_posts ADD COLUMN IF NOT EXISTS uniform_id BIGINT REFERENCES quote_uniform_types(id);
ALTER TABLE quote_posts DROP COLUMN IF EXISTS uniform;

ALTER TABLE quote_uniform_types ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'quote_uniform_types'::regclass AND tgname = 'audit_ins_quote_uniform_types') THEN
    CREATE TRIGGER audit_ins_quote_uniform_types AFTER INSERT ON quote_uniform_types REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'quote_uniform_types'::regclass AND tgname = 'audit_upd_quote_uniform_types') THEN
    CREATE TRIGGER audit_upd_quote_uniform_types AFTER UPDATE ON quote_uniform_types REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'quote_uniform_types'::regclass AND tgname = 'audit_del_quote_uniform_types') THEN
    CREATE TRIGGER audit_del_quote_uniform_types AFTER DELETE ON quote_uniform_types REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt();
  END IF;
END $$;

COMMIT;

-- Verify
SELECT id, name, active, display_order FROM quote_uniform_types ORDER BY display_order;
SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'quote_posts' AND column_name IN ('uniform', 'uniform_id');
SELECT rowsecurity FROM pg_tables WHERE tablename = 'quote_uniform_types';
SELECT tgname FROM pg_trigger WHERE tgrelid = 'quote_uniform_types'::regclass AND NOT tgisinternal ORDER BY 1;
