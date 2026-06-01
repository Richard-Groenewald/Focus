-- Manage Clients feature — adds client designation + status to organisations.
-- Idempotent: safe to run on both test and production.

ALTER TABLE organisations ADD COLUMN IF NOT EXISTS is_client boolean NOT NULL DEFAULT false;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS client_status text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'organisations_client_status_chk'
  ) THEN
    ALTER TABLE organisations
      ADD CONSTRAINT organisations_client_status_chk
      CHECK (client_status IN ('Active', 'Standing', 'Dormant'));
  END IF;
END $$;

-- New permission for the Manage Clients section (idempotent insert).
INSERT INTO permissions (name)
SELECT 'manage_clients'
WHERE NOT EXISTS (SELECT 1 FROM permissions WHERE name = 'manage_clients');

-- Grant manage_clients to the client-facing roles (idempotent, matched by name).
-- Admin already sees everything, but granting keeps role_permissions explicit.
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM roles r
CROSS JOIN permissions p
WHERE p.name = 'manage_clients'
  AND r.name IN ('Admin', 'Sales Manager', 'Sales User')
  AND NOT EXISTS (
    SELECT 1 FROM role_permissions rp
    WHERE rp.role_id = r.id AND rp.permission_id = p.id
  );
