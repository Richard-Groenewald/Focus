-- Focus v7.9.37 — performance Tier 1, part 2: engagement / organisation triggers
-- (2026-09-10). Idempotent. Run on Dev first, then prod. Rationale: Tier 1.2 and
-- 1.3 in docs/perf-review/PERFORMANCE_REVIEW.md (findings TRG-A2, TRG-1, TRG-A5).
--
-- Before running, list what the database actually has so nothing here surprises you:
--   SELECT tgrelid::regclass, tgname, pg_get_triggerdef(oid)
--     FROM pg_trigger WHERE NOT tgisinternal ORDER BY 1, 2;

BEGIN;

-- ── 1.2  refresh_lead_next_action: fire only when the relevant columns change,
--        and only rewrite the leads row when the derived values actually differ.
--        sql/unify_engagements.sql made it fire on EVERY engagement write and do
--        an unconditional UPDATE leads (new tuple, audit diff, stage-event trigger)
--        even when nothing changed — three lead rewrites per engagement logged.
--        Same SELECT, same result; the trigger function trg_engagements_refresh_next_action
--        is unchanged.
CREATE OR REPLACE FUNCTION public.refresh_lead_next_action(p_lead_id bigint) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_next_action      TEXT;
  v_next_action_date DATE;
BEGIN
  IF p_lead_id IS NULL THEN RETURN; END IF;

  SELECT next_action, next_action_date
    INTO v_next_action, v_next_action_date
  FROM public.engagements
  WHERE lead_id          = p_lead_id
    AND next_action_done = false
    AND next_action      IS NOT NULL
    AND next_action_date IS NOT NULL
  ORDER BY next_action_date ASC, id DESC
  LIMIT 1;

  UPDATE public.leads
     SET next_action = v_next_action, next_action_date = v_next_action_date, updated_at = now()
   WHERE id = p_lead_id
     AND (next_action IS DISTINCT FROM v_next_action
          OR next_action_date IS DISTINCT FROM v_next_action_date);
END;
$$;

DROP TRIGGER IF EXISTS engagements_refresh_next_action ON public.engagements;
CREATE TRIGGER engagements_refresh_next_action
  AFTER INSERT OR DELETE OR UPDATE OF lead_id, next_action, next_action_date, next_action_done
  ON public.engagements
  FOR EACH ROW EXECUTE FUNCTION public.trg_engagements_refresh_next_action();

-- ── 1.3  Default stream_id to the row's own id (a new engagement is the root of
--        its own stream) so the app no longer needs a second write to the row it
--        just inserted. Identity/serial defaults are applied before BEFORE ROW
--        triggers, so NEW.id is available. The self-referencing FK
--        (add_engagement_streams.sql) is satisfied by the row itself.
--        The app (v7.9.37) sends stream_label in the INSERT and only PATCHes
--        stream_id when the returned row still has none — i.e. on a database
--        where this trigger has not been installed.
CREATE OR REPLACE FUNCTION public.engagements_default_stream() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stream_id IS NULL THEN NEW.stream_id := NEW.id; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS engagements_default_stream ON public.engagements;
CREATE TRIGGER engagements_default_stream
  BEFORE INSERT ON public.engagements
  FOR EACH ROW EXECUTE FUNCTION public.engagements_default_stream();

-- ── TRG-A5  orgs_link_freetext_leads: fire only when a name actually changed.
--        The trigger function (schema.sql trg_orgs_link_freetext_leads) scans
--        leads by lower(trim(target_org_name)); perf_tier1_indexes.sql adds the
--        matching expression index. A WHEN clause cannot reference OLD on INSERT,
--        hence one trigger per event.
DROP TRIGGER IF EXISTS orgs_link_freetext_leads ON public.organisations;
DROP TRIGGER IF EXISTS orgs_link_freetext_leads_ins ON public.organisations;
DROP TRIGGER IF EXISTS orgs_link_freetext_leads_upd ON public.organisations;
CREATE TRIGGER orgs_link_freetext_leads_ins
  AFTER INSERT ON public.organisations
  FOR EACH ROW EXECUTE FUNCTION public.trg_orgs_link_freetext_leads();
CREATE TRIGGER orgs_link_freetext_leads_upd
  AFTER UPDATE OF name, legal_name ON public.organisations
  FOR EACH ROW
  WHEN (NEW.name IS DISTINCT FROM OLD.name OR NEW.legal_name IS DISTINCT FROM OLD.legal_name)
  EXECUTE FUNCTION public.trg_orgs_link_freetext_leads();

COMMIT;

-- Verify (Dev): log an engagement on a lead and check
--   SELECT stream_id, id FROM engagements ORDER BY id DESC LIMIT 1;   -- stream_id = id
--   SELECT count(*) FROM audit_log WHERE table_name = 'leads' AND at > now() - interval '1 minute';
--   -- one leads row change per engagement, not three
