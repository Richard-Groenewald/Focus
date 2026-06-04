-- Clear production BUSINESS/transactional data. Keep: all lookups, all access/
-- essentials (roles/permissions/users/regions/settings), the home organisation
-- (Xone), and people linked to a system-user login OR a home-org membership.
-- Run atomically:  psql "$URL" --single-transaction -v ON_ERROR_STOP=1 -f thisfile

-- Audit ref that would otherwise block people deletion (kept table -> people).
update system_user_regions set created_by = null
 where created_by is not null
   and created_by not in (
     select person_id from system_users where person_id is not null
     union select person_id from home_organisation_members where person_id is not null);

-- Transactional tables in FK-dependency order (a table is deleted only after
-- everything that references it). Verified against the prod FK graph:
--   revenue_stream_months->revenue_streams; deal_collaborators/opportunity_contacts->deals;
--   engagement_people->engagements; lead_*->leads; engagements&lead_interactions->next_actions;
--   leads->deals,research_campaigns.
delete from revenue_stream_months;
delete from revenue_streams;
delete from deal_collaborators;
delete from opportunity_contacts;
delete from engagement_people;
delete from lead_red_flags;
delete from lead_strategic_decisions;
delete from lead_interactions;
delete from engagements;
delete from leads;
delete from next_actions;
delete from research_campaigns;
delete from deals;
delete from parties;
delete from person_organisation_roles;

-- Organisations: keep only the home org (Xone). Clear self-ref first.
update organisations set parent_org_id = null where home_organisation is not true;
delete from organisations where home_organisation is not true;

-- People: keep only system-user accounts + home-org members.
delete from people
 where id not in (
   select person_id from system_users where person_id is not null
   union select person_id from home_organisation_members where person_id is not null);
