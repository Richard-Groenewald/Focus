-- Increment 1 — Ownership access model: permissions & role wiring
-- Run once against Supabase (SQL editor). Idempotent: safe to re-run.
--
-- Introduces the new permission rows and splits Leads off `manage_opportunities`.
-- No enforcement of edit/region/promote yet — those rows are seeded so the
-- Role Permissions matrix UI can assign them ahead of increments 3–5.
--
-- Uses `where not exists` rather than `on conflict` so it does not depend on
-- specific unique constraints existing on permissions / role_permissions.

begin;

-- 1. New permission rows (manage_opportunities already exists).
insert into permissions (name)
select v.name
from (values
  ('manage_leads'),
  ('edit_all_records'),
  ('assign_owner'),
  ('promote_lead')
) as v(name)
where not exists (
  select 1 from permissions p where p.name = v.name
);

-- 2. Migration: every role that can currently reach Leads (via manage_opportunities)
--    must also get manage_leads, or Leads disappears for them after the nav split.
insert into role_permissions (role_id, permission_id)
select distinct rp.role_id, ml.id
from role_permissions rp
join permissions po on po.id = rp.permission_id and po.name = 'manage_opportunities'
join permissions ml on ml.name = 'manage_leads'
where not exists (
  select 1 from role_permissions x
  where x.role_id = rp.role_id and x.permission_id = ml.id
);

-- 3. Grant the override permissions to Sales Manager.
--    Admin is untouched: isAdmin short-circuits can() to grant `all`.
insert into role_permissions (role_id, permission_id)
select r.id, p.id
from roles r
cross join permissions p
where r.name = 'Sales Manager'
  and p.name in ('edit_all_records', 'assign_owner', 'promote_lead')
  and not exists (
    select 1 from role_permissions x
    where x.role_id = r.id and x.permission_id = p.id
  );

-- 4. Base permissions per the agreed matrix. The step-2 back-fill only covers
--    roles that ALREADY had manage_opportunities; in this DB Sales User and
--    Sales Manager did not, so grant their base perms explicitly.
--      Sales User    -> manage_leads, manage_opportunities
--      Sales Manager -> manage_leads, manage_opportunities
insert into role_permissions (role_id, permission_id)
select r.id, p.id
from roles r
cross join permissions p
where r.name in ('Sales User', 'Sales Manager')
  and p.name in ('manage_leads', 'manage_opportunities')
  and not exists (
    select 1 from role_permissions x
    where x.role_id = r.id and x.permission_id = p.id
  );

commit;

-- Verify:
--   select r.name as role, p.name as permission
--   from role_permissions rp
--   join roles r on r.id = rp.role_id
--   join permissions p on p.id = rp.permission_id
--   where p.name in ('manage_leads','manage_opportunities','edit_all_records','assign_owner','promote_lead')
--   order by r.name, p.name;
