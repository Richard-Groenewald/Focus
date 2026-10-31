-- Bug #93 (Lesley-Anne, 2026-10-30): "The Premier Foods PARENT is not connected to the same
-- organisation as the other Premier sites."
--
-- What happened: the PARENT lead 4188 ("Premier FMCG - PARENT") was captured on 2026-08-31 and its
-- typed organisation became the Prospect organisation 4253 "Premier Foods". On 2026-10-30 the twelve
-- site leads 4223-4234 were captured against a new typed name, "Premier FMCG" (the company's name);
-- the capture strip offered "Premier Foods" as a possible match (score 89, under the 90 exact bar),
-- "Use as new" was chosen, and a second organisation 4264 was born. A lead's organisation is frozen
-- once it leaves Raw, so nobody could repoint 4188 in the app.
--
-- Fix: fold 4253 into 4264. 4253 carries nothing of its own (no legal / trading name, website,
-- notes, account, contacts, sites, deals or engagements; only sector 15 Manufacturing, which is not
-- carried - 4264 keeps 8 FMCG & Retail). Soft-retired, not deleted: pickers, the match engine and
-- find-or-create all skip inactive organisations.
--
-- PROD. Attributed to Claude Code (people 4128) for Richard (people 1). Run 2026-10-31 on Richard's
-- "go ahead with data fixes". Idempotent: every statement is guarded by the state it expects.
-- Not done here (Richard's call): the spurious collective birth stamped on 4184 "Reid, The" by the
-- 15-second mis-pick (collective_since 2026-10-30 14:49:02.81+00, group_description copied from a
-- Premier lead); orphan lead 4222 "Premier - Bakery - Salt River"; the duplicated site name on
-- leads 4233 / 4234.

BEGIN;

SELECT set_config('request.headers', '{"x-actor-id":"4128","x-real-actor-id":"1"}', true);

-- 1. The PARENT lead joins the organisation the twelve site leads already use.
UPDATE leads
   SET target_org_id = 4264,
       updated_at    = now()
 WHERE id = 4188
   AND target_org_id = 4253;

-- 2. Retire the capture-born duplicate.
UPDATE organisations
   SET active = false,
       notes  = concat_ws(E'\n', notes, 'Duplicate of Premier FMCG (4264); retired 2026-10-31 (bug #93).')
 WHERE id = 4253
   AND active = true;

-- Checks: expect 4188 -> 4264; 0 leads left on 4253; 4253 inactive, 4264 active with sector 8;
-- 13 leads on 4264.
SELECT 'lead' AS what, id::text AS a, target_org_id::text AS b FROM leads WHERE id = 4188
UNION ALL
SELECT 'left_on_4253', count(*)::text, '' FROM leads WHERE target_org_id = 4253
UNION ALL
SELECT 'org ' || id, name || ' active=' || active, 'sector=' || coalesce(sector_id::text, '')
  FROM organisations WHERE id IN (4253, 4264)
UNION ALL
SELECT 'leads_on_4264', count(*)::text, string_agg(id::text, ',' ORDER BY id) FROM leads WHERE target_org_id = 4264;

COMMIT;
