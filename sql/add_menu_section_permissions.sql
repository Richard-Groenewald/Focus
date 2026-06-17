-- Per-section "show this sidebar section" permissions for the 6 top-level menu
-- sections. Holding the permission displays the section; without it the section
-- is hidden. Items inside keep their own per-page permissions.
-- Rollout-safe: every new permission is granted to every existing role so the
-- current sidebar is unchanged until an admin revokes one.
-- Idempotent — safe to re-run.

INSERT INTO public.permissions (name, description)
SELECT v.name, v.description FROM (VALUES
  ('view_section_marketing',          'Show the Marketing menu section in the sidebar'),
  ('view_section_sales_management',   'Show the Sales Management menu section in the sidebar'),
  ('view_section_contract_management','Show the Contract Management menu section in the sidebar'),
  ('view_section_project_management', 'Show the Project Management menu section in the sidebar'),
  ('view_section_clients_contacts',   'Show the Clients & Contacts menu section in the sidebar'),
  ('view_section_site_admin',         'Show the Site Admin menu section in the sidebar')
) AS v(name, description)
WHERE NOT EXISTS (SELECT 1 FROM public.permissions p WHERE p.name = v.name);

-- Preserve current visibility: grant every new section permission to every role.
INSERT INTO public.role_permissions (role_id, permission_id)
SELECT r.id, p.id
FROM public.roles r
CROSS JOIN public.permissions p
WHERE p.name IN (
    'view_section_marketing','view_section_sales_management','view_section_contract_management',
    'view_section_project_management','view_section_clients_contacts','view_section_site_admin')
  AND NOT EXISTS (
    SELECT 1 FROM public.role_permissions rp WHERE rp.role_id = r.id AND rp.permission_id = p.id);
