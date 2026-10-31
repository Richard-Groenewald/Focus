-- Bug #92 (Lesley-Anne, 2026-10-29, deal 4285 Sunset Links HOA - Manpower): "Logging engagements
-- under the Opportunities section somehow looks and feels 'messy'."
--
-- What happened: the Log Engagement modal defaults to "Continue existing" on the deal's newest
-- stream even when no stream has an open action. On 4285 the newest stream was the automatic
-- "Restored" system row 4585 (2026-09-14), so Lesley-Anne's three real engagements - 4800 (dated
-- 2026-10-21), 4820 (dated 2026-10-19) and 4821 (dated 2026-10-27) - were chained under it. That
-- stream has no label, so the tab names it after whatever was logged last ("Email - 4 engagements",
-- holding a Restored row), and 4821's open Call (due 2026-11-06) now keeps the Restored stream as the
-- default for the next engagement too.
--
-- Fix: re-home the three rows on the deal's real Sales stream (root 4259, the Promotion row, which
-- already holds the 2026-08-28 Demo). 4800's chain link pointed at the Restored row; it now points at
-- the Demo, which is what the app would have written had the Sales stream been picked. 4820 and 4821
-- already chain to 4800 and are left as they are. The two system rows (4583 Suspended, 4585 Restored)
-- stay as singletons. Nothing else on the deal changes; the trigger engagements_refresh_next_action
-- does not fire on stream_id / related_interaction_id.
--
-- PROD. Attributed to Claude Code (people 4128) for Richard (people 1). Run 2026-10-31 on Richard's
-- "go ahead with data fixes". Idempotent: guarded by the state it expects. Reversal: set stream_id
-- back to 4585 on the three rows and 4800.related_interaction_id back to 4585.

BEGIN;

SELECT set_config('request.headers', '{"x-actor-id":"4128","x-real-actor-id":"1"}', true);

UPDATE engagements
   SET stream_id = 4259
 WHERE deal_id = 4285
   AND id IN (4800, 4820, 4821)
   AND stream_id = 4585;

UPDATE engagements
   SET related_interaction_id = 4460
 WHERE deal_id = 4285
   AND id = 4800
   AND related_interaction_id = 4585;

-- Check: expect 4259, 4460, 4800, 4820, 4821 on stream 4259 ("Sales"); 4258 on 4258; 4583 and 4585
-- alone on their own ids; 4800 related to 4460.
SELECT id, engagement_date, engagement_type, stream_id, coalesce(stream_label, '') AS label,
       coalesce(related_interaction_id::text, '') AS related,
       coalesce(next_action, '') AS next_action, next_action_done
  FROM engagements
 WHERE deal_id = 4285
 ORDER BY stream_id, engagement_date, id;

COMMIT;
