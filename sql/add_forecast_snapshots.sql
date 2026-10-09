-- Forecast snapshots (v7.10.02), Richard 2026-10-09: "go ahead with the snapshot table". The Revenue
-- Pipeline is computed live from today's streams and probabilities, so once a figure is edited the
-- forecast it used to give is gone and nothing can say whether last quarter's forecast was any good.
-- A snapshot freezes the pipeline as it stood at a month end — every deal, every month, exactly as
-- the page values them — so a later month can be held against it.
--
--   forecast_snapshots        one per month end (for_month = the month the snapshot closes, taken
--                             on the 1st of the next month): when, by whom, how (cron | auto |
--                             manual), the horizon and the headline totals.
--   forecast_snapshot_lines   one per deal and month: the deal's attributes AS THEY WERE (owner,
--                             region, branch, service, stage, type, probability), the projected and
--                             recorded figures, and the expected figure the page would have shown.
--                             deal_id carries no foreign key on purpose: a deal deleted later keeps
--                             its place in history.
--
-- take_forecast_snapshot(p_for_month, p_actor_id, p_trigger, p_force) builds one. It mirrors the
-- page's valuation rule (index.html RPP.layers / renderTotStrip): per deal and month the projection
-- is the first non-null opportunity figure over the deal's streams; a month counts as its ACTUAL
-- where one is recorded, else as the projection × the deal's probability (a deal at 100% — secured —
-- counts in full). Expected = actual + secured + weighted potential. An existing snapshot for the
-- month is returned untouched unless p_force, which rebuilds it.
--
-- Scheduling: pg_cron, where the project offers it, runs the function at 00:15 UTC on the 1st of
-- every month for the month just ended. Where it does not, the app takes the missing month's
-- snapshot the first time anyone opens the Revenue Pipeline in a new month (trigger 'auto'), and
-- an administrator can take or re-take one from the page's Forecast history (trigger 'manual').
--
-- RLS on; grants to service_role; statement-level audit on the header table only — the lines are
-- derived rows in their thousands and would only swamp the audit log. Additive and re-runnable; run
-- on DEV and PROD before or with the code (without it the Forecast history button says so and
-- nothing else changes). Attributed to Claude Code acting for Richard.

\set ON_ERROR_STOP on
BEGIN;

SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);

-- 1. Tables ------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS forecast_snapshots (
  id               BIGSERIAL     PRIMARY KEY,
  for_month        TEXT          NOT NULL UNIQUE CHECK (for_month ~ '^[0-9]{4}-[0-9]{2}$'),
  taken_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
  taken_by         BIGINT        REFERENCES people(id),
  trigger          TEXT          NOT NULL DEFAULT 'manual' CHECK (trigger IN ('cron', 'auto', 'manual')),
  deals            INTEGER       NOT NULL DEFAULT 0,
  lines            INTEGER       NOT NULL DEFAULT 0,
  horizon_from     TEXT,
  horizon_to       TEXT,
  expected_revenue NUMERIC(18,2) NOT NULL DEFAULT 0,
  expected_margin  NUMERIC(18,2) NOT NULL DEFAULT 0,
  secured_revenue  NUMERIC(18,2) NOT NULL DEFAULT 0,   -- deals at 100%, months without an actual
  actual_revenue   NUMERIC(18,2) NOT NULL DEFAULT 0,
  note             TEXT
);

CREATE TABLE IF NOT EXISTS forecast_snapshot_lines (
  id                BIGSERIAL     PRIMARY KEY,
  snapshot_id       BIGINT        NOT NULL REFERENCES forecast_snapshots(id) ON DELETE CASCADE,
  deal_id           BIGINT        NOT NULL,
  deal_name         TEXT,
  org_id            BIGINT,
  owner_id          BIGINT,
  region_id         BIGINT,
  branch_id         BIGINT,
  service_major_id  BIGINT,
  service_sub_id    BIGINT,
  stage_id          BIGINT,
  opportunity_type  TEXT,
  probability       INTEGER       NOT NULL DEFAULT 0,
  secured           BOOLEAN       NOT NULL DEFAULT false,
  month             TEXT          NOT NULL CHECK (month ~ '^[0-9]{4}-[0-9]{2}$'),
  projected_revenue NUMERIC(18,2),
  projected_margin  NUMERIC(18,2),
  actual_revenue    NUMERIC(18,2),
  actual_margin     NUMERIC(18,2),
  expected_revenue  NUMERIC(18,2) NOT NULL DEFAULT 0,
  expected_margin   NUMERIC(18,2) NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS forecast_snapshot_lines_snap_idx ON forecast_snapshot_lines (snapshot_id, month);
CREATE INDEX IF NOT EXISTS forecast_snapshot_lines_deal_idx ON forecast_snapshot_lines (deal_id);

-- 2. The function ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION take_forecast_snapshot(
  p_for_month TEXT    DEFAULT NULL,       -- 'YYYY-MM'; NULL = the month just ended (South African time)
  p_actor_id  BIGINT  DEFAULT NULL,
  p_trigger   TEXT    DEFAULT 'manual',
  p_force     BOOLEAN DEFAULT false
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_month TEXT := COALESCE(p_for_month,
                    to_char((date_trunc('month', (now() AT TIME ZONE 'Africa/Johannesburg')) - interval '1 month')::date, 'YYYY-MM'));
  v_id    BIGINT;
BEGIN
  IF v_month !~ '^[0-9]{4}-[0-9]{2}$' THEN RAISE EXCEPTION 'for_month must be YYYY-MM, got %', v_month; END IF;
  IF p_trigger NOT IN ('cron', 'auto', 'manual') THEN RAISE EXCEPTION 'trigger must be cron, auto or manual'; END IF;

  SELECT id INTO v_id FROM forecast_snapshots WHERE for_month = v_month;
  IF v_id IS NOT NULL THEN
    IF NOT p_force THEN RETURN v_id; END IF;      -- history is frozen: a month is taken once
    DELETE FROM forecast_snapshots WHERE id = v_id;   -- the lines cascade
  END IF;

  INSERT INTO forecast_snapshots (for_month, taken_by, trigger) VALUES (v_month, p_actor_id, p_trigger) RETURNING id INTO v_id;

  INSERT INTO forecast_snapshot_lines (snapshot_id, deal_id, deal_name, org_id, owner_id, region_id, branch_id,
      service_major_id, service_sub_id, stage_id, opportunity_type, probability, secured, month,
      projected_revenue, projected_margin, actual_revenue, actual_margin, expected_revenue, expected_margin)
  SELECT v_id, d.id, d.name, d.org_id, d.owner_id, d.region_id, d.branch_id,
         d.service_major_id, d.service_sub_id, d.stage_id, COALESCE(d.opportunity_type, 'new_business'),
         COALESCE(d.probability, 0), COALESCE(d.probability, 0) >= 100, m.month,
         m.proj_rev, m.proj_mar, m.act_rev, m.act_mar,
         COALESCE(m.act_rev, ROUND(COALESCE(m.proj_rev, 0) * COALESCE(d.probability, 0) / 100.0, 2)),
         COALESCE(m.act_mar, ROUND(COALESCE(m.proj_mar, 0) * COALESCE(d.probability, 0) / 100.0, 2))
  FROM deals d
  JOIN (
    -- One row per deal and month over all the deal's streams: the first non-null figure by stream
    -- (the page merges the same way); an actual counts only where its is_actual flag is set.
    SELECT s.deal_id, r.month,
      (array_agg(r.opportunity_revenue ORDER BY r.stream_id, r.id) FILTER (WHERE r.opportunity_revenue IS NOT NULL))[1] AS proj_rev,
      (array_agg(r.opportunity_margin  ORDER BY r.stream_id, r.id) FILTER (WHERE r.opportunity_margin  IS NOT NULL))[1] AS proj_mar,
      (array_agg(r.actual_revenue ORDER BY r.stream_id, r.id) FILTER (WHERE r.is_actual_revenue AND r.actual_revenue IS NOT NULL))[1] AS act_rev,
      (array_agg(r.actual_margin  ORDER BY r.stream_id, r.id) FILTER (WHERE r.is_actual_margin  AND r.actual_margin  IS NOT NULL))[1] AS act_mar
    FROM revenue_stream_months r
    JOIN revenue_streams s ON s.id = r.stream_id
    WHERE r.month ~ '^[0-9]{4}-[0-9]{2}$'
    GROUP BY s.deal_id, r.month
  ) m ON m.deal_id = d.id
  WHERE m.proj_rev IS NOT NULL OR m.proj_mar IS NOT NULL OR m.act_rev IS NOT NULL OR m.act_mar IS NOT NULL;

  UPDATE forecast_snapshots f SET
    deals            = (SELECT count(DISTINCT deal_id)            FROM forecast_snapshot_lines WHERE snapshot_id = v_id),
    lines            = (SELECT count(*)                           FROM forecast_snapshot_lines WHERE snapshot_id = v_id),
    horizon_from     = (SELECT min(month)                         FROM forecast_snapshot_lines WHERE snapshot_id = v_id),
    horizon_to       = (SELECT max(month)                         FROM forecast_snapshot_lines WHERE snapshot_id = v_id),
    expected_revenue = (SELECT COALESCE(sum(expected_revenue), 0) FROM forecast_snapshot_lines WHERE snapshot_id = v_id),
    expected_margin  = (SELECT COALESCE(sum(expected_margin), 0)  FROM forecast_snapshot_lines WHERE snapshot_id = v_id),
    secured_revenue  = (SELECT COALESCE(sum(projected_revenue), 0) FROM forecast_snapshot_lines WHERE snapshot_id = v_id AND secured AND actual_revenue IS NULL),
    actual_revenue   = (SELECT COALESCE(sum(actual_revenue), 0)   FROM forecast_snapshot_lines WHERE snapshot_id = v_id)
  WHERE f.id = v_id;

  RETURN v_id;
END $$;
GRANT EXECUTE ON FUNCTION take_forecast_snapshot(TEXT, BIGINT, TEXT, BOOLEAN) TO service_role;

-- 3. Row level security, grants, audit --------------------------------------------------------
ALTER TABLE forecast_snapshots      ENABLE ROW LEVEL SECURITY;
ALTER TABLE forecast_snapshot_lines ENABLE ROW LEVEL SECURITY;
GRANT ALL ON forecast_snapshots, forecast_snapshot_lines TO service_role;
GRANT USAGE, SELECT ON SEQUENCE forecast_snapshots_id_seq, forecast_snapshot_lines_id_seq TO service_role;

DO $$
DECLARE t TEXT := 'forecast_snapshots';
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

-- 4. Monthly schedule (pg_cron where the project offers it) --------------------------------------
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available (%): the app takes the month-end snapshot on the first visit to the Revenue Pipeline instead', SQLERRM;
    RETURN;
  END;
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'forecast_snapshot_monthly';
  PERFORM cron.schedule('forecast_snapshot_monthly', '15 0 1 * *', $job$ SELECT public.take_forecast_snapshot(NULL, NULL, 'cron') $job$);
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
