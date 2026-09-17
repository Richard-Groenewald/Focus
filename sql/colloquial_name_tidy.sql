-- Colloquial-name tidy-up after v7.8.82 (Richard approved 2026-08-25).
-- Sales surfaces now display organisations.name, so the colloquial identity
-- moves INTO name; legal_name keeps the registered entity; trading_name stays
-- as a matching alias. Each update is guarded on the current name (no-op if
-- the row changed since review). Plus: delete the orphan Prospect org 4251
-- ('sca' — a mid-type autosave artifact, hardened against in v7.8.83).
begin;
update organisations set name = 'SAB'                        where id = 4170 and name = 'The South African Breweries Proprietary Limited';
update organisations set name = 'Evander Mines'              where id = 4041 and name = 'Evander Gold Mining (Pty) Ltd';
update organisations set name = 'Malelane Airport'           where id = 4075 and name = 'Leopard Creek Airport (Pty) Ltd';
update organisations set name = 'Access World Durban'        where id = 4000 and name = 'Access World (Durban) (Pty) Ltd';
update organisations set name = 'Access World SA'            where id = 4001 and name = 'Access World South Africa (Pty) Ltd';
update organisations set name = 'Leopard Creek Country Club' where id = 4083 and name = 'Leopard Creek Country Club Limited';
update organisations set name = 'Leopard Creek Share Block'  where id = 4084 and name = 'Leopard''s Creek Share Block (Pty) Ltd';
update organisations set name = 'Mercedes Benz South Africa' where id = 4210 and name = 'Mercedez Benz South Africa';

-- Orphan check for 4251 (informational — the FK constraints block the delete
-- anyway if anything still references it).
select 'sca refs' as what,
  (select count(*) from leads where target_org_id = 4251 or source_org_id = 4251) as leads,
  (select count(*) from sites where organisation_id = 4251) as sites,
  (select count(*) from deals where org_id = 4251) as deals,
  (select count(*) from person_organisation_roles where org_id = 4251) as affiliations,
  (select count(*) from campaign_targets where organisation_id = 4251) as targets,
  (select count(*) from quote_sites where organisation_id = 4251) as quote_sites,
  (select count(*) from sales_campaign_organisations where organisation_id = 4251) as study_orgs,
  (select count(*) from work_projects where organisation_id = 4251) as work_projects,
  (select count(*) from organisations where parent_org_id = 4251) as children;

delete from organisations where id = 4251 and name = 'sca' and client_status = 'Prospect';
commit;

-- Verify the renames landed
select id, name, trading_name, legal_name from organisations
where id in (4000, 4001, 4041, 4075, 4083, 4084, 4170, 4210) order by id;
select count(*) as sca_remaining from organisations where id = 4251;
