-- Typed-username sign-in + password policy reset (Focus v7.8.86, Richard 2026-08-26).
-- Usernames become first names (case-insensitive at login). All six accounts are
-- forced to create a NEW password meeting the policy (8+ chars, lower, upper,
-- number, special) — old hashes are cleared so the old passwords die immediately
-- (live sessions survive on their tokens; the reset bites at next sign-in).
-- The roleless claimable 'admin' account is deactivated. Idempotent.
begin;
update system_users set username = 'richard'     where id = 4  and person_id = 1;
update system_users set username = 'lesley-anne' where id = 12 and person_id = 4105;
update system_users set username = 'graeme'      where id = 13 and person_id = 4119;
update system_users set username = 'raphael'     where id = 14 and person_id = 4120;
update system_users set username = 'krishnee'    where id = 15 and person_id = 4121;
update system_users set username = 'frik'        where id = 17 and person_id = 4123;

update system_users
set must_set_password = true, password_hash = null, password_salt = null, password_set_at = null
where id in (4, 12, 13, 14, 15, 17);

update system_users set active = false where id = 6 and username = 'admin';
commit;

select id, username, active, must_set_password, (password_hash is not null) as has_pw
from system_users order by id;
