-- Permissions for Manage Clients / Manage Contacts (own vs all, inferred
-- ownership) + admin-only lead deletion. Idempotent; run on Dev then Prod.

insert into permissions (name, description)
select v.name, v.description from (values
  ('manage_contacts',   'Access the Contacts management page'),
  ('view_all_clients',  'See all clients, not only your own'),
  ('view_all_contacts', 'See all contacts, not only your own'),
  ('delete_leads',      'Delete a lead (never a promoted one)')
) as v(name, description)
where not exists (select 1 from permissions p where p.name = v.name);

-- manage_contacts → same roles as manage_clients.
insert into role_permissions (role_id, permission_id)
select r.id, p.id
from roles r cross join permissions p
where p.name = 'manage_contacts'
  and r.name in ('Admin','Executive','Sales Manager','Sales User')
  and not exists (select 1 from role_permissions rp where rp.role_id = r.id and rp.permission_id = p.id);

-- view_all_clients / view_all_contacts → Admin + Executive + Sales Manager (mirrors view_all_leads).
insert into role_permissions (role_id, permission_id)
select r.id, p.id
from roles r cross join permissions p
where p.name in ('view_all_clients','view_all_contacts')
  and r.name in ('Admin','Executive','Sales Manager')
  and not exists (select 1 from role_permissions rp where rp.role_id = r.id and rp.permission_id = p.id);

-- delete_leads → Admin only.
insert into role_permissions (role_id, permission_id)
select r.id, p.id
from roles r cross join permissions p
where p.name = 'delete_leads' and r.name = 'Admin'
  and not exists (select 1 from role_permissions rp where rp.role_id = r.id and rp.permission_id = p.id);
