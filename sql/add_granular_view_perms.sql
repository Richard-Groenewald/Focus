-- Granular record-visibility permissions (v7.7.5)
-- Splits the old single `view_all_records` permission into two independent ones:
--   view_all_leads          -> may see every lead (not just own)
--   view_all_opportunities  -> may see every deal/opportunity (not just own)
-- and RETIRES view_all_records.
--
-- Default grants (per decision 2026-06-22):
--   Manager -> both     |  Sales -> leads only  |  others -> neither
--
-- Name-based & idempotent. Run on Dev DB first, then prod per the sync recipe.
-- NB: assumes role names 'Manager' and 'Sales' in `roles`; adjust if your live
--     DB uses different names (verify with: SELECT id, name FROM roles;).

BEGIN;

-- 1. Add the two new permissions (skip if already present)
INSERT INTO permissions (name)
SELECT v.name
FROM (VALUES ('view_all_leads'), ('view_all_opportunities')) AS v(name)
WHERE NOT EXISTS (SELECT 1 FROM permissions p WHERE p.name = v.name);

-- 2. Grant Manager BOTH new permissions
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
JOIN permissions p ON p.name IN ('view_all_leads', 'view_all_opportunities')
WHERE r.name = 'Manager'
  AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp
    WHERE rp.role_id = r.id AND rp.permission_id = p.id
  );

-- 3. Grant Sales view_all_leads ONLY (own opportunities only)
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
JOIN permissions p ON p.name = 'view_all_leads'
WHERE r.name = 'Sales'
  AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp
    WHERE rp.role_id = r.id AND rp.permission_id = p.id
  );

-- 4. Retire view_all_records (drop its grants, then the permission row)
DELETE FROM role_permissions
WHERE permission_id = (SELECT id FROM permissions WHERE name = 'view_all_records');

DELETE FROM permissions WHERE name = 'view_all_records';

COMMIT;

-- Verify:
-- SELECT r.name AS role, p.name AS permission
-- FROM role_permissions rp
-- JOIN roles r ON r.id = rp.role_id
-- JOIN permissions p ON p.id = rp.permission_id
-- WHERE p.name LIKE 'view_all_%'
-- ORDER BY r.name, p.name;
