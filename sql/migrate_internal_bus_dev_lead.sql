-- Migrate prod lead 4154 "Xone Security - INTERNAL BUS DEV MEETINGS" onto the
-- real structures, then remove the container. (v7.8.51)
--
-- PRODUCTION ONLY. Dev has no lead 4154 (it post-dates the last dev clone) — this
-- script is a no-op there, but there is no reason to run it. Run it AFTER
-- sql/add_engagement_time.sql, and after the v7.8.51 code is live.
--
-- BACKGROUND. Les had nowhere to record time, and no way to say "this was our own
-- work" rather than "this was contact with the client". So she created a lead
-- against Xone itself, pushed it to Qualified with all four dots green so it would
-- stay put, and used it as a timesheet — writing durations into the notes as free
-- text. Eleven engagements, 33.5 hours, 17 July to 18 August 2026.
--
-- The workaround cost: a phantom Qualified lead inside her own contract metrics,
-- and nine "Met with decision maker" milestones recorded against internal meetings
-- with her own Managing Director — a quarter of every milestone of that type in
-- the database, all of it feeding Milestone Pulse and the milestones register.
--
-- WHERE IT ALL GOES. Nothing is discarded except the false milestones:
--   * Focus troubleshooting sessions  -> work project "Focus Development"
--   * Bus Dev project work + minutes  -> work project "Bus Dev Project"
--   * Willowton proposal preparation  -> deal 4286, marked as our own work, so it
--     sits on the pursuit it belongs to WITHOUT posing as contact with the client
--     (that risk is exactly why it was parked on a fake lead in the first place)
--   * durations parsed out of the notes into duration_minutes
--   * the two "Critical Document Prep" milestones ride along with the Willowton
--     rows — those are real and stay
--
-- The 17-item minute of the 10 August meeting (engagement 4338) is the most
-- substantive project record in Focus. It is carried over verbatim.

BEGIN;

-- Engagements 4336 and 4337 are both 22 July, both 90 minutes, near-identical
-- wording — very likely one session logged twice. Both are carried over as-is;
-- confirm with Les afterwards and delete one if it is a duplicate.

-- ── 1. Focus working sessions -> "Focus Development" ─────────────────────────
UPDATE engagements SET
  lead_id          = NULL,
  work_project_id  = (SELECT id FROM work_projects WHERE lower(name) = 'focus development'),
  work_mode        = 'internal',
  duration_minutes = 90
WHERE id IN (4272, 4273, 4336, 4337, 4274, 4275) AND lead_id = 4154;

-- ── 2. Bus Dev project work -> "Bus Dev Project" ─────────────────────────────
-- 4294: "Created company profile x 7 hours"  |  4338: the 90-minute 10 Aug meeting
UPDATE engagements SET
  lead_id          = NULL,
  work_project_id  = (SELECT id FROM work_projects WHERE lower(name) = 'bus dev project'),
  work_mode        = 'internal',
  duration_minutes = 420
WHERE id = 4294 AND lead_id = 4154;

UPDATE engagements SET
  lead_id          = NULL,
  work_project_id  = (SELECT id FROM work_projects WHERE lower(name) = 'bus dev project'),
  work_mode        = 'internal',
  duration_minutes = 90
WHERE id = 4338 AND lead_id = 4154;

-- ── 3. Willowton preparation -> deal 4286, as our own work ───────────────────
-- 4370 "Worked on pre-proposal doc x 7 hours", 4371 "Continued... obtained
-- approval x 7 hours", 4372 "Met to discuss the doc x 120min".
UPDATE engagements SET
  lead_id          = NULL,
  deal_id          = 4286,
  work_mode        = 'internal',
  duration_minutes = 420
WHERE id IN (4370, 4371) AND lead_id = 4154;

UPDATE engagements SET
  lead_id          = NULL,
  deal_id          = 4286,
  work_mode        = 'internal',
  duration_minutes = 120
WHERE id = 4372 AND lead_id = 4154;

-- ── 4. Drop the false sales milestones ───────────────────────────────────────
-- "Met with decision maker" on an internal meeting with our own MD is not a sales
-- milestone. The two "Critical Document Prep" designations on the Willowton rows
-- are legitimate and are deliberately left in place.
DELETE FROM engagement_milestones
WHERE engagement_id IN (4272, 4273, 4274, 4275, 4294, 4336, 4337, 4338, 4372)
  AND milestone_type_id = (SELECT id FROM milestone_types WHERE name = 'Met with decision maker');

-- ── 5. Remove the container ──────────────────────────────────────────────────
-- Guarded: the DELETE only fires once nothing is left hanging off the lead.
-- (engagements.lead_id is ON DELETE CASCADE — deleting it while rows remained
-- would destroy them.)
DELETE FROM leads
WHERE id = 4154
  AND NOT EXISTS (SELECT 1 FROM engagements WHERE lead_id = 4154);

COMMIT;

-- ── Verify (expect: 0, 0, then 11 rows totalling 2010 minutes) ───────────────
-- SELECT count(*) FROM leads WHERE id = 4154;                    -- 0
-- SELECT count(*) FROM engagements WHERE lead_id = 4154;         -- 0
-- SELECT wp.name AS project, e.deal_id, count(*) AS entries, sum(e.duration_minutes) AS minutes
--   FROM engagements e LEFT JOIN work_projects wp ON wp.id = e.work_project_id
--  WHERE e.id IN (4272,4273,4274,4275,4294,4336,4337,4338,4370,4371,4372)
--  GROUP BY 1, 2 ORDER BY 1 NULLS LAST;
-- SELECT sum(duration_minutes) FROM engagements
--  WHERE id IN (4272,4273,4274,4275,4294,4336,4337,4338,4370,4371,4372);   -- 2010 (33.5 h)
