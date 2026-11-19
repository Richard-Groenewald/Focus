-- Decide 10 of the parent/child rework (docs/parent-child/DESIGN.md, Richard 2026-11-01), run on
-- Lesley-Anne's confirmation (2026-11-19): her "pointer" notes on site leads — "See PARENT",
-- "See notes under Parent", "See all engagement under 'SAB - HQ'" — point at the family's HQ lead
-- and record no contact with that site. They were saved client-facing, so each counted as the
-- site lead's own Last Contact (masked today by the family switch; stale contact the day a family
-- is switched off). Retype them to our own work (a touch, never a contact) and recompute the
-- affected leads' own Last Contact from what remains.
--
-- PROD only (DEV is a clone and carries the same ids; harmless there). One attributed,
-- system-marked transaction: the Last Touch triggers skip a system write, the audit rows name
-- Claude Code acting for Richard. Re-runnable: a second run finds no client-facing pointer rows.
-- The ids are the agreed ranges (Clover, Premier, Sasol, SAB); the text test keeps the three real
-- engagements inside them (4381 email, 4388 Frik, 4389 Matla) untouched. 41 rows, 41 leads.
BEGIN;
SELECT set_config('focus.system', 'data-fix', true);
SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);

CREATE TEMP TABLE _ptr ON COMMIT DROP AS
SELECT id, lead_id, engagement_date
  FROM engagements
 WHERE work_mode = 'client'
   AND (id BETWEEN 4260 AND 4269 OR id BETWEEN 4379 AND 4393 OR id BETWEEN 4795 AND 4797 OR id BETWEEN 4831 AND 4847)
   AND notes ~* '^\s*see\y.*\y(parent|hq)\y';

UPDATE engagements SET work_mode = 'internal' WHERE id IN (SELECT id FROM _ptr);

UPDATE leads l
   SET last_touch_date = (SELECT max(e.engagement_date) FROM engagements e WHERE e.lead_id = l.id AND e.work_mode = 'client')
 WHERE l.id IN (SELECT DISTINCT lead_id FROM _ptr);

-- What changed (shown by the SQL editor; the MCP returns the last statement).
SELECT (SELECT count(*) FROM _ptr) AS retyped,
       (SELECT count(DISTINCT lead_id) FROM _ptr) AS leads,
       (SELECT count(*) FROM leads WHERE id IN (SELECT lead_id FROM _ptr) AND last_touch_date IS NULL) AS leads_now_without_contact,
       (SELECT count(*) FROM leads WHERE id IN (SELECT lead_id FROM _ptr) AND last_touch_date IS NOT NULL) AS leads_with_other_contact;
COMMIT;
