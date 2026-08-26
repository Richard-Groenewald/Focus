-- Typed-username sign-in + password policy + rate limiting (Focus v7.8.86,
-- Richard 2026-08-26/27). Idempotent — safe to re-run.
--
-- Usernames = first names ('les' for Lesley-Anne, per Richard). Richard and Les
-- KEEP their current passwords but must set a new policy-compliant one at next
-- sign-in (the current password verifies the reset — nothing is claimable).
-- The four new users get the temp password Qwerty1$ (PBKDF2 hashes below,
-- generated with sb.js's exact parameters) and are HELD INACTIVE until Richard
-- says go. The roleless 'admin' account is deactivated. New columns back the
-- 5-fails / 15-minute account lock.

alter table system_users add column if not exists failed_login_count integer not null default 0;
alter table system_users add column if not exists locked_until timestamptz;

begin;
update system_users set username = 'richard'  where id = 4  and person_id = 1;
update system_users set username = 'les'      where id = 12 and person_id = 4105;
update system_users set username = 'graeme'   where id = 13 and person_id = 4119;
update system_users set username = 'raphael'  where id = 14 and person_id = 4120;
update system_users set username = 'krishnee' where id = 15 and person_id = 4121;
update system_users set username = 'frik'     where id = 17 and person_id = 4123;

-- Richard + Les: forced reset, current password stays as the verification key.
update system_users set must_set_password = true where id in (4, 12);

-- New users: temp password Qwerty1$, forced reset on first login, inactive
-- until go-live ("hold as inactive until I say go").
update system_users set
  password_salt = 'f583ffaaae586e056105286570e19c9c',
  password_hash = 'be3acdd52d128a3985478c07b4d5666b97fb6e1eddc2103e887319cf6b4d9f98',
  password_set_at = now(), must_set_password = true, active = false
where id = 13 and person_id = 4119;   -- graeme

update system_users set
  password_salt = 'cffb759f020d6ea8a633b760fa615a4e',
  password_hash = '9c6fc7bb7e4ecbba2ebd16ed3e6a80922af636bc3e6b78769237aac17d9962aa',
  password_set_at = now(), must_set_password = true, active = false
where id = 14 and person_id = 4120;   -- raphael

update system_users set
  password_salt = '04203f8f50c8dfa5ff28ebfcefcd8862',
  password_hash = '960ff2d0e50648cdb9822d61065ca78ac2a21ca4a13c4341554f9e089ab98332',
  password_set_at = now(), must_set_password = true, active = false
where id = 15 and person_id = 4121;   -- krishnee

update system_users set
  password_salt = 'fbddcb7ee116ed6245a4fea7be8bc796',
  password_hash = 'b30e8dd411587f7d7de80dfb5d2890c5bdd8e762ca6494af23455faca5e8f66f',
  password_set_at = now(), must_set_password = true, active = false
where id = 17 and person_id = 4123;   -- frik

update system_users set active = false where id = 6 and username = 'admin';
commit;

-- Go-live for the four (run when Richard says go):
--   update system_users set active = true where id in (13, 14, 15, 17);

select id, username, active, must_set_password, (password_hash is not null) as has_pw,
       failed_login_count, locked_until
from system_users order by id;
