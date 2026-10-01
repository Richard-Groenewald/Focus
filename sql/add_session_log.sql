-- Sign-in and usage log (v7.9.85), Richard 2026-10-01: "need to keep a basic log on sign ins and the
-- pages visited, and time on line". Until now Focus kept only user_presence.last_seen_at (one row per
-- person, overwritten) and the audit log of CHANGES — a reader who never edits left no trace.
--
--   user_sessions     one row per sign-in attempt. outcome 'ok' rows are sessions: started_at,
--                     last_seen_at, active_seconds (time online), ended_at when the user signs out.
--                     'failed' / 'locked' rows record refused attempts against a real account.
--                     'resumed' rows are sessions the app opened for a token issued before this
--                     log existed. Written by the sb proxy at sign-in (service key) and by
--                     log_activity() from the app.
--   user_page_visits  one row per page shown or record opened (opportunity / lead / quote) in a
--                     session; acting_person_id is set while an admin works as someone else.
--   log_activity()    the app's single write: adds time online, records a visit, closes a session
--                     on sign-out, or opens a 'resumed' session when given none. Time online is the
--                     sum of the gaps between activity beats that are at most 6 minutes apart; the
--                     app beats every 5 minutes while its tab is visible, on refocus and on every
--                     page visit, so a hidden or idle-closed tab stops counting.
--
-- No audit triggers on purpose (a log of the log would double the noise). RLS on, like every table.
-- Additive and re-runnable. Run on DEV and PROD before or with the code; the app and the proxy
-- both stay silent while the tables are absent.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS user_sessions (
  id              BIGSERIAL PRIMARY KEY,
  system_user_id  BIGINT REFERENCES system_users(id) ON DELETE CASCADE,
  person_id       BIGINT REFERENCES people(id),
  outcome         TEXT NOT NULL DEFAULT 'ok' CHECK (outcome IN ('ok', 'failed', 'locked', 'resumed')),
  started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  active_seconds  INTEGER NOT NULL DEFAULT 0,
  ended_at        TIMESTAMPTZ,
  user_agent      TEXT,
  ip              TEXT,
  app_version     TEXT
);
CREATE INDEX IF NOT EXISTS user_sessions_person_started_idx ON user_sessions (person_id, started_at DESC);
CREATE INDEX IF NOT EXISTS user_sessions_started_idx        ON user_sessions (started_at DESC);

CREATE TABLE IF NOT EXISTS user_page_visits (
  id                BIGSERIAL PRIMARY KEY,
  session_id        BIGINT NOT NULL REFERENCES user_sessions(id) ON DELETE CASCADE,
  person_id         BIGINT REFERENCES people(id),
  acting_person_id  BIGINT REFERENCES people(id),
  page              TEXT NOT NULL,
  record_id         BIGINT,
  visited_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS user_page_visits_session_idx ON user_page_visits (session_id, visited_at);
CREATE INDEX IF NOT EXISTS user_page_visits_person_idx  ON user_page_visits (person_id, visited_at DESC);

ALTER TABLE user_sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_page_visits ENABLE ROW LEVEL SECURITY;
GRANT ALL ON user_sessions, user_page_visits TO service_role;
GRANT USAGE, SELECT ON SEQUENCE user_sessions_id_seq, user_page_visits_id_seq TO service_role;

CREATE OR REPLACE FUNCTION log_activity(
  p_session_id        BIGINT,
  p_person_id         BIGINT,
  p_page              TEXT    DEFAULT NULL,
  p_record_id         BIGINT  DEFAULT NULL,
  p_acting_person_id  BIGINT  DEFAULT NULL,
  p_end               BOOLEAN DEFAULT false,
  p_version           TEXT    DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  sid  BIGINT := p_session_id;
  pid  BIGINT;
BEGIN
  -- No session yet (a token issued before this log existed): open a 'resumed' one.
  IF sid IS NULL THEN
    IF p_person_id IS NULL OR p_end THEN RETURN NULL; END IF;
    INSERT INTO user_sessions (system_user_id, person_id, outcome, app_version)
    VALUES ((SELECT id FROM system_users WHERE person_id = p_person_id ORDER BY active DESC, id LIMIT 1),
            p_person_id, 'resumed', p_version)
    RETURNING id INTO sid;
  END IF;

  UPDATE user_sessions
     SET active_seconds = active_seconds
           + CASE WHEN last_seen_at > now() - interval '6 minutes'
                  THEN GREATEST(0, EXTRACT(EPOCH FROM (now() - last_seen_at)))::int ELSE 0 END,
         last_seen_at = now(),
         app_version  = COALESCE(p_version, app_version),
         ended_at     = CASE WHEN p_end THEN now() ELSE ended_at END
   WHERE id = sid AND ended_at IS NULL AND outcome IN ('ok', 'resumed')
  RETURNING person_id INTO pid;
  IF NOT FOUND THEN RETURN NULL; END IF;   -- unknown or already-ended session: the app opens a new one

  IF p_page IS NOT NULL AND NOT p_end THEN
    INSERT INTO user_page_visits (session_id, person_id, acting_person_id, page, record_id)
    VALUES (sid, pid, CASE WHEN p_acting_person_id IS DISTINCT FROM pid THEN p_acting_person_id END,
            left(p_page, 80), p_record_id);
  END IF;
  RETURN sid;
END $$;
GRANT EXECUTE ON FUNCTION log_activity(BIGINT, BIGINT, TEXT, BIGINT, BIGINT, BOOLEAN, TEXT) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verify
SELECT (SELECT count(*) FROM user_sessions) AS sessions, (SELECT count(*) FROM user_page_visits) AS visits,
       (SELECT relrowsecurity FROM pg_class WHERE relname = 'user_sessions') AS rls;
