-- ============================================================================
-- Increment B — Retire the server-side lead-status triggers  (DEV ONLY)
-- ----------------------------------------------------------------------------
-- Lead status derivation moves to the app layer (computeLeadStatus in
-- index.html). These triggers would otherwise overwrite the app-computed status
-- using the old rules, so they must be dropped.
--
-- ⚠️ APPLY THIS AT THE SAME TIME AS THE INCREMENT-B CODE DEPLOY — not before.
-- Until the app-layer engine is live, these triggers are the only thing keeping
-- lead status correct.
--
-- DELIBERATELY KEPT: refresh_lead_next_action(bigint) +
-- lead_interactions_refresh_next_action (they maintain leads.next_action /
-- next_action_date, which the app-layer engine reads as the cond-4 signal).
-- ============================================================================

BEGIN;

DROP TRIGGER IF EXISTS lead_interactions_refresh_status ON public.lead_interactions;
DROP TRIGGER IF EXISTS lead_red_flags_refresh_status    ON public.lead_red_flags;
DROP TRIGGER IF EXISTS leads_refresh_status             ON public.leads;

DROP FUNCTION IF EXISTS public.trg_lead_interactions_refresh_status();
DROP FUNCTION IF EXISTS public.trg_lead_red_flags_refresh_status();
DROP FUNCTION IF EXISTS public.trg_leads_refresh_status();
DROP FUNCTION IF EXISTS public.refresh_lead_status(bigint);

COMMIT;
