-- Pan African Resources leads filed under the operating mines, Richard 2026-09-30: "file the PAR
-- leads under the mines with sites". PRODUCTION data change, attributed to Claude Code (4128) for
-- Richard (1). Follows sql/link_pan_african_family.sql (the mines already sit under PLC 4153).
-- The eleven Raw leads were on Pan African Resources PLC (4153) with only a typed site_name.
-- Each now points at its mine and a real site; site_name is cleared because the app treats
-- site_id and site_name as mutually exclusive (a typed name is a site not yet materialised).
--   Barberton Mines (4011): four new sites  - 4159 Fairview, 4160 Sheba, 4161 Consort, 4162 BTRP
--   Evander Mines (4041):   six new sites   - 4163 Shaft 8, 4164 Shaft 7, 4165 Egoli, 4166 Kinross,
--                                             4167 Rolspruit/Poplar, 4168 Elikhulu
--   Mogale Tailings Retreatment (4090): 4169 goes on the existing site 40 (the same place as
--                                       contract 4186)
-- Guarded: a site is created only if its org has none of that name; a lead moves only while it
-- is still on 4153 with no site. Re-running changes nothing.
\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('request.headers',
  json_build_object('x-actor-id', '4128', 'x-real-actor-id', '1')::text, true);

CREATE TEMP TABLE par_map (lead_id bigint, org_id bigint, site_name text, province text) ON COMMIT DROP;
INSERT INTO par_map VALUES
  (4159, 4011, 'Barberton - Fairview Mine', 'Mpumalanga'),
  (4160, 4011, 'Barberton - Sheba Mine', 'Mpumalanga'),
  (4161, 4011, 'Barberton - Consort Mine', 'Mpumalanga'),
  (4162, 4011, 'Barberton - Tailings Retreatment Plant (BTRP)', 'Mpumalanga'),
  (4163, 4041, 'Evander - Shaft 8', 'Mpumalanga'),
  (4164, 4041, 'Evander - Shaft 7', 'Mpumalanga'),
  (4165, 4041, 'Evander - Egoli Project', 'Mpumalanga'),
  (4166, 4041, 'Evander - Kinross', 'Mpumalanga'),
  (4167, 4041, 'Evander - Rolspruit/Poplar', 'Mpumalanga'),
  (4168, 4041, 'Evander - Elikhulu Tailings Retreatment Plant', 'Mpumalanga'),
  (4169, 4090, 'Mogale Tailings Retreatment', NULL);   -- existing site 40

INSERT INTO sites (organisation_id, name, province, created_by)
SELECT m.org_id, m.site_name, m.province, 4128
  FROM par_map m
 WHERE NOT EXISTS (SELECT 1 FROM sites s WHERE s.organisation_id = m.org_id AND s.name = m.site_name)
RETURNING id, organisation_id, name;

UPDATE leads l
   SET target_org_id = m.org_id,
       target_org_name = NULL,
       site_id = s.id,
       site_name = NULL
  FROM par_map m
  JOIN sites s ON s.organisation_id = m.org_id AND s.name = m.site_name
 WHERE l.id = m.lead_id AND l.target_org_id = 4153 AND l.site_id IS NULL
RETURNING l.id, l.target_org_id, l.site_id, s.name;

COMMIT;

SELECT l.id, o.name AS organisation, s.name AS site, l.status
  FROM leads l JOIN organisations o ON o.id = l.target_org_id LEFT JOIN sites s ON s.id = l.site_id
 WHERE l.id BETWEEN 4159 AND 4169 ORDER BY o.name, s.name;
