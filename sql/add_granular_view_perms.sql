-- Granular record-visibility permissions (v7.7.5)
-- Splits the old single `view_all_records` permission into two independent ones:
--   view_all_leads          -> may see every lead (not just own)
--   view_all_opportunities  -> may see every deal/opportunity (not just own)
-- and RETIRES view_all_records.
--
-- Default grants (per decision 2026-06-22, mapped to live role names):
--   view_all_leads         -> Sales Manager, Executive
--   view_all_opportunities -> Executive, Operations
--   (Admin bypasses via app-layer 'all'; all other roles stay own-only.)
--
-- Name-based & idempotent. Run on Dev DB first, then prod per the sync recipe.
-- NB: keyed off the live role names (verify with: SELECT id, name FROM roles;).
--     view_all_records does not exist in these DBs; the cleanup below is a
--     harmless no-op kept for any environment that still carries it.

BEGIN;

-- 1. Add the two new permissions (skip if already present)
INSERT INTO permissions (name)
SELECT v.name
FROM (VALUES ('view_all_leads'), ('view_all_opportunities')) AS v(name)
WHERE NOT EXISTS (SELECT 1 FROM permissions p WHERE p.name = v.name);

-- 2. Grant view_all_leads -> Sales Manager, Executive
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
JOIN permissions p ON p.name = 'view_all_leads'
WHERE r.name IN ('Sales Manager', 'Executive')
  AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp
    WHERE rp.role_id = r.id AND rp.permission_id = p.id
  );

-- 3. Grant view_all_opportunities -> Executive, Operations
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
JOIN permissions p ON p.name = 'view_all_opportunities'
WHERE r.name IN ('Executive', 'Operations')
  AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp
    WHERE rp.role_id = r.id AND rp.permission_id = p.id
  );

-- 4. Retire legacy view_all_records if present (no-op otherwise)
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
