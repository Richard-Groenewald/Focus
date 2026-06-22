-- Explicit cadence-start anchor on leads (cadence direction #3)
-- ============================================================
-- Replaces the fuzzy "day 0 = earliest interaction / created_at" inference with a
-- stored anchor date. Stamped at promote (when the lead enters the campaign);
-- the ribbon, the engagement-modal pre-fill, and the cockpit Work Queue all read
-- `cadence_started_at` (falling back to created_at for older / form-created leads),
-- so cadence due dates are deterministic and stable across interaction edits.
ALTER TABLE public.leads
  ADD COLUMN IF NOT EXISTS cadence_started_at date;
