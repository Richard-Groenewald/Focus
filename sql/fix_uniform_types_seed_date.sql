-- Fix: the four starter uniform types (sql/add_uniform_types.sql) were seeded
-- with in_use_date = CURRENT_DATE (the day the migration ran, 2026-09-18).
-- pbItemInWindow() correctly judges an item "not yet in use" for any quote
-- dated before its in_use_date -- and EVERY real quote on prod predates
-- today, so all four seeded types were invisible in every post's Uniform
-- dropdown on every existing quote (Richard, 2026-09-18: "dropdown in post
-- not picking up on it", after adding the first real cost to Standard).
-- Not a code bug -- pbItemInWindow does exactly what Accessories/Training
-- rely on it to do; the seed's date was simply wrong for a starter catalogue
-- meant to be usable immediately. Accessories precedent: seeded in_use_date
-- values go back to 2023-10-01, well before any live quote.
--
-- NULL (no known start date -- "always available"), not a fake early date:
-- these are placeholder entries with no real provenance, and pbItemInWindow
-- skips the in_use_date check entirely when it is null. Only rows still at
-- the seeded default are touched, so a type Richard has since edited himself
-- keeps whatever he set. Idempotent; run on BOTH databases.

UPDATE quote_uniform_types
   SET in_use_date = NULL
 WHERE code IN ('standard', 'formal_no1', 'tactical', 'reception')
   AND in_use_date = '2026-09-18';

-- Verify
SELECT id, code, name, in_use_date FROM quote_uniform_types ORDER BY id;
