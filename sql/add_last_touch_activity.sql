-- sql/add_last_touch_activity.sql — v7.10.24, Richard 2026-10-31: TWO measures on a lead.
--
--   LAST CONTACT = the newest client-facing engagement with the prospect.
--     • leads.last_touch_date keeps holding the lead's OWN newest contact (the app recomputes it from
--       the lead's work_mode = 'client' engagements — bumpLeadLastTouch). Only the label changes.
--     • The organisation FAMILY's latest contact comes from the view v_org_contact (one row per
--       organisation: its newest client-facing engagement on any of its leads, its deals, or the
--       group itself) and the client shares it across sibling leads (leadLastContact).
--
--   LAST TOUCH = the newest human activity on the lead RECORD in Focus: leads.last_touch_at /
--     last_touch_by, kept by triggers. It moves on a content change to the lead row and on any write
--     to one of its child records (an engagement of any work mode, a note, a research note, an
--     estimate, a flag, a decision, a stage or promotion request, a milestone on one of its
--     engagements). It does NOT move on reads, on housekeeping writes (the recomputed contact date,
--     the stage engine's status / working_at / woke_at / nurture_* stamps, updated_at) or on system
--     jobs (sweep_leads sets focus.system; a maintenance script should SELECT set_config('focus.system',
--     'data-fix', true) inside its transaction). Direct SQL without a request actor never touches.
--     Per lead, never shared. An administrator's maintenance edit of the lead row through the app
--     (an organisation merge re-pointing target_org_id) is a content change by a signed-in person and
--     counts like any other; the free-text organisation link trigger and the stage engine mark
--     themselves system writes; a stamp never moves backwards (the lead form's Revert echoes the
--     row as opened).
--
-- Additive, re-runnable, SQL-editor safe (no psql meta-commands). Order: this file, THEN re-run
-- sql/perf_tier2_dashboard_summary.sql (the bundle reads the new column and the view). DEV first,
-- PROD with the release. A client on the previous release ignores the new column and still reads
-- org_touches from the bundle.

-- ── 1. Columns ──────────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.leads ADD COLUMN IF NOT EXISTS last_touch_at timestamptz;
ALTER TABLE public.leads ADD COLUMN IF NOT EXISTS last_touch_by bigint REFERENCES public.people(id);

COMMENT ON COLUMN public.leads.last_touch_date IS
  'LAST CONTACT (own): the lead''s newest client-facing engagement date (work_mode client), recomputed by the app (bumpLeadLastTouch). The family-shared contact is v_org_contact.';
COMMENT ON COLUMN public.leads.last_touch_at IS
  'LAST TOUCH: newest human activity on this lead record in Focus — trigger-maintained (trg_leads_touch, trg_lead_child_touch). Housekeeping and system writes never count.';
COMMENT ON COLUMN public.leads.last_touch_by IS
  'The person (people.id, the request''s x-actor-id) whose activity set last_touch_at.';

-- ── 2. Who is writing ───────────────────────────────────────────────────────────────────────────
-- The acting person comes from the PostgREST request headers the proxy forwards (x-actor-id —
-- the same source the audit log uses). Direct SQL has none → NULL → no touch. A touch is activity by
-- a SIGNED-IN person: an actor without a Focus login (the attribution person maintenance scripts
-- write under, people 4128 "Claude Code" on prod) is not one, so an attributed data fix never
-- touches a lead even if it forgets focus.system.
CREATE OR REPLACE FUNCTION public.focus_actor_id()
RETURNS bigint LANGUAGE plpgsql STABLE SET search_path = pg_catalog, public AS $$
DECLARE v bigint;
BEGIN
  BEGIN
    v := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-actor-id', '')::bigint;
  EXCEPTION WHEN OTHERS THEN v := NULL;
  END;
  IF v IS NULL THEN RETURN NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.system_users su WHERE su.person_id = v) THEN RETURN NULL; END IF;
  RETURN v;
END $$;

-- A system job marks itself for the rest of its transaction:
--   PERFORM set_config('focus.system', '<job>', true);
CREATE OR REPLACE FUNCTION public.focus_is_system_write()
RETURNS boolean LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT coalesce(nullif(current_setting('focus.system', true), ''), '') <> ''
$$;

-- Columns on leads whose change is NOT a touch by itself: the recomputed contact date, the stage
-- engine's stamps (status itself is a consequence — the hand paths that move a stage also write a
-- lead_stage_requests row, a dead_reason, a wake_date, nurture_started_at or promoted_at, each of
-- which counts; nurture_cadence_days is copied onto siblings by group cohesion, so it stays silent;
-- promoted_deal_id is cleared by Deal Administration's delete, while a promotion also writes
-- promoted_at and an engagement), and the two touch columns themselves. Everything else on the
-- row is content — including nurture_started_at, which only the hand Nurture entry and the hand
-- Exit Nurture write, so leaving Nurture by hand counts.
CREATE OR REPLACE FUNCTION public.lead_touch_housekeeping_keys()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = pg_catalog, public AS $$
  SELECT ARRAY['updated_at', 'last_touch_date', 'last_touch_at', 'last_touch_by',
               'status', 'working_at', 'working_eligible_at', 'woke_at', 'first_engaged_at',
               'qualified_at', 'cadence_started_at', 'nurture_cadence_days', 'promoted_deal_id']
$$;

-- ── 3. The lead row: a content change by a person is a touch ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_leads_touch()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor   bigint;
  v_changed boolean;
BEGIN
  IF public.focus_is_system_write() THEN RETURN NEW; END IF;
  v_actor := public.focus_actor_id();
  IF v_actor IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.last_touch_at := coalesce(NEW.last_touch_at, now());
    NEW.last_touch_by := coalesce(NEW.last_touch_by, v_actor);
    RETURN NEW;
  END IF;
  -- Two serialisations and one comparison (a per-key walk cost ~4 ms a row).
  v_changed := (to_jsonb(NEW) - public.lead_touch_housekeeping_keys())
               IS DISTINCT FROM
               (to_jsonb(OLD) - public.lead_touch_housekeeping_keys());
  IF v_changed THEN
    NEW.last_touch_at := now();
    NEW.last_touch_by := v_actor;
  ELSIF NEW.last_touch_at IS DISTINCT FROM OLD.last_touch_at
        AND (NEW.last_touch_at IS NULL OR NEW.last_touch_at < OLD.last_touch_at) THEN
    -- Nothing changed on the row, yet the write carries an older stamp (the lead
    -- form's Revert echoes the row as opened): the stamp never moves backwards.
    NEW.last_touch_at := OLD.last_touch_at;
    NEW.last_touch_by := OLD.last_touch_by;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS leads_touch ON public.leads;
CREATE TRIGGER leads_touch
  BEFORE INSERT OR UPDATE ON public.leads
  FOR EACH ROW EXECUTE FUNCTION public.trg_leads_touch();

-- ── 4. Child records: any write by a person touches the lead they belong to ─────────────────────
CREATE OR REPLACE FUNCTION public.lead_touch(p_lead_id bigint)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_actor bigint;
BEGIN
  IF p_lead_id IS NULL OR public.focus_is_system_write() THEN RETURN; END IF;
  v_actor := public.focus_actor_id();
  IF v_actor IS NULL THEN RETURN; END IF;
  UPDATE public.leads
     SET last_touch_at = now(), last_touch_by = v_actor
   WHERE id = p_lead_id;
END $$;

CREATE OR REPLACE FUNCTION public.trg_lead_child_touch()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
  v_new bigint;
  v_old bigint;
BEGIN
  IF TG_TABLE_NAME = 'engagement_milestones' THEN
    -- the lead sits on the engagement the milestone row points at
    SELECT e.lead_id INTO v_new
      FROM public.engagements e
     WHERE e.id = coalesce((to_jsonb(NEW)->>'engagement_id')::bigint, (to_jsonb(OLD)->>'engagement_id')::bigint);
    v_old := v_new;
  ELSE
    v_new := (to_jsonb(NEW)->>'lead_id')::bigint;   -- NULL on DELETE
    v_old := (to_jsonb(OLD)->>'lead_id')::bigint;   -- NULL on INSERT
  END IF;
  PERFORM public.lead_touch(v_new);
  IF v_old IS DISTINCT FROM v_new THEN PERFORM public.lead_touch(v_old); END IF;
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['engagements', 'lead_description_log', 'lead_research_interviews',
                           'lead_service_estimates', 'lead_red_flags', 'lead_strategic_decisions',
                           'lead_stage_requests', 'promotion_requests', 'engagement_milestones'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', t || '_lead_touch', t);
      EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.trg_lead_child_touch()',
                     t || '_lead_touch', t);
    END IF;
  END LOOP;
END $$;

-- ── 5. The sweep marks itself a system job (same body as sql/perf_tier1_sweeps_heartbeat.sql) ───
CREATE OR REPLACE FUNCTION public.sweep_leads(p_flip boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $function$
DECLARE
  v_grace   int;
  v_working jsonb := '[]'::jsonb;
  v_woke    jsonb := '[]'::jsonb;
BEGIN
  -- v7.10.24: the stage engine's writes are not a touch on the lead (trg_leads_touch).
  PERFORM set_config('focus.system', 'sweep_leads', true);

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
$function$;

-- ── 5b. The free-text organisation link is a consequence, not activity ─────────────────────────
-- When an organisation is created or renamed, the pre-existing trigger (sql/perf_tier1_triggers.sql)
-- re-points every orgless lead whose typed name matches. It runs inside the organisation writer's
-- request, so without a mark it would stamp other people's leads as touched by whoever saved the
-- organisation. Same body as deployed, wrapped in the system mark — saved and restored, so an
-- outer job's mark survives. (The lead the person is saving still gets its touch from their own
-- PATCH of that lead.)
CREATE OR REPLACE FUNCTION public.trg_orgs_link_freetext_leads()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $function$
DECLARE
  v_prev text := coalesce(current_setting('focus.system', true), '');
BEGIN
  PERFORM set_config('focus.system', 'orgs_link_freetext', true);
  UPDATE public.leads
  SET target_org_id   = NEW.id,
      target_org_name = NULL,
      updated_at      = now()
  WHERE target_org_id IS NULL
    AND target_org_name IS NOT NULL
    AND (
      lower(trim(target_org_name)) = lower(trim(NEW.name))
      OR (
        NEW.legal_name IS NOT NULL
        AND lower(trim(target_org_name)) = lower(trim(NEW.legal_name))
      )
    );
  PERFORM set_config('focus.system', v_prev, true);
  RETURN NEW;
END;
$function$;

-- ── 6. The audit log does not record the touch stamp (it is derivable, and every child write
--       would otherwise add a leads row). Same body as sql/audit_log_scrub_credentials.sql plus the
--       two keys beside updated_at.
CREATE OR REPLACE FUNCTION public.audit_stmt()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_actor bigint;
  v_real  bigint;
begin
  -- Actor from the PostgREST request headers (absent for direct SQL) — once per statement.
  begin
    v_actor := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-actor-id', '')::bigint;
  exception when others then v_actor := null;
  end;
  begin
    v_real := nullif(nullif(current_setting('request.headers', true), '')::json->>'x-real-actor-id', '')::bigint;
  exception when others then v_real := null;
  end;
  if v_real is not null and v_real = v_actor then v_real := null; end if;

  if tg_op = 'INSERT' then
    insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, row_data)
    select v_actor, v_real, tg_table_name, nullif(to_jsonb(n)->>'id', '')::bigint, 'INSERT', public.audit_scrub(to_jsonb(n))
      from new_rows n;

  elsif tg_op = 'DELETE' then
    insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, row_data)
    select v_actor, v_real, tg_table_name, nullif(to_jsonb(o)->>'id', '')::bigint, 'DELETE', public.audit_scrub(to_jsonb(o))
      from old_rows o;

  else
    -- Only the fields that actually changed; updated_at alone is noise, skip it — and so is the
    -- touch stamp (v7.10.24: last_touch_at / last_touch_by follow every child write).
    -- Credential columns are dropped from the diff; a diff that held nothing
    -- else (a bare hash rewrite) is not recorded at all.
    insert into public.audit_log (actor_id, real_actor_id, table_name, row_id, op, changes)
    select v_actor, v_real, tg_table_name, nullif(x.nj->>'id', '')::bigint, 'UPDATE', public.audit_scrub(d.changes)
      from (select to_jsonb(n) as nj, to_jsonb(o) as oj
              from new_rows n
              join old_rows o on o.id = n.id) x
      cross join lateral (
        select jsonb_object_agg(k, jsonb_build_object('o', x.oj->k, 'n', x.nj->k)) as changes
          from jsonb_object_keys(x.nj) k
         where k not in ('updated_at', 'last_touch_at', 'last_touch_by')
           and x.nj->k is distinct from x.oj->k) d
     where d.changes is not null
       and public.audit_scrub(d.changes) <> '{}'::jsonb;
  end if;
  return null;
end;
$function$;

-- ── 7. The family's latest contact, one row per organisation ────────────────────────────────────
-- Client-facing only (work_mode internal is "our own work", not contact); a date in the future is
-- a plan, not contact (capped at today); the automatic deal rows (promotion, suspension, proposal
-- withdrawal) are not contact. Every lead and deal counts whatever its status: contact is contact.
-- The client takes the max over the organisation family (ultimate parent and every org under it)
-- while the family's "Group acts as one" switch is on, and marks a contact that sits on another
-- record. The dashboard bundle carries the same rows as org_contacts.
CREATE OR REPLACE VIEW public.v_org_contact AS
WITH c AS (
  SELECT coalesce(l.target_org_id, s.organisation_id) AS org_id,
         e.engagement_date AS d, e.created_at,
         'lead'::text AS via_kind, l.id AS via_id,
         coalesce(nullif(l.site_name, ''), nullif(s.name, ''), nullif(l.target_org_name, ''), o.name, 'Lead #' || l.id) AS via_label
    FROM public.engagements e
    JOIN public.leads l ON l.id = e.lead_id
    LEFT JOIN public.sites s ON s.id = l.site_id
    LEFT JOIN public.organisations o ON o.id = coalesce(l.target_org_id, s.organisation_id)
   WHERE e.engagement_date IS NOT NULL AND e.engagement_date <= current_date
     AND e.work_mode IS DISTINCT FROM 'internal'
  UNION ALL
  SELECT d.org_id, e.engagement_date, e.created_at,
         'deal'::text, d.id, coalesce(nullif(d.name, ''), 'Deal #' || d.id)
    FROM public.engagements e
    JOIN public.deals d ON d.id = e.deal_id
   WHERE e.engagement_date IS NOT NULL AND e.engagement_date <= current_date
     AND e.work_mode IS DISTINCT FROM 'internal'
     AND coalesce(e.engagement_type, '') NOT IN ('Promotion', 'Suspended', 'Restored', 'Suspension lifted', 'Proposal withdrawn')
  UNION ALL
  SELECT e.org_id, e.engagement_date, e.created_at,
         'group'::text, e.org_id, o.name
    FROM public.engagements e
    JOIN public.organisations o ON o.id = e.org_id
   WHERE e.engagement_date IS NOT NULL AND e.engagement_date <= current_date
     AND e.work_mode IS DISTINCT FROM 'internal'
)
SELECT DISTINCT ON (org_id)
       org_id, d AS last_contact, via_kind, via_id, via_label
  FROM c
 WHERE org_id IS NOT NULL
 ORDER BY org_id, d DESC, created_at DESC;

GRANT SELECT ON public.v_org_contact TO service_role;

-- ── 8. Backfill Last Touch from the history we have (only where still empty, so a re-run never
--       clobbers a live value). Sources: audited content changes to the lead row, audited writes to
--       its child tables, the un-audited child rows themselves, and the lead's own creation — each
--       counted only when the actor is a signed-in person (system_users), never an attributed
--       maintenance script (the 2026-10-20 next-action rename touched every lead's next_action under
--       people 4128, which is not activity by anyone).
BEGIN;
SELECT set_config('focus.system', 'backfill', true);
WITH who AS (SELECT DISTINCT person_id FROM public.system_users WHERE person_id IS NOT NULL),
ev AS (
  SELECT a.row_id AS lead_id, a.at, a.actor_id
    FROM public.audit_log a JOIN who ON who.person_id = a.actor_id
   WHERE a.table_name = 'leads'
     AND (a.op = 'INSERT'
          OR (a.op = 'UPDATE'
              AND EXISTS (SELECT 1 FROM jsonb_object_keys(coalesce(a.changes, '{}'::jsonb)) k
                           WHERE k <> ALL (public.lead_touch_housekeeping_keys()))
              -- not the free-text organisation link (target_org_name → NULL as target_org_id is
              -- set, nothing else): a consequence of someone's organisation write, not activity
              AND NOT (a.changes ? 'target_org_name' AND a.changes->'target_org_name'->>'n' IS NULL
                       AND a.changes ? 'target_org_id' AND a.changes->'target_org_id'->>'o' IS NULL
                       AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(a.changes) k2
                                        WHERE k2 NOT IN ('target_org_name', 'target_org_id', 'updated_at')))))
  UNION ALL
  SELECT (a.row_data->>'lead_id')::bigint, a.at, a.actor_id
    FROM public.audit_log a JOIN who ON who.person_id = a.actor_id
   WHERE a.table_name IN ('engagements', 'lead_research_interviews', 'lead_service_estimates',
                          'lead_stage_requests', 'promotion_requests', 'lead_red_flags')
     AND coalesce(a.row_data->>'lead_id', '') ~ '^[0-9]+$'
  UNION ALL
  SELECT e.lead_id, a.at, a.actor_id
    FROM public.audit_log a JOIN who ON who.person_id = a.actor_id
    JOIN public.engagements e ON e.id = a.row_id
   WHERE a.table_name = 'engagements' AND a.op = 'UPDATE' AND e.lead_id IS NOT NULL
  UNION ALL
  SELECT e.lead_id, a.at, a.actor_id
    FROM public.audit_log a JOIN who ON who.person_id = a.actor_id
    JOIN public.engagement_milestones m ON m.id = a.row_id
    JOIN public.engagements e ON e.id = m.engagement_id
   WHERE a.table_name = 'engagement_milestones' AND e.lead_id IS NOT NULL
  UNION ALL
  SELECT d.lead_id, d.created_at, d.created_by FROM public.lead_description_log d
   WHERE d.created_by IS NULL OR d.created_by IN (SELECT person_id FROM who)
  UNION ALL
  SELECT lead_id, created_at, NULL::bigint FROM public.lead_strategic_decisions
  UNION ALL
  SELECT e.lead_id, e.created_at, e.created_by FROM public.engagements e
   WHERE e.lead_id IS NOT NULL AND (e.created_by IS NULL OR e.created_by IN (SELECT person_id FROM who))
  UNION ALL  -- decisions and edits the audit log holds only as diffs: the rows' own stamps
  SELECT r.lead_id, r.decided_at, r.decided_by FROM public.lead_stage_requests r
   WHERE r.decided_at IS NOT NULL AND r.decided_by IN (SELECT person_id FROM who)
  UNION ALL
  SELECT r.lead_id, r.decided_at, r.decided_by FROM public.promotion_requests r
   WHERE r.decided_at IS NOT NULL AND r.decided_by IN (SELECT person_id FROM who)
  UNION ALL
  SELECT f.lead_id, f.reviewed_at, f.reviewed_by FROM public.lead_red_flags f
   WHERE f.reviewed_at IS NOT NULL AND f.reviewed_by IN (SELECT person_id FROM who)
  UNION ALL
  SELECT i.lead_id, i.updated_at, i.updated_by FROM public.lead_research_interviews i
   WHERE i.updated_at IS NOT NULL AND (i.updated_by IS NULL OR i.updated_by IN (SELECT person_id FROM who))
  UNION ALL
  SELECT s.lead_id, s.updated_at, NULL::bigint FROM public.lead_service_estimates s
   WHERE s.updated_at IS NOT NULL
  UNION ALL
  SELECT l.id, l.created_at, l.created_by FROM public.leads l
   WHERE l.created_by IS NULL OR l.created_by IN (SELECT person_id FROM who)
),
best AS (
  SELECT DISTINCT ON (lead_id) lead_id, at, actor_id
    FROM ev
   WHERE lead_id IS NOT NULL AND at IS NOT NULL
   ORDER BY lead_id, at DESC
)
UPDATE public.leads l
   SET last_touch_at = b.at,
       last_touch_by = CASE WHEN EXISTS (SELECT 1 FROM public.people p WHERE p.id = b.actor_id) THEN b.actor_id END
  FROM best b
 WHERE b.lead_id = l.id
   AND l.last_touch_at IS NULL;
COMMIT;

NOTIFY pgrst, 'reload schema';
