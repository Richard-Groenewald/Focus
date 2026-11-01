-- sql/org_kind.sql — v7.10.25, Richard 2026-11-01: "parents will mostly be an actual organisation and not
-- just a grouping. grouping should still be allowed by request. If parent is actual company, it should be
-- listed first when displaying." Design: docs/parent-child/DESIGN.md (eleven decisions settled the same day).
--
--   • organisations.org_kind  company (default) | grouping — a grouping is a label with children: it may
--     carry family notes, contacts and a family-level engagement, but never a lead, deal, site or quote,
--     and is never a client. The guard below enforces it where the client's pickers cannot reach.
--   • leads.is_hq — the company-level (head-office) lead that sits beside site leads; explicit, because
--     sites are mostly free text and cannot be derived. Seeded once for Lesley-Anne's PARENT leads.
--   • parent_org_id — the one link; an organisation can no longer be its own parent, nor a cycle.
--   • Birth is retired (the client no longer writes collective_since); the 15 backfill-seeded family
--     notes are cleared; is_parent (never set, read by nothing) is dropped.
--   • trg_orgs_link_freetext_leads skips a grouping: creating or renaming one never re-points a
--     typed-name lead onto it.
--
-- Re-runnable, SQL-editor safe (no psql meta-commands), one transaction, attributed to Claude Code (4128)
-- for Richard (1) with focus.system set so the Last Touch triggers stay silent. The DATA steps (Pan
-- African, the HQ seed, the cleared notes) run ONLY in the run that adds org_kind, so a re-run never
-- undoes a later hand edit (an Admin making 4153 a company again, an HQ tick removed). Safe BEFORE the code:
-- every organisation is a company and the guard refuses nothing that exists. DEV first, PROD with the
-- release. lead_open_bundle's `org` key is to_jsonb(o) and so carries org_kind at once; dashboard_summary
-- needs no change.

BEGIN;
SELECT set_config('request.headers', '{"x-actor-id":"4128","x-real-actor-id":"1"}', true);
SELECT set_config('focus.system', 'migration', true);

-- The run that creates org_kind is the first run; the data steps below are keyed on it.
CREATE TEMP TABLE _ok_run ON COMMIT DROP AS
  SELECT NOT EXISTS (SELECT 1 FROM information_schema.columns
                      WHERE table_schema = 'public' AND table_name = 'organisations' AND column_name = 'org_kind') AS first_run;

-- ── 1. Columns ──────────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.organisations ADD COLUMN IF NOT EXISTS org_kind text NOT NULL DEFAULT 'company';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'organisations_org_kind_check') THEN
    ALTER TABLE public.organisations ADD CONSTRAINT organisations_org_kind_check CHECK (org_kind IN ('company', 'grouping'));
  END IF;
END $$;
COMMENT ON COLUMN public.organisations.org_kind IS
  'company (default): an organisation Xone can sell to, which may also parent others. grouping: a declared label with children — family notes, contacts and a family-level engagement only; never a lead, deal, site, quote or client (org_kind_guard).';

ALTER TABLE public.leads ADD COLUMN IF NOT EXISTS is_hq boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.leads.is_hq IS
  'The company-level (head-office) lead of an organisation that also has site leads. Ticked by hand on the lead form; pinned first in its register band and tagged HQ. Never defaulted.';

-- ── 2. Self-links cleared, then forbidden ────────────────────────────────────────────────────────
UPDATE public.organisations SET parent_org_id = NULL WHERE parent_org_id = id;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'organisations_not_own_parent') THEN
    ALTER TABLE public.organisations ADD CONSTRAINT organisations_not_own_parent CHECK (parent_org_id IS NULL OR parent_org_id <> id);
  END IF;
END $$;

-- ── 3. Data decisions (Richard 2026-11-01), first run only ──────────────────────────────────────
-- The five head-office leads Lesley-Anne has been marking "PARENT" (Decide 4: exactly these; nothing
-- is HQ by default — SAB 4064, Milco 4067, Premier 4188, Sasol 4059, Exxaro 4156). A clone that lacks
-- a row simply skips it.
UPDATE public.leads SET is_hq = true
 WHERE id IN (4064, 4067, 4188, 4059, 4156) AND is_hq = false AND (SELECT first_run FROM _ok_run);

-- Family notes seeded by birth from a first pursuit that was itself a backfill or a template (Decide 8).
UPDATE public.organisations SET group_description = NULL
 WHERE (group_description LIKE 'Forward extension opportunity created by backfill%'
     OR group_description LIKE 'This prospect (and its sites) fulfills Xone''s Ideal Customer definition%')
   AND (SELECT first_run FROM _ok_run);
-- (Pan African Resources PLC becomes a grouping in section 5, once the guard can check that it owns nothing.)

-- ── 4. The guard ────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.org_is_grouping(p_org_id bigint)
RETURNS boolean LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (SELECT 1 FROM public.organisations o WHERE o.id = p_org_id AND o.org_kind = 'grouping')
$$;

-- Rows that would make a grouping a client: refused with a message the app shows as-is.
CREATE OR REPLACE FUNCTION public.trg_org_kind_guard_ref()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
  v_org bigint;
  v_what text := TG_ARGV[0];
BEGIN
  v_org := (to_jsonb(NEW)->>TG_ARGV[1])::bigint;
  IF v_org IS NOT NULL THEN
    -- FOR SHARE: a concurrent "make it a grouping" (NO KEY UPDATE on the organisation row) waits for
    -- this row and re-checks, so a record and a conversion can never both pass at the same moment.
    PERFORM 1 FROM public.organisations o WHERE o.id = v_org AND o.org_kind = 'grouping' FOR SHARE;
    IF FOUND THEN
      RAISE EXCEPTION '% cannot belong to a grouping — pick one of its member organisations', v_what
        USING ERRCODE = 'P0001', HINT = 'org_kind';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS leads_org_kind_guard ON public.leads;
CREATE TRIGGER leads_org_kind_guard BEFORE INSERT OR UPDATE OF target_org_id ON public.leads
  FOR EACH ROW EXECUTE FUNCTION public.trg_org_kind_guard_ref('A lead', 'target_org_id');
DROP TRIGGER IF EXISTS deals_org_kind_guard ON public.deals;
CREATE TRIGGER deals_org_kind_guard BEFORE INSERT OR UPDATE OF org_id ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public.trg_org_kind_guard_ref('An opportunity', 'org_id');
DROP TRIGGER IF EXISTS sites_org_kind_guard ON public.sites;
CREATE TRIGGER sites_org_kind_guard BEFORE INSERT OR UPDATE OF organisation_id ON public.sites
  FOR EACH ROW EXECUTE FUNCTION public.trg_org_kind_guard_ref('A site', 'organisation_id');
DROP TRIGGER IF EXISTS quote_sites_org_kind_guard ON public.quote_sites;
CREATE TRIGGER quote_sites_org_kind_guard BEFORE INSERT OR UPDATE OF organisation_id ON public.quote_sites
  FOR EACH ROW EXECUTE FUNCTION public.trg_org_kind_guard_ref('A quote site', 'organisation_id');

-- The organisation row itself: a grouping is never a client nor the home organisation; the kind may
-- only become grouping while the organisation owns nothing; a parent link may not form a cycle.
CREATE OR REPLACE FUNCTION public.trg_org_kind_guard_org()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
  v_cur  bigint;
  v_seen bigint[] := ARRAY[]::bigint[];
  v_n    int;
BEGIN
  IF NEW.org_kind = 'grouping' THEN
    IF coalesce(NEW.is_client, false) THEN
      RAISE EXCEPTION 'A grouping is never a client — it is a label for its member organisations' USING ERRCODE = 'P0001', HINT = 'org_kind';
    END IF;
    IF coalesce(NEW.home_organisation, false) THEN
      RAISE EXCEPTION 'The home organisation cannot be a grouping' USING ERRCODE = 'P0001', HINT = 'org_kind';
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.org_kind IS DISTINCT FROM 'grouping' THEN
      SELECT (SELECT count(*) FROM public.leads WHERE target_org_id = NEW.id)
           + (SELECT count(*) FROM public.deals WHERE org_id = NEW.id)
           + (SELECT count(*) FROM public.sites WHERE organisation_id = NEW.id)
           + (SELECT count(*) FROM public.quote_sites WHERE organisation_id = NEW.id)
           + (SELECT count(*) FROM public.work_projects WHERE organisation_id = NEW.id)
        INTO v_n;
      IF v_n > 0 THEN
        RAISE EXCEPTION 'This organisation owns % lead(s), opportunity(ies), site(s), quote site(s) or work project(s) — move them to a member organisation before making it a grouping', v_n
          USING ERRCODE = 'P0001', HINT = 'org_kind';
      END IF;
    END IF;
  END IF;
  -- no self-link (the CHECK would refuse it too, but this message reads better) and no cycle
  IF NEW.parent_org_id IS NOT NULL THEN
    IF NEW.parent_org_id = NEW.id THEN
      RAISE EXCEPTION 'An organisation cannot be its own parent' USING ERRCODE = 'P0001', HINT = 'org_kind';
    END IF;
    v_cur := NEW.parent_org_id;
    WHILE v_cur IS NOT NULL LOOP
      IF v_cur = NEW.id THEN
        RAISE EXCEPTION 'That parent sits under this organisation already — a family cannot loop' USING ERRCODE = 'P0001', HINT = 'org_kind';
      END IF;
      IF v_cur = ANY (v_seen) THEN EXIT; END IF;
      v_seen := v_seen || v_cur;
      SELECT parent_org_id INTO v_cur FROM public.organisations WHERE id = v_cur;
    END LOOP;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS organisations_org_kind_guard ON public.organisations;
CREATE TRIGGER organisations_org_kind_guard BEFORE INSERT OR UPDATE OF org_kind, is_client, home_organisation, parent_org_id ON public.organisations
  FOR EACH ROW EXECUTE FUNCTION public.trg_org_kind_guard_org();

-- ── 5. The free-text link never lands a lead on a grouping (same body as deployed, v7.10.24 mark kept)
CREATE OR REPLACE FUNCTION public.trg_orgs_link_freetext_leads()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $function$
DECLARE
  v_prev text := coalesce(current_setting('focus.system', true), '');
BEGIN
  IF NEW.org_kind = 'grouping' THEN RETURN NEW; END IF;
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

-- A grouping made a company again gets the link pass it skipped: the UPDATE trigger also fires on
-- that kind change (the function itself returns at once while the row is a grouping).
DROP TRIGGER IF EXISTS orgs_link_freetext_leads_upd ON public.organisations;
CREATE TRIGGER orgs_link_freetext_leads_upd AFTER UPDATE OF name, legal_name, org_kind ON public.organisations
  FOR EACH ROW WHEN (NEW.name IS DISTINCT FROM OLD.name OR NEW.legal_name IS DISTINCT FROM OLD.legal_name
                     OR (OLD.org_kind = 'grouping' AND NEW.org_kind = 'company'))
  EXECUTE FUNCTION public.trg_orgs_link_freetext_leads();

-- Pan African Resources PLC owns nothing of its own: a grouping, never a client (Decide 1). Runs AFTER
-- the guard, so a lead, deal, site or work project added to it since the design was checked refuses
-- the conversion loudly and rolls the whole run back rather than leaving a grouping that owns records.
UPDATE public.organisations SET org_kind = 'grouping', is_client = false
 WHERE id = 4153 AND name = 'Pan African Resources PLC' AND org_kind <> 'grouping' AND (SELECT first_run FROM _ok_run);

-- ── 6. Retired ──────────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.organisations DROP COLUMN IF EXISTS is_parent;

NOTIFY pgrst, 'reload schema';   -- delivered at commit
COMMIT;

-- Checks (the last statement, so the SQL editor shows them)
SELECT 'kinds' AS what, string_agg(org_kind || '=' || n, ', ') AS detail FROM (SELECT org_kind, count(*) n FROM public.organisations GROUP BY 1) k
UNION ALL SELECT 'self_links', count(*)::text FROM public.organisations WHERE parent_org_id = id
UNION ALL SELECT 'hq_leads', string_agg(id::text, ',' ORDER BY id) FROM public.leads WHERE is_hq
UNION ALL SELECT 'family_notes_left', count(*)::text FROM public.organisations WHERE group_description IS NOT NULL
UNION ALL SELECT 'guards', string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgname LIKE '%org_kind_guard%';
