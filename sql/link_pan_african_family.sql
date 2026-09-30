-- Pan African Resources family, Richard 2026-09-30: "Mogale, Barberton and Evander ... are all part of
-- Pan African Resources". PRODUCTION data change, attributed to Claude Code (4128) for Richard (1).
--   1. Barberton Mines (4011) and Mogale Tailings Retreatment (4090) become children of
--      Pan African Resources PLC (4153); Evander Mines (4041) already was.
--   2. The empty duplicate "Pan African Resources" (4188, Prospect, nothing references it) is deactivated.
-- Guarded: re-running changes nothing. Dev has no person 4128 - do not run there as-is.
\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('request.headers',
  json_build_object('x-actor-id', '4128', 'x-real-actor-id', '1')::text, true);

UPDATE organisations SET parent_org_id = 4153
 WHERE id IN (4011, 4090) AND parent_org_id IS NULL
RETURNING id, name, parent_org_id;

UPDATE organisations SET active = false
 WHERE id = 4188 AND name = 'Pan African Resources' AND active
RETURNING id, name, active;

COMMIT;

SELECT id, name, parent_org_id, active
  FROM organisations WHERE id IN (4011, 4041, 4090, 4153, 4188) ORDER BY id;
