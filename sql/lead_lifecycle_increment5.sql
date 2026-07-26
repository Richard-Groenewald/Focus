-- Lead Lifecycle rework — Increment 5 (timers: Hold wake sweep + New/Working
-- aging escalations + dashboard reminders). Per LEAD_LIFECYCLE_RULES.md.
-- Run on BOTH DBs (dev first).

-- 1) Hold wake marker: stamped when the client-side wake sweep returns a held
--    lead to play (wake_date expired); drives the top-of-dashboard reminder for
--    the owner + sales manager until dismissed or the lead is re-engaged
--    (engagement save clears it).
ALTER TABLE leads ADD COLUMN woke_at TIMESTAMPTZ;

-- 2) Aging thresholds (Q10): a New lead untouched X days / a Working lead with
--    no touch for Y days escalates on the dashboard to its owner + the sales
--    manager. Globals here (blank/0 = escalation off); per-user overrides live
--    in lead_aging_overrides JSON ({ "<personId>": {"new": N, "working": N} }),
--    maintained from Admin → Settings → Lead Lifecycle.
insert into settings (key, value) values
  ('lead_aging_new_days', '7'),
  ('lead_aging_working_days', '14'),
  ('lead_aging_overrides', '{}')
on conflict (key) do nothing;
