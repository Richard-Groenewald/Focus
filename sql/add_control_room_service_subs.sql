-- Control Room service sub-types (v7.8.53).
-- Run on BOTH databases. Prod first — it is the one that is blocked.
--
-- WHY. The "Control Room" service major (id 4) was added with NO sub-types beneath
-- it. The promote wizard fills its required "Service type" dropdown from the subs
-- belonging to the lead's service focus, so every Control Room lead reached that
-- screen with an empty list and could not be promoted at all. 27 prod leads carry
-- that major — Exxaro (Matla + HQ Centurion), SAB HQ, 11 Pan African sites and 12
-- Clover SA sites — so this was about to block a whole book of work, not one deal.
--
-- These are the BUILD side of a control room. The manning side already exists
-- under Manpower as "On-site Control Room" and "Off-site Control Room"; nothing
-- here duplicates those. Margins follow the established pattern: build/upgrade
-- work at the Technology Works Project rate, design at the Advisory rate.
--
-- Ids are explicit so both databases carry the SAME ids. Prod and dev service
-- taxonomies have already drifted once (dev never received the Control Room major
-- at all), and matching ids are what keep a dev clone honest.

-- ── Dev only: the major itself is missing there ──────────────────────────────
-- No-op on prod, where id 4 already exists.
INSERT INTO service_major (id, name, active)
SELECT 4, 'Control Room', TRUE
WHERE NOT EXISTS (SELECT 1 FROM service_major WHERE id = 4);
SELECT setval('service_major_id_seq', GREATEST((SELECT max(id) FROM service_major), 1));

-- ── The sub-types ────────────────────────────────────────────────────────────
INSERT INTO service_sub (id, major_id, name, is_recurring, default_margin, default_duration, active) VALUES
  (9,  4, 'Control Room Build',   FALSE, 25.00, 3, TRUE),
  (10, 4, 'Control Room Upgrade', FALSE, 25.00, 3, TRUE),
  (11, 4, 'Control Room Design',  FALSE, 40.00, 1, TRUE)
ON CONFLICT (id) DO NOTHING;
SELECT setval('service_sub_id_seq', GREATEST((SELECT max(id) FROM service_sub), 1));

-- ── Verify (expect Control Room = 3) ─────────────────────────────────────────
-- SELECT m.name, count(s.id) FILTER (WHERE s.active) AS active_subs
--   FROM service_major m LEFT JOIN service_sub s ON s.major_id = m.id
--  GROUP BY m.name ORDER BY m.name;
