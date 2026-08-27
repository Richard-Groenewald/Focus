-- Duplicate-engagement cleanup (Focus v7.8.87, Les's report 2026-08-27).
-- Five phantom-failure duplicate pairs (identical lead/date/type/notes, created
-- 0-14s apart). In each pair the row deleted below is the one with NO
-- bookkeeping attached (no stream link, contacts, milestones, supersedes) and
-- ZERO references from other rows (verified 2026-08-27):
--   4066 (dup of 4065, 9 Jul) · 4084 (dup of 4083, 10 Jul)
--   4115 (dup of 4114, 13 Jul) · 4265 (dup of 4266, 3 Aug — here the FIRST row
--   is the orphan; 4266 carries the stream + milestone) · 4430 (dup of 4431,
--   Les's Milco pair, 27 Aug 01:10).
-- Also: 4431's due date becomes 28 Aug — the date Les chose; the saved 25 Sept
-- was the Nurture cadence prefill. Backup: backups/dup_engagements_cleanup_20260827.csv
begin;
delete from engagements where id in (4066, 4084, 4115, 4265, 4430);
update engagements set next_action_date = '2026-08-28'
where id = 4431 and next_action_date = '2026-09-25';
commit;

select id, lead_id, engagement_date, next_action, next_action_date, next_action_done
from engagements where id in (4065, 4083, 4114, 4266, 4431) order by id;
