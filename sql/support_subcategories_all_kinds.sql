-- Focus v7.9.74 — subcategories for every catalogue kind (Richard, 2026-09-19).
-- "make all support items and uniforms and training in proposal builder work exactly like
-- workforce support items": the subcategory table (v7.9.71, sql/add_support_subcategories.sql)
-- already carries a `category`, so contract and service items could file under it; this admits
-- uniform types and training courses too, and gives their tables the same `subcategory_id`
-- filing column quote_accessories has. Plain REFERENCES (RESTRICT), as on quote_accessories:
-- a subcategory that still files a uniform type or a course cannot be deleted.
--
-- No seed rows: Richard builds each family's hierarchy on its admin page (+ Add group,
-- + Subcategory, drag). Re-runnable and additive — old code ignores the column and the check only
-- widens — so it may run before the code. Run on BOTH databases.

BEGIN;

ALTER TABLE quote_support_subcategories DROP CONSTRAINT IF EXISTS quote_support_subcategories_category_check;
ALTER TABLE quote_support_subcategories ADD CONSTRAINT quote_support_subcategories_category_check
  CHECK (category IN ('workforce', 'contract', 'service', 'uniform', 'training'));

ALTER TABLE quote_uniform_types    ADD COLUMN IF NOT EXISTS subcategory_id BIGINT REFERENCES quote_support_subcategories(id);
ALTER TABLE quote_training_courses ADD COLUMN IF NOT EXISTS subcategory_id BIGINT REFERENCES quote_support_subcategories(id);

COMMIT;

-- Verify
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'quote_support_subcategories_category_check';
SELECT table_name, column_name FROM information_schema.columns WHERE column_name = 'subcategory_id' AND table_schema = 'public' ORDER BY 1;
SELECT category, count(*) FROM quote_support_subcategories GROUP BY 1 ORDER BY 1;
