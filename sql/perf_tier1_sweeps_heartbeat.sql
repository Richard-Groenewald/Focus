-- Focus v7.9.37 — performance Tier 1, part 4: sweep_leads() and heartbeat()
-- (2026-09-10). Rationale: Tier 1.5 / 2.9 / 2.13 in docs/perf-review/PERFORMANCE_REVIEW.md
-- (findings TRG-A3, LR-02, ATT-2, POLL-1).
--
-- The app calls both through the existing proxy:
--   api('rpc/sweep_leads', 'POST', { p_flip: true })   -> /rest/v1/rpc/sweep_leads
--   api('rpc/heartbeat',   'POST', { p_person_id, p_version })
-- and falls back to its previous behaviour (per-lead PATCHes / PATCH + GET) when a
-- function is absent, so this file can be run before or after the v7.9.37 deploy.
-- Idempotent. Run on Dev first, then prod.

BEGIN;

-- ── heartbeat: presence upsert + live broadcasts in ONE call ─────────────────
-- Replaces PATCH user_presence (+ POST fallback) + GET broadcasts per tick.
-- user_presence.person_id is the primary key (add_broadcasts.sql).
CREATE OR REPLACE FUNCTION public.heartbeat(p_person_id bigint, p_version text)
RETURNS SETOF public.broadcasts
LANGUAGE sql SECURITY DEFINER AS $$
  INSERT INTO public.user_presence (person_id, last_seen_at, app_version)
  VALUES (p_person_id, now(), p_version)
  ON CONFLICT (person_id) DO UPDATE
    SET last_seen_at = excluded.last_seen_at, app_version = excluded.app_version;
  SELECT * FROM public.broadcasts
   WHERE ended_at IS NULL AND expires_at > now()
   ORDER BY created_at DESC;
$$;

-- ── sweep_leads: the New→Working flip and the Hold wake as two set-based
--    statements. Mirrors index.html: sweepNewToWorking, sweepHoldWake,
--    computeLeadStatus and the lead*Complete helpers (v7.9.36). Until now the
--    browser PATCHed one lead per round trip on every register, cockpit and
--    dashboard load. Keep these rules and the JS in step.
--    Returns the changed rows so the page can patch its in-memory list:
--      { "working": [{id, status, working_at}], "woke": [{id, status, working_at, woke_at, wake_date}] }

-- leadNameHasTwoParts: first + last name present.
CREATE OR REPLACE FUNCTION public.lead_name_has_two_parts(s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(array_length(array_remove(regexp_split_to_array(trim(coalesce(s, '')), '\s+'), ''), 1), 0) >= 2
$$;

-- leadHasPhone: at least 7 digits.
CREATE OR REPLACE FUNCTION public.lead_has_phone(p text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 7
$$;

-- leadSourceComplete
CREATE OR REPLACE FUNCTION public.lead_source_complete(l public.leads) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT CASE s.name
    WHEN 'Referral' THEN l.source_person_id IS NOT NULL
         OR (public.lead_name_has_two_parts(l.source_person_name)
             AND (nullif(trim(l.source_person_email), '') IS NOT NULL OR public.lead_has_phone(l.source_person_phone)))
    WHEN 'Client Expansion'   THEN l.source_org_id IS NOT NULL
    WHEN 'Marketing Campaign' THEN l.research_campaign_id IS NOT NULL
    WHEN 'Research Campaign'  THEN l.research_campaign_id IS NOT NULL
    WHEN 'Research'           THEN l.research_campaign_id IS NOT NULL
    WHEN 'Research Study'     THEN l.sales_campaign_id IS NOT NULL
    WHEN 'Sales Campaign'     THEN l.sales_campaign_id IS NOT NULL
    ELSE nullif(trim(l.source_detail), '') IS NOT NULL END
  FROM public.lead_sources s
  WHERE s.id = l.source_id
$$;

-- leadWorkingPrereqsMet(l, null) = source complete AND description AND target contact
CREATE OR REPLACE FUNCTION public.lead_working_prereqs(l public.leads) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT coalesce(public.lead_source_complete(l), false)
     AND nullif(trim(l.description), '') IS NOT NULL
     AND (l.target_person_id IS NOT NULL
          OR (public.lead_name_has_two_parts(l.target_person_name)
              AND (nullif(trim(l.target_person_email), '') IS NOT NULL OR public.lead_has_phone(l.target_person_phone))))
$$;

CREATE OR REPLACE FUNCTION public.sweep_leads(p_flip boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_grace   int;
  v_working jsonb := '[]'::jsonb;
  v_woke    jsonb := '[]'::jsonb;
BEGIN
  -- new_lead_waiting_minutes: the editable grace after a lead becomes Working.
  SELECT coalesce(nullif(trim(value), '')::int, 0) INTO v_grace
    FROM public.settings WHERE key = 'new_lead_waiting_minutes';
  v_grace := coalesce(v_grace, 0);

  -- New → Working (sweepNewToWorking): mandatory fields + a next step + a first engagement.
  IF p_flip THEN
    WITH f AS (
      UPDATE public.leads l
         SET status = 'Working', working_at = coalesce(l.working_at, now()), updated_at = now()
       WHERE l.status = 'New' AND l.dead_reason IS NULL AND l.wake_date IS NULL AND l.promoted_at IS NULL
         AND l.first_engaged_at IS NOT NULL
         AND l.next_action IS NOT NULL AND l.next_action_date IS NOT NULL
         AND public.lead_working_prereqs(l)
      RETURNING l.id, l.status, l.working_at)
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'status', status, 'working_at', working_at)), '[]'::jsonb)
      INTO v_working FROM f;
  END IF;

  -- Hold → awake (sweepHoldWake): wake date reached. Landing stage per computeLeadStatus
  -- with wake_date cleared and working_at = existing or now.
  WITH w AS (
    UPDATE public.leads l
       SET wake_date  = NULL,
           woke_at    = now(),
           working_at = coalesce(l.working_at, now()),
           updated_at = now(),
           status = CASE
             WHEN l.fit = 2 AND l.trigger_score = 2 AND l.access = 2 AND l.capacity = 2
                  AND l.service_major_id IS NOT NULL AND l.service_major_id > 0
                  AND (l.target_org_id IS NOT NULL OR nullif(trim(l.target_org_name), '') IS NOT NULL)
                  AND coalesce(l.qualification_demoted, false) = false                    THEN 'Qualified'
             WHEN now() - coalesce(l.working_at, now()) >= make_interval(mins => v_grace) THEN 'Working'
             WHEN public.lead_working_prereqs(l) AND l.next_action IS NOT NULL
                  AND l.next_action_date IS NOT NULL AND l.first_engaged_at IS NOT NULL   THEN 'Working'
             ELSE 'New' END
     WHERE l.status = 'Hold' AND l.wake_date IS NOT NULL AND l.wake_date <= current_date
       AND l.promoted_at IS NULL AND l.dead_reason IS NULL
    RETURNING l.id, l.status, l.working_at, l.woke_at, l.wake_date)
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'status', status, 'working_at', working_at,
                                               'woke_at', woke_at, 'wake_date', wake_date)), '[]'::jsonb)
    INTO v_woke FROM w;

  RETURN jsonb_build_object('working', v_working, 'woke', v_woke);
END;
$$;

COMMIT;

-- Verify (Dev):
--   SELECT public.sweep_leads(false);   -- wake only: {"working": [], "woke": [...]}
--   SELECT public.sweep_leads();        -- both
--   SELECT * FROM public.heartbeat(<your person id>, 'test');   -- returns live broadcasts; user_presence row updated
--
-- Optional: run the sweep on a schedule as well, so leads flip even when nobody
-- opens the register (pg_cron is available on Supabase):
--   CREATE EXTENSION IF NOT EXISTS pg_cron;
--   SELECT cron.schedule('focus_sweep_leads', '*/10 * * * *', $$SELECT public.sweep_leads()$$);
