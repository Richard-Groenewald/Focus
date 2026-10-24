-- Beatrix Offsite Control Room (deal 4288), Richard 2026-10-24: "the 'suspended' lead is actually a
-- secured contract". PRODUCTION data change, attributed to Claude Code (4128) for Richard (1).
--
-- What happened (audit_log rows 8824 and 8828): on 2026-10-01 at 11:05 UTC the start-date sweep
-- suspended the deal (Prospect 95% -> Suspended 0%, start date 2026-10-01 had arrived); at 11:44 Richard
-- moved it from Suspended straight to Secured by hand. Nothing cleared suspended_from_stage_id /
-- suspended_probability / suspended_at, and the ledger's last word stayed "Suspended". From v7.10.18 a
-- hand stage change off Suspended clears the columns and logs "Suspension lifted" itself; this file does
-- the same for the one deal that went through before the code did.
-- Guarded: re-running changes nothing. DEV holds no deal with suspended_at set - nothing to do there.
BEGIN;
SELECT set_config('request.headers',
  json_build_object('x-actor-id', '4128', 'x-real-actor-id', '1')::text, true);

UPDATE deals SET suspended_from_stage_id = NULL, suspended_probability = NULL, suspended_at = NULL
 WHERE id = 4288 AND suspended_at IS NOT NULL
   AND stage_id = (SELECT id FROM stages WHERE lower(name) = 'secured' LIMIT 1)
RETURNING id, name, stage_id, suspended_from_stage_id, suspended_probability, suspended_at;

INSERT INTO engagements (deal_id, engagement_date, engagement_type, notes, next_action_done, created_by)
SELECT 4288, DATE '2026-10-01', 'Suspension lifted',
       'Suspension lifted by Richard Groenewald: moved to Secured — now a contract. (Recorded by Claude Code on 2026-10-24; the stage change itself was made on 2026-10-01 at 11:44 UTC, audit_log 8828.)',
       true, 1
 WHERE NOT EXISTS (SELECT 1 FROM engagements WHERE deal_id = 4288 AND engagement_type = 'Suspension lifted');

COMMIT;

SELECT id, name, stage_id, suspended_from_stage_id, suspended_probability, suspended_at FROM deals WHERE id = 4288;
SELECT id, engagement_date, engagement_type, left(notes, 80) FROM engagements WHERE deal_id = 4288 ORDER BY engagement_date, id;
