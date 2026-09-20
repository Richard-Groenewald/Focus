-- Delete the 'a1' test row from Workforce Support Items (Richard, 2026-09-20: "delete completely a1
-- under workforce support items"). quote_accessories id 26, code a1_45324, created 2026-09-15 while
-- trying the "+ Add" flow; never ticked on a post or a contract, no adjustment, no rule member —
-- only its one cost row, which cascades (quote_accessory_costs ON DELETE CASCADE). Run on BOTH
-- databases on 2026-09-20 as the single statement below; kept here as the record.

DELETE FROM quote_accessories WHERE id = 26 AND name = 'a1' AND category = 'workforce';

-- Verify
SELECT count(*) AS a1_left FROM quote_accessories WHERE name = 'a1';
SELECT count(*) AS orphan_costs FROM quote_accessory_costs c WHERE NOT EXISTS (SELECT 1 FROM quote_accessories a WHERE a.id = c.accessory_id);
