-- Interactions dashboard widget (v7.8.13) — three tunable settings.
-- Run on BOTH Dev and Prod before (or with) the v7.8.13 code release; the
-- Settings page PATCHes these keys, so the rows must exist.
--
--   interactions_team_scope       'managers' (default) | 'everyone' — who sees
--                                 the per-person Team view on the widget
--   interactions_weekly_target    interactions per person per week; '' = no target
--   interactions_count_promotion  'true'/'false' — whether the Promote flow's
--                                 auto-engagement counts as a touch

insert into settings (key, value) values
  ('interactions_team_scope', 'managers'),
  ('interactions_weekly_target', ''),
  ('interactions_count_promotion', 'true')
on conflict (key) do nothing;

-- Verify:
--   select key, value from settings where key like 'interactions_%';
