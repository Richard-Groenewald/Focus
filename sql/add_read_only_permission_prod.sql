-- read_only permission + Frik Wiese (2026-08-21). PROD. Run WITH v7.8.59, not before:
-- the permission does nothing until the code that honours it is deployed, and it
-- is harmless if it lands first.
--
-- WHAT read_only DOES. index.html's api() refuses every non-GET for a user holding
-- it (except the presence heartbeat and bug reports), and the generic Add button
-- and row-action controls disappear. It changes nothing about what they can SEE.
-- Completes the interim 'Sales Viewer' role from sql/add_sales_viewer_role_prod.sql,
-- which could only remove delete/promote/assign.
--
-- ⚠️ STILL UI-LEVEL. Focus has no RLS and the proxy runs on the service key, so a
-- determined person with the network tab open can still write. This stops
-- accidents and casual mischief. Do not present it as enforcement.
--
-- Idempotent / transactional: safe to re-run.

begin;

-- ── 1. The permission ────────────────────────────────────────────────────────
insert into permissions (name, description)
select 'read_only',
       'Suppresses every write in the app for this user (api() guard + hidden edit '
       'controls). Visibility is unaffected. UI-level only - Focus has no RLS.'
where not exists (select 1 from permissions where name = 'read_only');

insert into role_permissions (role_id, permission_id)
select r.id, p.id
  from roles r cross join permissions p
 where r.name = 'Sales Viewer' and p.name = 'read_only'
   and not exists (select 1 from role_permissions x
                    where x.role_id = r.id and x.permission_id = p.id);

-- ── 2. Frik Wiese, same rights as the other three ────────────────────────────
-- Person first: system_users.person_id -> people.id is how currentUser.personId
-- resolves, and a system user without one breaks ownership and audit attribution.
insert into people (first_name, last_name, email, phone)
select 'Frik', 'Wiese', 'frik.wiese@xone.co.za', '+27723011400'
where not exists (select 1 from people where lower(email) = 'frik.wiese@xone.co.za');

insert into system_users (person_id, username, active, must_set_password)
select p.id, 'Frik Wiese', true, true
  from people p
 where lower(p.email) = 'frik.wiese@xone.co.za'
   and not exists (select 1 from system_users where username = 'Frik Wiese');

insert into user_roles (user_id, role_id)
select su.id, r.id
  from system_users su cross join roles r
 where su.username = 'Frik Wiese' and r.name = 'Sales Viewer'
   and not exists (select 1 from user_roles x where x.user_id = su.id and x.role_id = r.id);

-- ── 3. Force all four viewers to choose a password at next sign-in ───────────
-- NOTE: Focus has no "temporary password" concept. handleAuth() treats
-- must_set_password as "cannot sign in at all until a new one is chosen", and the
-- set action skips the current-password check in that state - so any password
-- stored here would never be typed. The existing hashes are therefore cleared
-- rather than replaced with a known-weak one.
update system_users
   set password_hash = null, password_salt = null, password_set_at = null,
       must_set_password = true
 where username in ('Graeme Auret', 'Raphael Andro', 'Krishnee Naidoo', 'Frik Wiese');

commit;

-- Verify:
--   select su.username, r.name, su.must_set_password, (su.password_hash is not null) as has_hash
--     from system_users su
--     left join user_roles ur on ur.user_id = su.id left join roles r on r.id = ur.role_id
--    where su.username in ('Graeme Auret','Raphael Andro','Krishnee Naidoo','Frik Wiese');
--   select p.name from roles r join role_permissions rp on rp.role_id = r.id
--     join permissions p on p.id = rp.permission_id where r.name = 'Sales Viewer' order by p.name;
