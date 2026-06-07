-- Promotion eligibility threshold — special (below-full-qualification) request path
-- Run once against the DEV/test Supabase DB (SQL editor). Safe to re-run.
--
-- A fully Qualified lead (all four dimensions Strong + estimate + service) is urged
-- to request promotion the normal way. A lead that is NOT yet fully Qualified but
-- whose green-dimension tally meets a configurable minimum (+ a service category)
-- can instead make a SPECIAL promotion request, which requires a written
-- justification surfaced to the manager who considers it. The real Promote stays
-- gated on full Qualified — unchanged.
--
-- Two settings drive it:
--   promotion_min_green          1..4, default 4 (4 = special path effectively off)
--   promotion_green_counts_weak  'true'/'false', default 'false'
--     (false = only Strong counts toward the tally; full Qualified ALWAYS needs all
--      four Strong regardless of this setting)

-- Request metadata: 'standard' | 'special', plus the special-request justification.
alter table leads add column if not exists promotion_request_type text;
alter table leads add column if not exists promotion_request_note text;

-- Tunable settings (key is UNIQUE — settings_key_key).
insert into settings (key, value) values
  ('promotion_min_green', '4'),
  ('promotion_green_counts_weak', 'false')
on conflict (key) do nothing;

-- Verify:
--   select key, value from settings
--   where key in ('promotion_min_green','promotion_green_counts_weak');
--
--   select id, status, promotion_request_type, promotion_request_note
--   from leads where promotion_request_type is not null
--   order by promotion_requested_at desc;
