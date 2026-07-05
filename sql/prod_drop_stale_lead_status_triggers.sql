-- PROD-ONLY cleanup (2026-07-05): retire the old DB-side lead status engine.
--
-- v7.6.99 (2026-06-22) merged lead_interactions into engagements, dropped the
-- table, and moved lead status derivation into the app (computeLeadStatus in
-- index.html — the payload writes status/working_at/qualified_at directly).
-- Dev lost these triggers in that migration; PROD kept them. Since the table
-- drop, refresh_lead_status() has thrown 42P01 ("relation lead_interactions
-- does not exist") whenever it ran:
--   • leads_refresh_status fires on UPDATE of fit/trigger_score/access/capacity/
--     dead_reason/wake_date/promoted_at → every qualification-dot change on prod
--     failed the whole PATCH (visible error).
--   • lead_red_flags_refresh_status fires on red-flag insert/delete → red-flag
--     saves failed silently (the app try/catches those).
-- The function's logic is obsolete anyway (all-green ⇒ Qualified without the
-- est-value/service checks; Working ⇒ any interaction — both superseded).
--
-- Idempotent. Brings prod to parity with dev (which has none of these).

drop trigger  if exists leads_refresh_status          on leads;
drop trigger  if exists lead_red_flags_refresh_status on lead_red_flags;

drop function if exists trg_leads_refresh_status();
drop function if exists trg_lead_red_flags_refresh_status();
drop function if exists trg_lead_interactions_refresh_status();
drop function if exists refresh_lead_status(bigint);
