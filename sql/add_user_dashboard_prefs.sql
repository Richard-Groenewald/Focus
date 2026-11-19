-- v7.10.50 — DASHBOARD PREFERENCES FOLLOW THE LOGIN (Richard, 2026-11-19: a person may order dashboard
-- cards and choose which of the cards their role allows to see — "follow the login").
--
-- One row per person: the personal card order (NULL = the role's standard order) and the cards hidden
-- (empty = none). The role matrix in settings.dashboard_role_widgets still decides what a login MAY see;
-- this row only arranges and hides within that. Read once per session on the first dashboard and
-- written on every change; the browser keeps a mirror for the first paint. Additive, re-runnable,
-- SQL-editor safe; run on BOTH databases, before or after the code (a database without the table keeps
-- the browser-only behaviour).

CREATE TABLE IF NOT EXISTS user_dashboard_prefs (
  person_id       BIGINT       PRIMARY KEY REFERENCES people(id) ON DELETE CASCADE,
  widget_order    JSONB,
  hidden_widgets  JSONB        NOT NULL DEFAULT '[]'::jsonb,
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE user_dashboard_prefs IS 'A person''s dashboard layout: widget_order (NULL = the role''s standard order) and hidden_widgets, within the cards their role allows (settings.dashboard_role_widgets).';

ALTER TABLE user_dashboard_prefs ENABLE ROW LEVEL SECURITY;
GRANT ALL ON user_dashboard_prefs TO service_role;

-- No audit triggers: a layout preference, written on every drag; the audit log is for records.

NOTIFY pgrst, 'reload schema';
