-- Session revocation (Focus v7.9.56, Richard 2026-09-17: "do item 1, the
-- session revocation"). Idempotent — safe to re-run on either database.
--
-- Before this, a signed session token stayed valid until it expired (24h):
-- deactivating a user or resetting their password did NOT end a session they
-- already held. Now each token carries the user's session_version, the sb
-- function confirms it (and active) on every proxied request, and THIS trigger
-- bumps the version whenever a credential-relevant change lands on the row —
-- whichever path made it: the /auth 'set' action, the admin Reset-password
-- button, the System Users form's Active tick, or direct SQL.
--
-- ⚠️ RUN THIS BEFORE THE v7.9.56 CODE REACHES THE SAME DATABASE. The function's
-- login SELECT and per-request check both read session_version; code-first =
-- every sign-in and every data call fails until the column exists.
-- Deploying the code ends every open session once (the token format changes
-- and the old one is refused) — users simply sign in again.

alter table system_users add column if not exists session_version integer not null default 1;

create or replace function bump_session_version() returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if (old.active is not false and new.active is false)                        -- deactivated
     or new.password_hash is distinct from old.password_hash                   -- password set, changed or cleared
     or (old.must_set_password is not true and new.must_set_password is true)  -- forced reset switched on
  then
    new.session_version := coalesce(old.session_version, 1) + 1;
  end if;
  return new;
end;
$$;

drop trigger if exists system_users_bump_session_version on system_users;
create trigger system_users_bump_session_version
  before update on system_users
  for each row execute function bump_session_version();

-- PostgREST learns the new column on its next schema reload; ask for one now.
notify pgrst, 'reload schema';

-- Verify
select id, username, active, must_set_password, session_version from system_users order by id;
