-- Focus v7.9.38 — performance Tier 2, part 2: engagements_labelled view
-- (2026-09-10). Rationale: Tier 2.6 in docs/perf-review/PERFORMANCE_REVIEW.md
-- (findings EH-1, RPT-1, MIL-1, ATT-1, IA-1, D9).
--
-- Engagement History resolved every label in the browser: the engagement rows,
-- then deals + leads + engagement_people + milestones + stream roots, then
-- people + organisations — three dependent rounds per open and per date or
-- category change. This view carries every one of those labels on the row, so
-- the page reads it in ONE call with the same filters it already sends:
--   apiGet('engagements_labelled', 'lead_id=not.is.null&engagement_date=gte.…&select=*&order=engagement_date.desc,id.desc&limit=1000')
-- The client (v7.9.38) falls back to the old reads when the view is absent
-- (404 / PGRST205), so this file can ship before or after the deploy.
-- Plain view (no data copied, nothing to refresh). Idempotent. Dev first, then prod.
--
-- Label rules mirror index.html exactly (keep them in step):
--   cat / lost              _engHistCat: lead → Outreach; stage 6 → Sales + lost;
--                           stages 5/7/8 → Project when service_sub.is_recurring = false else Contract;
--                           anything else → Sales; no parent → NULL (the page drops such rows)
--   stream_root             stream_id, else the row's own id
--   stream_label_resolved   the ROOT row's stream_label (NULL → the page shows "Stream #<root>")
--   client_name             lead: org name by target_org_id, else target_org_name; deal: org name — else "—"
--   parent_label            lead: leadEngLabel — site name, site_name, target_org_name, description, "Lead #n";
--                           deal: name, "Deal #n"
--   owner_id / owner_name   the parent's owner; "Person #n" when the people row is missing; "—" when none
--   persons                 engagement_people names; a lead engagement with none falls back to the
--                           lead's target person (by id, else the typed name)
--   milestones              every engagement_milestones row for the engagement (badges)

BEGIN;

CREATE OR REPLACE VIEW public.engagements_labelled AS
SELECT e.*,
       CASE WHEN e.lead_id IS NOT NULL THEN 'lead' WHEN e.deal_id IS NOT NULL THEN 'deal' END AS parent_kind,
       coalesce(e.lead_id, e.deal_id)                                              AS parent_id,
       CASE WHEN e.lead_id IS NOT NULL THEN 'Outreach'
            WHEN d.id IS NULL THEN NULL
            WHEN d.stage_id = 6 THEN 'Sales'
            WHEN d.stage_id IN (5, 7, 8) THEN CASE WHEN ss.is_recurring = false THEN 'Project' ELSE 'Contract' END
            ELSE 'Sales' END                                                       AS cat,
       (e.lead_id IS NULL AND d.stage_id = 6)                                      AS lost,
       coalesce(e.stream_id, e.id)                                                 AS stream_root,
       nullif(root.stream_label, '')                                               AS stream_label_resolved,
       CASE WHEN e.lead_id IS NOT NULL THEN coalesce(nullif(o_l.name, ''), nullif(l.target_org_name, ''), '—')
            ELSE coalesce(nullif(o_d.name, ''), '—') END                           AS client_name,
       CASE WHEN e.lead_id IS NOT NULL
            THEN coalesce(nullif(s_l.name, ''), nullif(trim(l.site_name), ''), nullif(l.target_org_name, ''),
                          nullif(l.description, ''), 'Lead #' || e.lead_id)
            ELSE coalesce(nullif(d.name, ''), 'Deal #' || e.deal_id) END           AS parent_label,
       coalesce(l.owner_id, d.owner_id)                                            AS owner_id,
       CASE WHEN coalesce(l.owner_id, d.owner_id) IS NULL THEN '—'
            ELSE coalesce(nullif(trim(concat_ws(' ', p_o.first_name, p_o.last_name)), ''),
                          'Person #' || coalesce(l.owner_id, d.owner_id)) END      AS owner_name,
       coalesce(pp.persons,
                CASE WHEN e.lead_id IS NOT NULL AND l.target_person_id IS NOT NULL
                     THEN jsonb_build_array(coalesce(nullif(trim(concat_ws(' ', p_t.first_name, p_t.last_name)), ''),
                                                     'Person #' || l.target_person_id))
                     WHEN e.lead_id IS NOT NULL AND nullif(l.target_person_name, '') IS NOT NULL
                     THEN jsonb_build_array(l.target_person_name)
                     ELSE '[]'::jsonb END)                                         AS persons,
       coalesce(mm.milestones, '[]'::jsonb)                                        AS milestones
  FROM public.engagements e
  LEFT JOIN public.leads l           ON l.id = e.lead_id
  LEFT JOIN public.sites s_l         ON s_l.id = l.site_id
  LEFT JOIN public.organisations o_l ON o_l.id = l.target_org_id
  LEFT JOIN public.people p_t        ON p_t.id = l.target_person_id
  LEFT JOIN public.deals d           ON d.id = e.deal_id
  LEFT JOIN public.organisations o_d ON o_d.id = d.org_id
  LEFT JOIN public.service_sub ss    ON ss.id = d.service_sub_id
  LEFT JOIN public.people p_o        ON p_o.id = coalesce(l.owner_id, d.owner_id)
  LEFT JOIN public.engagements root  ON root.id = coalesce(e.stream_id, e.id)
  LEFT JOIN LATERAL (
       SELECT jsonb_agg(coalesce(nullif(trim(concat_ws(' ', p.first_name, p.last_name)), ''), 'Person #' || ep.person_id)
                        ORDER BY ep.id) AS persons
         FROM public.engagement_people ep
         LEFT JOIN public.people p ON p.id = ep.person_id
        WHERE ep.engagement_id = e.id) pp ON true
  LEFT JOIN LATERAL (
       SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) AS milestones
         FROM public.engagement_milestones m
        WHERE m.engagement_id = e.id) mm ON true;

COMMIT;

-- Verify (Dev):
--   SELECT count(*) FROM public.engagements_labelled;                       -- = count(*) FROM engagements
--   SELECT id, cat, lost, stream_root, stream_label_resolved, client_name, parent_label, owner_name, persons, milestones
--     FROM public.engagements_labelled ORDER BY engagement_date DESC, id DESC LIMIT 5;
--   EXPLAIN ANALYZE SELECT * FROM public.engagements_labelled
--     WHERE lead_id IS NOT NULL AND engagement_date >= current_date - 180
--     ORDER BY engagement_date DESC, id DESC LIMIT 1000;                     -- uses engagements_lead_date_idx / engagements_date_id_idx
