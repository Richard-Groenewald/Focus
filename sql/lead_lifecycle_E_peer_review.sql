-- ============================================================================
-- Increment E — Peer review hold  (DEV ONLY — Production frozen)
-- ----------------------------------------------------------------------------
-- A Qualified lead (all-green F/T/A/C + est_value) can be "demoted back to
-- Working" by a peer review. Without a hold it would instantly re-qualify on the
-- next status recompute, so we record the demotion explicitly. The flag is
-- cleared in-app whenever a qualification score is changed, re-opening the path
-- to Qualified. peer_review_status / _at / _by already exist (Increment A).
-- Additive + idempotent.
-- ============================================================================

BEGIN;

ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS qualification_demoted boolean NOT NULL DEFAULT false;

COMMIT;
