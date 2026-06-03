-- Revenue Stream Pipeline page: dedicated view permission.
-- Apply to the TEST DB first:
--   ~/scoop/apps/postgresql/current/bin/psql.exe "$SUPABASE_TEST_DB_URL" -f sql/add_revenue_pipeline_permission.sql
-- (Admins carry 'all' and see the page regardless; this grants non-admin roles.)

insert into permissions (name, description)
values ('view_revenue_pipeline', 'View the Revenue Stream Pipeline (cross-deal revenue matrix)')
on conflict (name) do nothing;

-- Grant to every role that already has manage_opportunities (coherent default scope).
insert into role_permissions (role_id, permission_id)
select rp.role_id, p2.id
from role_permissions rp
join permissions p1 on p1.id = rp.permission_id and p1.name = 'manage_opportunities'
join permissions p2 on p2.name = 'view_revenue_pipeline'
on conflict (role_id, permission_id) do nothing;
