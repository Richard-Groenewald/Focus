-- Broadcasts to active users + presence heartbeat (v7.8.35).
-- Run on BOTH databases (prod first at release, per the release recipe).
--
-- broadcasts: admin-composed announcements. Every logged-in session polls this
-- table every 60s and shows live rows as a dismissible top banner ("new version
-- deploying in 5 minutes" etc.). A row is live while ended_at IS NULL and
-- expires_at is in the future; "End now" on the admin page stamps ended_at.
--
-- user_presence: one row per person, upserted by the same 60s poll. Powers the
-- "Active users" panel on Admin -> Settings -> Broadcasts (and pre-release
-- checks). Deliberately NOT audit-triggered: it is heartbeat noise, one write
-- per active user per minute.

CREATE TABLE broadcasts (
  id         BIGSERIAL PRIMARY KEY,
  message    TEXT NOT NULL,
  severity   TEXT NOT NULL DEFAULT 'notice' CHECK (severity IN ('notice', 'urgent')),
  created_by BIGINT REFERENCES people(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  ended_at   TIMESTAMPTZ
);
CREATE INDEX idx_broadcasts_live ON broadcasts(expires_at) WHERE ended_at IS NULL;

CREATE TABLE user_presence (
  person_id    BIGINT PRIMARY KEY REFERENCES people(id),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  app_version  TEXT
);

-- Broadcasts are administrative and worth the audit trail (who told everyone
-- what); the trigger function ships with sql/add_audit_log.sql.
CREATE TRIGGER audit_broadcasts
  AFTER INSERT OR UPDATE OR DELETE ON broadcasts
  FOR EACH ROW EXECUTE FUNCTION audit_row_change();

-- Verify:
--   select * from broadcasts;
--   select * from user_presence;
