-- ═══════════════════════════════════════════════════════════════════════
-- UNIFY lead_interactions INTO engagements          (2026-06-22)
-- ═══════════════════════════════════════════════════════════════════════
-- One activity table for every context. `engagements` gains lead_id so a row
-- can target a LEAD or a DEAL (exactly one); projects/contracts add columns
-- later. The next-action-maintenance function/trigger is ported off
-- lead_interactions onto engagements, then lead_interactions is dropped.
--
-- Safe to run on dev AND prod: BOTH have 0 engagements and 0 lead_interactions
-- right now, so there is NOTHING to backfill — this is purely structural.
-- Idempotent / transactional.
--
--   ▸ Run order vs code:  add columns FIRST, deploy code, THEN this drops the
--     old table. Since it's one script with no data, running it whole then
--     deploying is fine — old code simply stops being used.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. Structural: engagements becomes the unified interaction table ──────
ALTER TABLE public.engagements
  ADD COLUMN IF NOT EXISTS lead_id                bigint,
  ADD COLUMN IF NOT EXISTS related_interaction_id bigint;

-- An engagement now targets a lead OR a deal — deal_id no longer mandatory.
ALTER TABLE public.engagements ALTER COLUMN deal_id DROP NOT NULL;

-- FKs (ADD CONSTRAINT IF NOT EXISTS isn't supported, so guard each).
DO $$ BEGIN
  ALTER TABLE public.engagements
    ADD CONSTRAINT engagements_lead_id_fkey
    FOREIGN KEY (lead_id) REFERENCES public.leads(id) ON DELETE CASCADE;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.engagements
    ADD CONSTRAINT engagements_related_interaction_id_fkey
    FOREIGN KEY (related_interaction_id) REFERENCES public.engagements(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Exactly one target. Widen to num_nonnull(lead_id, deal_id, project_id,
-- contract_id) = 1 when those columns are added.
DO $$ BEGIN
  ALTER TABLE public.engagements
    ADD CONSTRAINT engagements_one_target_chk CHECK (num_nonnull(lead_id, deal_id) = 1);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS idx_engagements_lead ON public.engagements (lead_id);

-- ── 2. Port next-action maintenance from lead_interactions → engagements ──
-- Keeps leads.next_action / next_action_date in sync from the lead's earliest
-- still-open engagement (the app reads this as the cond-4 cadence signal).
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
   WHERE id = p_lead_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_engagements_refresh_next_action() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.lead_id IS NOT NULL THEN PERFORM refresh_lead_next_action(OLD.lead_id); END IF;
    RETURN OLD;
  END IF;
  IF NEW.lead_id IS NOT NULL THEN PERFORM refresh_lead_next_action(NEW.lead_id); END IF;
  -- Row re-parented between leads: refresh the old lead too.
  IF TG_OP = 'UPDATE' AND OLD.lead_id IS DISTINCT FROM NEW.lead_id AND OLD.lead_id IS NOT NULL THEN
    PERFORM refresh_lead_next_action(OLD.lead_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS engagements_refresh_next_action ON public.engagements;
CREATE TRIGGER engagements_refresh_next_action
  AFTER INSERT OR DELETE OR UPDATE ON public.engagements
  FOR EACH ROW EXECUTE FUNCTION public.trg_engagements_refresh_next_action();

-- ── 3. Retire lead_interactions (0 rows on both DBs — nothing to migrate) ──
DROP TABLE IF EXISTS public.lead_interactions CASCADE;     -- takes its triggers with it
DROP FUNCTION IF EXISTS public.trg_lead_interactions_refresh_next_action();

COMMIT;

-- ── Verification ─────────────────────────────────────────────────────────
SELECT 'lead_interactions gone' AS check,
       CASE WHEN to_regclass('public.lead_interactions') IS NULL THEN 'ok' ELSE 'STILL EXISTS' END AS result
UNION ALL SELECT 'engagements.lead_id',
       CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                          WHERE table_name='engagements' AND column_name='lead_id') THEN 'ok' ELSE 'MISSING' END
UNION ALL SELECT 'one-target CHECK',
       CASE WHEN EXISTS (SELECT 1 FROM information_schema.table_constraints
                          WHERE table_name='engagements' AND constraint_name='engagements_one_target_chk') THEN 'ok' ELSE 'MISSING' END
UNION ALL SELECT 'next-action trigger',
       CASE WHEN EXISTS (SELECT 1 FROM information_schema.triggers
                          WHERE event_object_table='engagements' AND trigger_name='engagements_refresh_next_action') THEN 'ok' ELSE 'MISSING' END;
