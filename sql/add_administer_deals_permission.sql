-- Deal Administration page: edit secured deals + delete deals.
-- These actions are blocked on the normal Opportunities page; they are only
-- available on the dedicated, permission-gated Deal Administration page.
-- Apply to the TEST DB first:
--   ~/scoop/apps/postgresql/current/bin/psql.exe "$SUPABASE_TEST_DB_URL" -f sql/add_administer_deals_permission.sql
-- (Admins carry 'all' and reach the page regardless; this grants the explicit permission.)

insert into permissions (name, description)
values ('administer_deals', 'Deal Administration: edit secured deals and delete deals')
on conflict (name) do nothing;

-- Grant to the Admin role only (strictest default; widen later if needed).
insert into role_permissions (role_id, permission_id)
select r.id, p.id
from roles r
cross join permissions p
where r.name = 'Admin' and p.name = 'administer_deals'
on conflict (role_id, permission_id) do nothing;
