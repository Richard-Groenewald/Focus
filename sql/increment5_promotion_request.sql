-- Increment 5 — Promote gating + request stub
-- Run once against Supabase (SQL editor). Safe to re-run.
--
-- Promotion is gated to managers/admin (promote_lead). A lead's owner who lacks
-- that permission can instead REQUEST promotion, which stamps these two columns.
-- (Lightweight stub — no notifications yet; managers see the request flag in the
-- list + on the lead. Full approval workflow defers to the notifications design.)

alter table leads add column if not exists promotion_requested_at timestamptz;
alter table leads add column if not exists promotion_requested_by bigint references people(id);

-- Verify:
--   select id, status, promotion_requested_at, promotion_requested_by
--   from leads
--   where promotion_requested_at is not null
--   order by promotion_requested_at desc;
