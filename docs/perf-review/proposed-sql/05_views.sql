-- Focus CRM performance review, September 2026 — proposals 2.1, 2.2, 2.6, 2.8, 2.10
-- (findings SRV-1, SRV-2, SRV-6, SRV-7, SRV-8 in findings-catalogue.md)
--
-- Views and functions the pages read in ONE call instead of downloading tables and
-- joining in the browser. All are plain (non-materialised) views over existing
-- tables: no data is copied and nothing goes stale.
--
-- Check the live FK list before relying on PostgREST embedding from these views:
--   select conrelid::regclass, conname, pg_get_constraintdef(oid)
--     from pg_constraint where contype = 'f' order by 1;

begin;

-- ── 2.1  deal_financials: TCV / margin / weighted / first-last month per deal
--        and stream type. Replaces every page that embeds ALL revenue_stream_months
--        rows to sum them in JS (register 11803, dashboard 12664/12707, pipeline 13574).
--        Financials still come only from revenue streams, never from base amount /
--        num months.
create or replace view public.deal_financials as
select s.deal_id, s.stream_type, s.id as stream_id, s.locked,
       count(m.id)                                   as months,
       min(m.month)                                  as first_month,
       max(m.month)                                  as last_month,
       coalesce(sum(m.opportunity_revenue), 0)       as opportunity_revenue,
       coalesce(sum(m.opportunity_margin), 0)        as opportunity_margin,
       coalesce(sum(m.secured_revenue), 0)           as secured_revenue,
       coalesce(sum(m.secured_margin), 0)            as secured_margin,
       coalesce(sum(m.actual_revenue) filter (where m.is_actual_revenue), 0) as actual_revenue,
       coalesce(sum(m.opportunity_revenue), 0) * coalesce(d.probability, 0) / 100.0 as weighted
  from public.revenue_streams s
  join public.deals d on d.id = s.deal_id
  left join public.revenue_stream_months m on m.stream_id = s.id
 group by s.deal_id, s.stream_type, s.id, s.locked, d.probability;

-- Client: apiGetAll('deal_financials', 'stream_type=eq.opportunity&select=deal_id,opportunity_revenue,weighted,locked')
-- returns one ~60-byte row per deal.

-- ── 2.2  opportunities_register: the Opportunities page as one server-filtered read.
create or replace view public.opportunities_register as
select d.id, d.name, d.org_id, o.name as org_name, o.legal_name, o.parent_org_id,
       sec.name as sector,
       d.site_id, si.name as site_name,
       d.stage_id, st.name as stage, sc.name as stage_category, st.sort_order as stage_order,
       d.probability, d.order_date, d.start_date, d.owner_id,
       trim(concat_ws(' ', p.first_name, p.last_name)) as owner_name,
       d.region_id, d.branch_id, d.service_major_id, d.service_sub_id,
       d.opportunity_type, d.master_deal_id, d.parent_deal_id, d.created_at, d.updated_at,
       f.opportunity_revenue as tcv, f.weighted, coalesce(f.locked, false) as forecast_locked,
       f.first_month, f.last_month,
       (select coalesce(array_agg(dc.person_id), '{}') from public.deal_collaborators dc where dc.deal_id = d.id) as collaborator_ids
  from public.deals d
  left join public.organisations o      on o.id = d.org_id
  left join public.industry_sectors sec on sec.id = o.sector_id
  left join public.sites si             on si.id = d.site_id
  left join public.stages st            on st.id = d.stage_id
  left join public.stage_categories sc  on sc.id = st.category_id
  left join public.people p             on p.id = d.owner_id
  left join public.deal_financials f    on f.deal_id = d.id and f.stream_type = 'opportunity';

-- Client (Own / Open): apiGetAll('opportunities_register',
--   'owner_id=eq.' + me + '&stage_category=eq.Opportunity-Open&order=created_at.desc')
-- Collaborations: '&collaborator_ids=cs.{' + me + '}'

-- ── 2.6  engagements_labelled: engagements with every label the history, attention,
--        milestones, internal-activity and report pages currently resolve in JS.
--        Stage ids follow sql/seed_lookups.sql (5 Secured, 6 Lost, 7 In Progress, 8 Complete).
create or replace view public.engagements_labelled as
select e.*,
       case when e.lead_id is not null then 'lead'
            when e.deal_id is not null then 'deal'
            else 'project' end                                        as parent_kind,
       coalesce(e.lead_id, e.deal_id, e.work_project_id)              as parent_id,
       coalesce(d.name, l.description)                                as parent_label,
       coalesce(l.owner_id, d.owner_id)                               as owner_id,
       coalesce(o_d.id, o_l.id, s_l.organisation_id)                  as client_org_id,
       coalesce(o_d.name, o_l.name, l.target_org_name)                as client_name,
       l.site_name                                                    as lead_site_name,
       s_l.name                                                       as lead_site,
       d.stage_id, d.service_sub_id,
       case when e.lead_id is not null then 'Outreach'
            when d.stage_id = 6 then 'Sales'
            when d.stage_id in (5, 7, 8) then case when ss.is_recurring = false then 'Project' else 'Contract' end
            else 'Sales' end                                          as category,
       (e.lead_id is null and d.stage_id = 6)                         as lost,
       coalesce(root.stream_label, 'Stream #' || coalesce(e.stream_id, e.id)) as stream_label_resolved,
       (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', trim(concat_ws(' ', p.first_name, p.last_name)))), '[]')
          from public.engagement_people ep join public.people p on p.id = ep.person_id
         where ep.engagement_id = e.id)                               as persons,
       (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'type_id', m.milestone_type_id, 'status', m.status)), '[]')
          from public.engagement_milestones m where m.engagement_id = e.id) as milestones
  from public.engagements e
  left join public.leads l           on l.id = e.lead_id
  left join public.sites s_l         on s_l.id = l.site_id
  left join public.organisations o_l on o_l.id = l.target_org_id
  left join public.deals d           on d.id = e.deal_id
  left join public.organisations o_d on o_d.id = d.org_id
  left join public.service_sub ss    on ss.id = d.service_sub_id
  left join public.engagements root  on root.id = coalesce(e.stream_id, e.id);

-- Group touch per organisation (replaces the whole-table engagements scan in _loadOrgTouches)
create or replace view public.org_last_touch as
select org_id, max(engagement_date) as last_touch
  from public.engagements
 where org_id is not null and work_mode is distinct from 'internal'
 group by org_id;

-- Client (Engagement History, Outreach, own): apiGet('engagements_labelled',
--   'category=eq.Outreach&engagement_date=gte.' + from + '&or=(owner_id.eq.' + me + ',created_by.eq.' + me + ')'
--   + '&select=id,engagement_date,engagement_type,notes,next_action,next_action_date,next_action_done,work_mode,'
--   + 'parent_kind,parent_id,parent_label,owner_id,client_name,category,lost,stream_id,stream_label_resolved,persons,milestones'
--   + '&order=engagement_date.desc,id.desc&limit=1000')

-- ── 2.8  ownership_scope: replaces _ensureOwnershipScope's three whole-table pulls.
create or replace function public.ownership_scope(p_person_id bigint) returns jsonb
language sql stable security definer as $$
select jsonb_build_object(
  'owned_orgs', (select coalesce(jsonb_agg(distinct x.org_id), '[]') from (
      select org_id from public.deals where owner_id = p_person_id and org_id is not null
      union select target_org_id from public.leads where owner_id = p_person_id and target_org_id is not null) x),
  'owned_persons', (select coalesce(jsonb_agg(distinct x.pid), '[]') from (
      select dc.person_id as pid from public.deal_contacts dc join public.deals d on d.id = dc.deal_id where d.owner_id = p_person_id
      union select (c->>'person_id')::bigint from public.leads l
             cross join lateral jsonb_array_elements(coalesce(l.contacts, '[]'::jsonb)) c
            where l.owner_id = p_person_id and (c->>'person_id') is not null) x),
  'contact_persons', (select coalesce(jsonb_agg(distinct x.pid), '[]') from (
      select person_id as pid from public.deal_contacts
      union select (c->>'person_id')::bigint from public.leads l
             cross join lateral jsonb_array_elements(coalesce(l.contacts, '[]'::jsonb)) c
            where (c->>'person_id') is not null) x))
$$;

-- Client: const s = await apiGet('rpc/ownership_scope', 'p_person_id=' + me);

-- ── 2.10  user_context: the whole of buildUserContext + settings + home-org members in one call.
--        The 'login' action in sb.js can call this via sbRest and return it with the token;
--        session resume calls apiGet('rpc/user_context', 'p_user_id=' + userId).
--        Never returns password_hash / password_salt.
create or replace function public.user_context(p_user_id bigint) returns jsonb
language sql stable security definer as $$
select jsonb_build_object(
  'user', (select jsonb_build_object('id', id, 'person_id', person_id, 'username', username,
                                     'active', active, 'must_set_password', must_set_password)
             from public.system_users where id = p_user_id),
  'person', (select to_jsonb(p) from public.people p
               join public.system_users su on su.person_id = p.id where su.id = p_user_id),
  'roles', (select coalesce(jsonb_agg(to_jsonb(r)), '[]')
              from public.user_roles ur join public.roles r on r.id = ur.role_id where ur.user_id = p_user_id),
  'permissions', (select coalesce(jsonb_agg(distinct name), '[]') from (
       select pm.name from public.user_roles ur
         join public.role_permissions rp on rp.role_id = ur.role_id
         join public.permissions pm on pm.id = rp.permission_id where ur.user_id = p_user_id
       union select pm.name from public.user_permission_overrides o
         join public.permissions pm on pm.id = o.permission_id where o.user_id = p_user_id and o.granted
       except select pm.name from public.user_permission_overrides o
         join public.permissions pm on pm.id = o.permission_id where o.user_id = p_user_id and not o.granted) x),
  'regions',  (select coalesce(jsonb_agg(region_id), '[]') from public.system_user_regions  where system_user_id = p_user_id),
  'branches', (select coalesce(jsonb_agg(branch_id), '[]') from public.system_user_branches where system_user_id = p_user_id),
  'settings', (select coalesce(jsonb_object_agg(key, value), '{}') from public.settings),
  'home_org_member_ids', (select coalesce(jsonb_agg(distinct person_id), '[]') from public.home_organisation_members))
$$;

commit;

-- Still to write against the live schema (specified in the catalogue):
--   leads_register view (LR-06), dashboard_summary(p_person_id, p_scope) (SRV-3 / D5),
--   lead_bundle / deal_bundle (SRV-4 / LF-02), promote_lead(p_lead_id, p_pkg) (SRV-5 / PW-01),
--   merge_organisations (SRV-10 / G12), the Proposal Builder functions (PB-01, PB-03, PB-04, PB-05).
-- They depend on columns of sites, deal_contacts, engagement_milestones and lead_stage_requests
-- whose DDL is not in sql/.
