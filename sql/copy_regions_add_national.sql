-- Focus CRM — sync regions Dev→Prod + add a "National" region to both
-- ----------------------------------------------------------------------------
-- Prod was missing 4 regions that Dev has (Mpumalanga, Great Karoo, Free State
-- Goldfield, Greater Durban Area — all under branch 2 = Centurion). Branch ids
-- are identical on both DBs (1=Cape Town, 2=Centurion), so branch_id maps cleanly.
--
-- "National" is added to BOTH with branch_id = NULL (it spans branches).
--
-- Explicit ids keep regions aligned across Dev/Prod (Prod seq was at 2 so these
-- would land on 3-7 anyway; Dev already has 3-6 so ON CONFLICT skips them and only
-- National (7) is added). Idempotent: safe to re-run on either DB.
-- ----------------------------------------------------------------------------

insert into regions (id, name, branch_id, active, created_at) values
  (3, 'Mpumalanga',           2,    true, now()),
  (4, 'Great Karoo',          2,    true, now()),
  (5, 'Free State Goldfield', 2,    true, now()),
  (6, 'Greater Durban Area',  2,    true, now()),
  (7, 'National',             null, true, now())
on conflict (id) do nothing;

-- Realign the sequence so future region inserts don't collide with the explicit ids.
select setval('regions_id_seq', (select max(id) from regions));

-- Verify --------------------------------------------------------------------
-- select id, name, branch_id, active from regions order by id;
