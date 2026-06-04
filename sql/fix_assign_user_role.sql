-- Fix: assign a login role to a system user.
-- Login resolves roles from `user_roles` (user_id -> role_id), but the app has no
-- UI that writes that table — so a new user logs in with "No role" / empty menu.
-- Run this to link the user to the correct role.
--
-- 1) DIAGNOSE — see the user, their current user_roles, and available roles.
--    Replace 'newuser' with the username you created.

select su.id as system_user_id, su.username,
       p.first_name || ' ' || p.last_name as person,
       coalesce(string_agg(r.name, ', '), '(none)') as login_roles
from system_users su
join people p on p.id = su.person_id
left join user_roles ur on ur.user_id = su.id
left join roles r       on r.id = ur.role_id
where su.username = 'newuser'      -- <<< EDIT
group by su.id, su.username, person;

-- available roles (use an exact name below — 'Sales User' has the wired permissions):
--   select id, name from roles order by name;

-- 2) FIX — link the user to the 'Sales User' role (idempotent).
--    Edit the username; change the role name to 'Sales Manager' if appropriate.

insert into user_roles (user_id, role_id)
select su.id, r.id
from system_users su
cross join roles r
where su.username = 'newuser'       -- <<< EDIT
  and r.name      = 'Sales User'    -- <<< EDIT ('Sales User' or 'Sales Manager')
  and not exists (
    select 1 from user_roles x where x.user_id = su.id and x.role_id = r.id
  );

-- 3) Re-run the diagnose query (step 1) to confirm login_roles now shows the role.
--    Then log out and back in — the menu should appear.
