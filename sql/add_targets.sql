-- Targets (v7.10.05), Richard 2026-10-10: "focus needs to provide for targets, revenue and margin.
-- targets can be set by period (typically fy), company, region, salesperson and potentially others.
-- targets do not need to sum, so the combination of regional targets could be different to the
-- company target etc. targets need to be set in site admin".
--
--   targets   one row per PERIOD and SCOPE carrying a revenue target and / or a margin target.
--             period_type  'fy' (the financial year, settings.fy_start_month) or 'month';
--             period_start / period_end  the first and last day of that period — readers match
--                          an FY target by the FY its period_start falls in and a month target by
--                          its month, so a later change of the FY start month relabels an old row
--                          rather than losing it;
--             scope_type   'company' (scope_id NULL) | 'region' (regions.id) | 'branch'
--                          (branches.id) | 'person' (people.id — a salesperson) | 'service'
--                          (service_major.id — a service family) | 'service_type' (service_sub.id).
--                          scope_id carries no foreign key: the scopes live in different tables
--                          and a retired region or person keeps its target in history. Add a scope
--                          type by widening the CHECK below (and the ALTER that follows it, for a
--                          database that already has the table) and the client's TARGET_SCOPES.
--             revenue_target / margin_target  rand, either may be blank but not both.
--           Nothing rolls up: the company target is its own row, the regional ones theirs, and
--           they need not agree — by design, so no constraint or trigger relates them.
--
-- Set under Site Admin → Settings → Targets (manage_settings); shown on the Revenue Pipeline by its
-- Targets toggle against the figure on the page. Additive and re-runnable; run on DEV and PROD
-- before or with the code (without it the admin page and the toggle say the table is not
-- installed). Runs in the Supabase SQL editor or psql: no psql meta-commands. Attributed to Claude
-- Code acting for Richard.
BEGIN;

SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);

-- 1. Table -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS targets (
  id              BIGSERIAL     PRIMARY KEY,
  period_type     TEXT          NOT NULL CHECK (period_type IN ('fy', 'month')),
  period_start    DATE          NOT NULL,
  period_end      DATE          NOT NULL CHECK (period_end >= period_start),
  scope_type      TEXT          NOT NULL CHECK (scope_type IN ('company', 'region', 'branch', 'person', 'service', 'service_type')),
  scope_id        BIGINT        CHECK ((scope_type = 'company') = (scope_id IS NULL)),
  revenue_target  NUMERIC(18,2) CHECK (revenue_target IS NULL OR revenue_target >= 0),
  margin_target   NUMERIC(18,2) CHECK (margin_target IS NULL OR margin_target >= 0),
  note            TEXT,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
  created_by      BIGINT        REFERENCES people(id),
  updated_at      TIMESTAMPTZ,
  updated_by      BIGINT        REFERENCES people(id),
  CONSTRAINT targets_one_figure CHECK (revenue_target IS NOT NULL OR margin_target IS NOT NULL)
);
COMMENT ON TABLE targets IS 'Revenue and margin targets by period (fy | month) and scope (company | region | branch | person | service | service_type). Rows do not roll up: each scope''s target stands on its own.';

-- v7.10.06 (service scopes): a database that ran the first cut carries the four-value check under
-- the name Postgres gave the column constraint; replace it with the current list. A no-op in effect
-- on a fresh install (the same check is dropped and put back).
ALTER TABLE targets DROP CONSTRAINT IF EXISTS targets_scope_type_check;
ALTER TABLE targets ADD CONSTRAINT targets_scope_type_check
  CHECK (scope_type IN ('company', 'region', 'branch', 'person', 'service', 'service_type'));

-- One target per scope and period. COALESCE so the company rows (scope_id NULL) are unique too.
CREATE UNIQUE INDEX IF NOT EXISTS targets_scope_period_uniq
  ON targets (period_type, period_start, scope_type, COALESCE(scope_id, 0));
CREATE INDEX IF NOT EXISTS targets_period_idx ON targets (period_start, period_end);

-- 2. Row level security, grants, audit --------------------------------------------------------
ALTER TABLE targets ENABLE ROW LEVEL SECURITY;
GRANT ALL ON targets TO service_role;
GRANT USAGE, SELECT ON SEQUENCE targets_id_seq TO service_role;

DO $$
DECLARE t TEXT := 'targets';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_ins_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_ins_%1$I AFTER INSERT ON %1$I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_upd_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_upd_%1$I AFTER UPDATE ON %1$I REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_del_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_del_%1$I AFTER DELETE ON %1$I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verification:
-- SELECT period_type, period_start, scope_type, scope_id, revenue_target, margin_target FROM targets ORDER BY period_start, scope_type, scope_id;
