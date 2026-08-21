-- Sales Viewer role (2026-08-20). PROD only, for Graeme / Raphael / Krishnee.
--
-- WHY THIS IS AN INTERIM. Richard wants three people to see everything Sales
-- Management sees without being able to change it. Focus cannot express that
-- today: every Sales Management menu item is gated on `manage_leads` or
-- `manage_opportunities`, the menu skips a section when no item passes can(),
-- and those two permissions are never checked anywhere ELSE in the app. So
-- reaching a page IS permission to edit it, and the existing 'Read Only' role
-- (six view_section_* permissions) would show them no Sales Management at all.
--
-- Until a real per-user read-only switch ships, this role does the one thing
-- configuration can do: keep full visibility, remove the rights whose misuse is
-- hardest to undo.
--
--   REMOVED vs Sales Manager   delete_leads   destroys records
--                              promote_lead   converts a lead to an opportunity,
--                                             and via _engShiftCanAll() is also
--                                             what grants milestone approve/decline
--                              assign_owner   silently moves someone's book
--
--   STILL POSSIBLE (accepted, interim)  editing leads, opportunities, clients,
--   contacts and organisations; creating quotes. Full read access is retained.
--
-- ⚠️ This is UI-level only. Focus has no RLS, so a determined user could still
-- write through the proxy API. It reduces accident and blast radius, not intent.
--
-- Idempotent / transactional: safe to re-run.

begin;

-- ── 1. The role ───────────────────────────────────────────────────────────────
insert into roles (name, description, is_system)
select 'Sales Viewer',
       'Sees everything Sales Management sees. Cannot delete leads, promote leads, '
       'reassign ownership, or approve milestones. Interim until a per-user '
       'read-only mode ships.',
       false
where not exists (select 1 from roles where name = 'Sales Viewer');

-- ── 2. Permissions: Sales Manager, less the three ────────────────────────────
-- Derived from Sales Manager rather than listed literally, so the two roles do
-- not drift apart the next time Sales Manager gains a viewing permission.
insert into role_permissions (role_id, permission_id)
select (select id from roles where name = 'Sales Viewer'), rp.permission_id
  from role_permissions rp
  join roles r on r.id = rp.role_id
  join permissions p on p.id = rp.permission_id
 where r.name = 'Sales Manager'
   and p.name not in ('delete_leads', 'promote_lead', 'assign_owner')
   and not exists (
     select 1 from role_permissions x
      where x.role_id = (select id from roles where name = 'Sales Viewer')
        and x.permission_id = rp.permission_id)
;

-- Belt and braces: if this is re-run after Sales Manager changed, make sure the
-- three excluded rights have not crept in.
delete from role_permissions
 where role_id = (select id from roles where name = 'Sales Viewer')
   and permission_id in (select id from permissions
                          where name in ('delete_leads', 'promote_lead', 'assign_owner'));

-- ── 3. Move the three accounts across ────────────────────────────────────────
-- Graeme Auret (13), Raphael Andro (14), Krishnee Naidoo (15). Matched by
-- username so a re-run cannot catch anyone else by id drift.
insert into user_roles (user_id, role_id)
select su.id, (select id from roles where name = 'Sales Viewer')
  from system_users su
 where su.username in ('Graeme Auret', 'Raphael Andro', 'Krishnee Naidoo')
   and not exists (select 1 from user_roles ur
                    where ur.user_id = su.id
                      and ur.role_id = (select id from roles where name = 'Sales Viewer'));

delete from user_roles
 where role_id = (select id from roles where name = 'Sales Manager')
   and user_id in (select id from system_users
                    where username in ('Graeme Auret', 'Raphael Andro', 'Krishnee Naidoo'));

-- ── 4. Give the new role a dashboard ─────────────────────────────────────────
-- _dashWidgetsForUser() falls back to DASH_ROLE_WIDGETS[roleName] || [] — an
-- unknown role name means a BLANK dashboard. Seed it with Sales Manager's list
-- minus 'approvals', which they can no longer action.
update settings
   set value = (
     (value::jsonb) || jsonb_build_object('Sales Viewer',
       ((value::jsonb) -> 'Sales Manager') - 'approvals')
   )::text
 where key = 'dashboard_role_widgets'
   and (value::jsonb) ? 'Sales Manager';

commit;

-- Verify:
--   select su.username, r.name from system_users su
--     join user_roles ur on ur.user_id = su.id join roles r on r.id = ur.role_id
--    where su.username in ('Graeme Auret','Raphael Andro','Krishnee Naidoo');
--   select p.name from roles r join role_permissions rp on rp.role_id = r.id
--     join permissions p on p.id = rp.permission_id
--    where r.name = 'Sales Viewer' order by p.name;
--   select (value::jsonb) -> 'Sales Viewer' from settings where key='dashboard_role_widgets';
