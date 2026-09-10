-- Focus v7.9.38 — performance Tier 2, part 1: dashboard_summary()
-- (2026-09-10). Rationale: Tier 2.3 in docs/perf-review/PERFORMANCE_REVIEW.md
-- (findings D2, D3, D4, D5, D6, D11).
--
-- The dashboard used to issue ~30 requests per render: leads whole-table four
-- times, deals five times, engagements three times, plus serial 150-id chunk
-- loops for milestones. This returns every dataset the thirteen widgets read in
-- ONE call. The widgets keep their own counting and the Mine / Team / All scope
-- rule (rows carry owner_id, branch_id, region_id), so the numbers are computed
-- exactly as before — only the round trips change.
--
-- The app calls it through the existing proxy:
--   api('rpc/dashboard_summary', 'POST', { p_from: 'YYYY-MM-DD' })
-- and falls back to the per-widget reads when the function is absent
-- (404 / PGRST202), so this file can ship before or after the v7.9.38 deploy.
-- Idempotent. Run on Dev first, then prod.
--
-- Keys returned (all arrays unless noted):
--   leads            every lead, the union of the columns the four widgets read,
--                    with sites:{name} in the PostgREST embed shape
--   deals            id, name, stage_id, probability, owner/branch/region, org_id, service_sub_id
--   orgs             id, parent_org_id, group_touch_soothes, sector_id
--   org_touches      object {"o<org_id>": "YYYY-MM-DD"} — latest non-internal touch (_loadOrgTouches)
--   open_actions     engagements with an open, dated next action
--   promotion_requests / stage_requests   pending rows for Approvals Outstanding
--   pending_milestones (≤100, oldest first) / approved_milestones (≤80, newest decided first)
--                    engagement_milestones rows plus _lead_id, _deal_id, _deal_name / _engagement_date
--   pulse_milestones every pending row plus approved rows dated this month or last month
--   milestone_groups, milestone_types, red_flags, pending_red_flags, campaigns, bugs (≤500),
--   industry_sectors, stages
--   stream_values    per deal: opp_total (opportunity streams' opportunity_revenue),
--                    sec_total (fulfilment streams' secured_revenue) — from revenue streams only
--   interactions     engagements dated >= p_from with _owner_id (parent's owner) and _cat
--                    (Outreach / Sales / Contract / Project — the _engHistCat rule)

BEGIN;

CREATE OR REPLACE FUNCTION public.dashboard_summary(
  p_from date DEFAULT (date_trunc('month', now()) - interval '11 months')::date)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
SELECT jsonb_build_object(
  'generated_at', now(),

  'leads', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', l.id, 'owner_id', l.owner_id, 'branch_id', l.branch_id, 'region_id', l.region_id, 'status', l.status,
      'wake_date', l.wake_date, 'woke_at', l.woke_at, 'created_at', l.created_at, 'last_touch_date', l.last_touch_date,
      'promoted_at', l.promoted_at, 'dead_reason', l.dead_reason, 'working_at', l.working_at,
      'fit', l.fit, 'access', l.access, 'capacity', l.capacity, 'trigger_score', l.trigger_score,
      'service_major_id', l.service_major_id, 'qualification_demoted', l.qualification_demoted,
      'target_org_name', l.target_org_name, 'target_org_id', l.target_org_id, 'description', l.description,
      'site_id', l.site_id, 'site_name', l.site_name, 'next_action_date', l.next_action_date,
      'sites', CASE WHEN s.id IS NULL THEN NULL ELSE jsonb_build_object('name', s.name) END) ORDER BY l.id), '[]'::jsonb)
    FROM public.leads l LEFT JOIN public.sites s ON s.id = l.site_id),

  'deals', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id, 'name', d.name, 'stage_id', d.stage_id, 'probability', d.probability,
      'owner_id', d.owner_id, 'branch_id', d.branch_id, 'region_id', d.region_id,
      'org_id', d.org_id, 'service_sub_id', d.service_sub_id) ORDER BY d.id), '[]'::jsonb)
    FROM public.deals d),

  'orgs', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', o.id, 'parent_org_id', o.parent_org_id, 'group_touch_soothes', o.group_touch_soothes,
      'sector_id', o.sector_id) ORDER BY o.id), '[]'::jsonb)
    FROM public.organisations o),

  'org_touches', (SELECT coalesce(jsonb_object_agg('o' || t.org_id, t.last_touch), '{}'::jsonb)
    FROM (SELECT org_id, max(engagement_date) AS last_touch
            FROM public.engagements
           WHERE org_id IS NOT NULL AND engagement_date IS NOT NULL AND work_mode IS DISTINCT FROM 'internal'
           GROUP BY org_id) t),

  'open_actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'lead_id', e.lead_id, 'deal_id', e.deal_id, 'next_action', e.next_action,
      'next_action_date', e.next_action_date, 'engagement_type', e.engagement_type,
      'stream_id', e.stream_id, 'engagement_date', e.engagement_date) ORDER BY e.id), '[]'::jsonb)
    FROM public.engagements e
   WHERE e.next_action_done = false AND e.next_action_date IS NOT NULL),

  'promotion_requests', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', r.lead_id, 'request_type', r.request_type, 'requested_by', r.requested_by,
      'requested_at', r.requested_at) ORDER BY r.id), '[]'::jsonb)
    FROM public.promotion_requests r WHERE r.status = 'pending'),

  'stage_requests', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'lead_id', r.lead_id, 'request_type', r.request_type, 'requested_by', r.requested_by,
      'requested_at', r.requested_at) ORDER BY r.id), '[]'::jsonb)
    FROM public.lead_stage_requests r WHERE r.status = 'pending' AND r.request_type = 'dead'),

  'pending_milestones', (SELECT coalesce(jsonb_agg(
      to_jsonb(m) || jsonb_build_object('_lead_id', e.lead_id, '_deal_id', e.deal_id, '_deal_name', d.name)
      ORDER BY m.proposed_at ASC, m.id), '[]'::jsonb)
    FROM (SELECT * FROM public.engagement_milestones WHERE status = 'pending'
           ORDER BY proposed_at ASC, id LIMIT 100) m
    JOIN public.engagements e ON e.id = m.engagement_id
    LEFT JOIN public.deals d ON d.id = e.deal_id),

  'approved_milestones', (SELECT coalesce(jsonb_agg(
      to_jsonb(m) || jsonb_build_object('_lead_id', e.lead_id, '_deal_id', e.deal_id, '_engagement_date', e.engagement_date)
      ORDER BY m.decided_at DESC NULLS LAST, m.id DESC), '[]'::jsonb)
    FROM (SELECT * FROM public.engagement_milestones WHERE status = 'approved'
           ORDER BY decided_at DESC NULLS LAST, id DESC LIMIT 80) m
    JOIN public.engagements e ON e.id = m.engagement_id),

  'pulse_milestones', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', m.id, 'engagement_id', m.engagement_id, 'milestone_type_id', m.milestone_type_id,
      'status', m.status, 'decided_at', m.decided_at,
      '_lead_id', e.lead_id, '_deal_id', e.deal_id, '_engagement_date', e.engagement_date) ORDER BY m.id), '[]'::jsonb)
    FROM public.engagement_milestones m
    JOIN public.engagements e ON e.id = m.engagement_id
   WHERE m.status = 'pending'
      OR (m.status = 'approved'
          AND coalesce(e.engagement_date, m.decided_at::date) >= (date_trunc('month', now()) - interval '1 month')::date)),

  'milestone_groups', (SELECT coalesce(jsonb_agg(to_jsonb(g) ORDER BY g.sort_order, g.id), '[]'::jsonb) FROM public.milestone_groups g),
  'milestone_types',  (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.sort_order, t.id), '[]'::jsonb) FROM public.milestone_types t),

  'red_flags', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name) ORDER BY f.sort_order, f.id), '[]'::jsonb)
    FROM public.red_flags f),
  'pending_red_flags', (SELECT coalesce(jsonb_agg(jsonb_build_object('lead_id', x.lead_id, 'red_flag_id', x.red_flag_id)), '[]'::jsonb)
    FROM public.lead_red_flags x WHERE x.review_status = 'pending' AND x.cleared = false),

  'campaigns', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'status', c.status, 'owner_id', c.owner_id, 'created_by', c.created_by) ORDER BY c.id), '[]'::jsonb)
    FROM public.research_campaigns c),

  'bugs', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', b.id, 'severity', b.severity, 'status', b.status, 'description', left(b.description, 300),
      'page', b.page, 'created_at', b.created_at) ORDER BY b.created_at DESC, b.id DESC), '[]'::jsonb)
    FROM (SELECT * FROM public.bug_reports ORDER BY created_at DESC, id DESC LIMIT 500) b),

  -- Financials come from revenue streams only (never base amount / num months).
  'stream_values', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'deal_id', v.deal_id, 'opp_total', v.opp_total, 'sec_total', v.sec_total) ORDER BY v.deal_id), '[]'::jsonb)
    FROM (SELECT rs.deal_id,
                 sum(CASE WHEN rs.stream_type = 'opportunity' THEN coalesce(m.opportunity_revenue, 0) ELSE 0 END) AS opp_total,
                 sum(CASE WHEN rs.stream_type = 'fulfilment'  THEN coalesce(m.secured_revenue, 0)     ELSE 0 END) AS sec_total
            FROM public.revenue_streams rs
            JOIN public.revenue_stream_months m ON m.stream_id = rs.id
           GROUP BY rs.deal_id) v),

  'interactions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'lead_id', e.lead_id, 'deal_id', e.deal_id, 'engagement_date', e.engagement_date,
      'engagement_type', e.engagement_type, 'created_by', e.created_by,
      '_owner_id', coalesce(l.owner_id, d.owner_id),
      '_cat', CASE WHEN e.lead_id IS NOT NULL THEN 'Outreach'
                   WHEN d.stage_id IN (5, 7, 8) THEN CASE WHEN ss.is_recurring = false THEN 'Project' ELSE 'Contract' END
                   ELSE 'Sales' END) ORDER BY e.engagement_date, e.id), '[]'::jsonb)
    FROM public.engagements e
    LEFT JOIN public.leads l        ON l.id = e.lead_id
    LEFT JOIN public.deals d        ON d.id = e.deal_id
    LEFT JOIN public.service_sub ss ON ss.id = d.service_sub_id
   WHERE e.engagement_date >= p_from),

  'industry_sectors', (SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.id), '[]'::jsonb) FROM public.industry_sectors s),
  'stages', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) ORDER BY s.id), '[]'::jsonb) FROM public.stages s)
);
$$;

COMMIT;

-- Verify (Dev):
--   SELECT length(public.dashboard_summary()::text) AS bytes;           -- payload size, uncompressed
--   SELECT k, jsonb_typeof(v) AS t, CASE WHEN jsonb_typeof(v) = 'array' THEN jsonb_array_length(v) END AS n
--     FROM jsonb_each(public.dashboard_summary()) AS x(k, v) ORDER BY k;
--   SELECT public.dashboard_summary('2026-08-01') -> 'interactions' -> 0;
