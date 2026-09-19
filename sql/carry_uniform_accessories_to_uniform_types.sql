-- Carry the four real uniforms into the Uniform Types catalogue (Richard, 2026-09-19).
--
-- "Where do the uniforms come from?" — the Contract Support Items tab on every quote listed
-- Basic / Combat / Executive-Corporate / Specialised uniform at per-officer prices. They were
-- four quote_accessories rows with category = 'uniform' (ids 27-30, created 2026-09-16 with real
-- April-2025 prices, before Uniform Types existed as their own table in v7.9.64/65). No admin
-- page shows that category (the catalogue pages are workforce / contract / service), yet
-- renderContractItemsTab lists every accessory whose category is not 'workforce', so they
-- leaked onto the Contract tab of every quote, priced per officer on a per-contract tab.
-- Nothing referenced them: no post tick, no contract tick, no workforce adjustment, no rule.
--
-- Richard: "carry them". So: the four become quote_uniform_types rows (same code, name,
-- in-use date; display_order continues after the four seeded names, which stay — three posts
-- already picked from them and two carry his own cost rows), their cost history moves across
-- field-for-field into quote_uniform_type_costs, the orphan accessory rows go (their cost rows
-- cascade), and the accessories category check drops 'uniform' so nothing can land there again.
--
-- Backed up first to backups/uniform_accessories_<db>_2026-09-19.csv (+ _costs). Run on BOTH
-- databases. Not idempotent (the codes are unique in quote_uniform_types) — run once.

BEGIN;

INSERT INTO quote_uniform_types (code, name, display_order, active, in_use_date, retired_date, description, created_by, created_at)
  SELECT a.code, a.name,
         (SELECT COALESCE(MAX(display_order), 0) FROM quote_uniform_types) + ROW_NUMBER() OVER (ORDER BY a.display_order, a.id),
         a.active, a.in_use_date, a.retired_date, a.description, a.created_by, a.created_at
    FROM quote_accessories a
   WHERE a.category = 'uniform';

INSERT INTO quote_uniform_type_costs (uniform_type_id, effective_date, acquisition_cost, life_months, monthly_cost, loss_pct_per_year, cost_basis, recovery, note, created_by, created_at)
  SELECT u.id, c.effective_date, c.acquisition_cost, c.life_months, c.monthly_cost, c.loss_pct_per_year, c.cost_basis, c.recovery, c.note, c.created_by, c.created_at
    FROM quote_accessory_costs c
    JOIN quote_accessories a ON a.id = c.accessory_id AND a.category = 'uniform'
    JOIN quote_uniform_types u ON u.code = a.code;

DELETE FROM quote_accessories WHERE category = 'uniform';   -- quote_accessory_costs cascades

ALTER TABLE quote_accessories DROP CONSTRAINT quote_accessories_category_check;
ALTER TABLE quote_accessories ADD CONSTRAINT quote_accessories_category_check
  CHECK (category = ANY (ARRAY['workforce'::text, 'contract'::text, 'service'::text]));

COMMIT;

-- Verify
SELECT u.id, u.code, u.name, u.display_order, u.in_use_date, c.effective_date, c.acquisition_cost, c.life_months, c.cost_basis, c.recovery
  FROM quote_uniform_types u LEFT JOIN quote_uniform_type_costs c ON c.uniform_type_id = u.id
 ORDER BY u.display_order, c.effective_date;
SELECT count(*) AS uniform_accessories_left FROM quote_accessories WHERE name ILIKE '%uniform%';
SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'quote_accessories_category_check';
