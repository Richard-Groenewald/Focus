-- Focus v7.10.14 — lead_open_bundle(p_lead_id) (2026-10-20).
--
-- Opening a lead used to cost seven DEPENDENT round trips: the lead row, the
-- description log, the lead's engagements, the group engagements on its
-- organisation chain, their milestones, the campaign cadence steps and the
-- campaign name — each waiting on the one before. On prod's Nano instance every
-- trip that stalls at the API layer adds seconds (Richard, 2026-10-20: "clicking
-- on edit lead takes many seconds before opening"). This returns everything
-- openLeadForm reads for ONE lead in a single call; the lookups the form needs
-- are already cached by the time a lead is opened.
--
-- The app calls it through the existing proxy:
--   api('rpc/lead_open_bundle', 'POST', { p_lead_id: <id> })
-- and keeps its per-table reads when the function is absent (404 / PGRST202),
-- so this file can ship before or after the v7.10.14 deploy. Idempotent, SQL
-- editor safe. Run on Dev first, then prod.
--
-- Keys returned:
--   lead_id             the id asked for (the client checks it before using the bundle)
--   lead                the leads row (null when no such lead), as select=* would return it
--   site                the lead's sites row, or null
--   org                 the lead's target organisation row, or null
--   description_log     lead_description_log rows, newest first (created_at desc, id desc)
--   service_estimates   lead_service_estimates rows
--   engagements         the lead's own engagements, engagement_date desc, created_at desc
--   org_chain           ids of the lead's organisation and its ancestors (target org, else the
--                       site's organisation), nearest first — the chain loadLeadInteractions walks
--   group_engagements   engagements on any organisation of that chain, engagement_date desc
--   milestones          engagement_milestones rows for the lead's own engagements
--   cadence_steps       campaign_cadence_steps for the lead's research campaign, step_no asc
--   campaign_name       that campaign's name, or null
--   red_flag_links      lead_red_flags rows for the lead
--   strategic_decision_links  lead_strategic_decisions rows for the lead
--   stage_request       the latest pending hold / nurture lead_stage_requests row, or null
--   red_flags, strategic_decisions   the ACTIVE lookup rows (sort_order, name) — the form's pools
--   milestone_groups, milestone_types, qualification_dimensions, home_org_member_ids,
--   service_sub (active), research_campaigns (Active), sales_campaigns (Active)
--                       small lookups the open path fetches when its cache is empty — the
--                       prod logs showed service_sub and sales_campaigns re-read on every
--                       open, and one of those stalling held the whole first round

BEGIN;

CREATE OR REPLACE FUNCTION public.lead_open_bundle(p_lead_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
WITH lead AS (
  SELECT * FROM public.leads WHERE id = p_lead_id
),
start_org AS (
  -- The organisation loadLeadInteractions starts its chain from: the target
  -- organisation, else the site's organisation.
  SELECT coalesce(l.target_org_id, s.organisation_id) AS org_id
    FROM lead l LEFT JOIN public.sites s ON s.id = l.site_id
),
chain AS (
  -- The organisation and its ancestors via parent_org_id, nearest first. A missing
  -- organisation row still contributes its own id (the client did the same), and a
  -- cycle is cut by the path check.
  WITH RECURSIVE up AS (
    SELECT so.org_id AS id, 0 AS depth, ARRAY[so.org_id] AS path
      FROM start_org so WHERE so.org_id IS NOT NULL
    UNION ALL
    SELECT o.parent_org_id, up.depth + 1, up.path || o.parent_org_id
      FROM up JOIN public.organisations o ON o.id = up.id
     WHERE o.parent_org_id IS NOT NULL AND NOT (o.parent_org_id = ANY(up.path))
  )
  SELECT id, depth FROM up
),
own_eng AS (
  SELECT e.* FROM public.engagements e WHERE e.lead_id = p_lead_id
)
SELECT jsonb_build_object(
  'generated_at', now(),
  'lead_id', p_lead_id,
  'lead', (SELECT to_jsonb(l) FROM lead l),
  'site', (SELECT to_jsonb(s) FROM lead l JOIN public.sites s ON s.id = l.site_id),
  'org',  (SELECT to_jsonb(o) FROM lead l JOIN public.organisations o ON o.id = l.target_org_id),

  'description_log', (SELECT coalesce(jsonb_agg(to_jsonb(d) ORDER BY d.created_at DESC, d.id DESC), '[]'::jsonb)
                        FROM public.lead_description_log d WHERE d.lead_id = p_lead_id),
  'service_estimates', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.id), '[]'::jsonb)
                          FROM public.lead_service_estimates x WHERE x.lead_id = p_lead_id),

  'engagements', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.engagement_date DESC, e.created_at DESC), '[]'::jsonb)
                    FROM own_eng e),
  'org_chain', (SELECT coalesce(jsonb_agg(c.id ORDER BY c.depth), '[]'::jsonb) FROM chain c),
  'group_engagements', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.engagement_date DESC), '[]'::jsonb)
                          FROM public.engagements e WHERE e.org_id IN (SELECT id FROM chain)),
  'milestones', (SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.id), '[]'::jsonb)
                   FROM public.engagement_milestones m WHERE m.engagement_id IN (SELECT id FROM own_eng)),

  'cadence_steps', (SELECT coalesce(jsonb_agg(to_jsonb(cs) ORDER BY cs.step_no), '[]'::jsonb)
                      FROM lead l JOIN public.campaign_cadence_steps cs ON cs.research_campaign_id = l.research_campaign_id),
  'campaign_name', (SELECT rc.name FROM lead l JOIN public.research_campaigns rc ON rc.id = l.research_campaign_id),

  'red_flag_links', (SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) FROM public.lead_red_flags r WHERE r.lead_id = p_lead_id),
  'strategic_decision_links', (SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) FROM public.lead_strategic_decisions r WHERE r.lead_id = p_lead_id),
  'stage_request', (SELECT to_jsonb(q) FROM public.lead_stage_requests q
                     WHERE q.lead_id = p_lead_id AND q.status = 'pending' AND q.request_type IN ('hold', 'nurture')
                     ORDER BY q.requested_at DESC LIMIT 1),

  'red_flags', (SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.sort_order, f.name), '[]'::jsonb) FROM public.red_flags f WHERE f.active = true),
  'strategic_decisions', (SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.sort_order, f.name), '[]'::jsonb) FROM public.strategic_decisions f WHERE f.active = true),
  'milestone_groups', (SELECT coalesce(jsonb_agg(to_jsonb(g) ORDER BY g.sort_order, g.id), '[]'::jsonb) FROM public.milestone_groups g),
  'milestone_types',  (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.sort_order, t.id), '[]'::jsonb) FROM public.milestone_types t),
  'qualification_dimensions', (SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.sort_order), '[]'::jsonb) FROM public.qualification_dimensions q),
  'home_org_member_ids', (SELECT coalesce(jsonb_agg(jsonb_build_object('person_id', h.person_id)), '[]'::jsonb) FROM public.home_organisation_members h),
  'service_sub', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.name), '[]'::jsonb) FROM public.service_sub x WHERE x.active = true),
  'research_campaigns', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.name), '[]'::jsonb) FROM public.research_campaigns x WHERE x.status = 'Active'),
  'sales_campaigns', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.name), '[]'::jsonb) FROM public.sales_campaigns x WHERE x.status = 'Active')
);
$$;

REVOKE ALL ON FUNCTION public.lead_open_bundle(bigint) FROM public;
GRANT EXECUTE ON FUNCTION public.lead_open_bundle(bigint) TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verify (Dev):
--   SELECT k, jsonb_typeof(v) AS t, CASE WHEN jsonb_typeof(v) = 'array' THEN jsonb_array_length(v) END AS n
--     FROM jsonb_each(public.lead_open_bundle(<lead id>)) AS x(k, v) ORDER BY k;
