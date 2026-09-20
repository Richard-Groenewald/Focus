-- Delete the four placeholder uniform types seeded by v7.9.64/65 (Richard, 2026-09-20:
-- "from uniforms, fully delete Standard, Formal, Tactical and Reception previously seeded by you").
--
-- They were starter names — Standard, Formal / No.1 Dress, Tactical / Response, Reception / Front
-- of House — never real Xone uniforms; the four real ones (Basic / Combat / Executive-Corporate /
-- Specialised, carried from the old accessory rows on 2026-09-19) stay. A post still pointing at
-- one loses its pick (quote_posts.uniform_id has a plain FK with no ON DELETE, so it is set NULL
-- first); their cost rows cascade (quote_uniform_type_costs ON DELETE CASCADE). On prod that was
-- post 6 "New Post 1" on sandbox quote 8 (Tactical) and the two R1,000 trial costs Richard entered
-- on Standard and Formal on 2026-09-18. Keyed on the seeded codes, so a real type later renamed to
-- one of these names is untouched. CSV backups in backups/seeded_uniform_types_<db>_2026-09-20*.
-- Run once on BOTH databases; a second run finds nothing and changes nothing.

BEGIN;

UPDATE quote_posts
   SET uniform_id = NULL
 WHERE uniform_id IN (SELECT id FROM quote_uniform_types WHERE code IN ('standard', 'formal_no1', 'tactical', 'reception'));

DELETE FROM quote_uniform_type_costs
 WHERE uniform_type_id IN (SELECT id FROM quote_uniform_types WHERE code IN ('standard', 'formal_no1', 'tactical', 'reception'));

DELETE FROM quote_uniform_types
 WHERE code IN ('standard', 'formal_no1', 'tactical', 'reception');

COMMIT;

-- Verify
SELECT id, code, name, display_order, in_use_date FROM quote_uniform_types ORDER BY display_order, id;
SELECT count(*) AS posts_pointing_nowhere FROM quote_posts p WHERE p.uniform_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM quote_uniform_types u WHERE u.id = p.uniform_id);
SELECT u.name, count(c.id) AS cost_rows FROM quote_uniform_types u LEFT JOIN quote_uniform_type_costs c ON c.uniform_type_id = u.id GROUP BY u.name ORDER BY u.name;
