-- Richard 2026-11-01: "I have two opportunities, Welgevonden and Willowton. These need to be demoted
-- to Leads in Nurture. All engagements should be retained." → "include 4292 and 4293, sql for now,
-- build code later" (the Admin-only in-app routine is to be built after 5 November 2026).
--
-- What this does, in ONE attributed transaction (Claude Code, people 4128, for Richard, people 1;
-- focus.system set so the Last Touch triggers stay silent):
--   • 4289 Welgevonden Security Upgrade (Tender)  → back to its source lead 4039
--   • 4286 Willowton control rooms                → back to its source lead 4158
--   • 4292 Willowton National Guarding Contract    → a NEW lead built from the deal
--   • 4293 Willowton Business analysis             → a NEW lead built from the deal
--   For each: every engagement on the deal moves to the lead (milestones and contact links travel
--   with the engagement; stream ids are kept), one 'Demotion' engagement records the reversal, the
--   lead stands in Nurture with a 30-day cadence and its contacts rebuilt from the deal's, and the
--   deal is parked as Lost — "Demoted to lead" — with its revenue stream, quote, probability answers
--   and files kept attached and recoverable. The lead stage trigger logs the status change itself.
-- New leads: owner, organisation, site, region, branch, service and notes from the deal; origin
-- Referral via Matthew Moses' referrer like their sibling lead 4158; gates rated Strong (the deals
-- stood at Prospect 45% and Proposal 80%); estimated value from the deal's revenue stream.
-- Idempotent: every statement is guarded by the state it expects. PROD. Run 2026-11-01.

BEGIN;
SELECT set_config('request.headers', '{"x-actor-id":"4128","x-real-actor-id":"1"}', true);
SELECT set_config('focus.system', 'data-fix', true);

CREATE TEMP TABLE t_map (deal_id bigint PRIMARY KEY, lead_id bigint, created boolean) ON COMMIT DROP;
INSERT INTO t_map
SELECT d.id, l.id, false FROM deals d JOIN leads l ON l.promoted_deal_id = d.id
 WHERE d.id IN (4289, 4286) AND d.stage_id <> 6 AND l.status = 'Promoted';

-- 1. Leads for the two deals that never had one
WITH ins AS (
  INSERT INTO leads (status, owner_id, created_by, created_at, updated_at, source_id, source_person_id,
                     target_org_id, site_id, region_id, branch_id, service_major_id, service_sub_id, service_major_ids,
                     fit, trigger_score, access, capacity, general_notes, working_at, nurture_started_at, nurture_cadence_days,
                     contacts, additional_contacts, est_value, first_engaged_at, last_touch_date, last_touch_at, last_touch_by)
  SELECT 'Nurture', d.owner_id, d.created_by, d.created_at, now(), 3001, 4116,
         d.org_id, d.site_id, d.region_id, d.branch_id, d.service_major_id, d.service_sub_id, ARRAY[d.service_major_id],
         2, 2, 2, 2,
         'Demoted from opportunity #' || d.id || ' "' || d.name || '" on 2026-11-01.' || coalesce(E'\n\n' || nullif(d.notes, ''), ''),
         d.created_at, now(), 30, '[]'::jsonb, '[]'::jsonb,
         (SELECT sum(m.opportunity_revenue) FROM revenue_streams s JOIN revenue_stream_months m ON m.stream_id = s.id WHERE s.deal_id = d.id),
         (SELECT min(e.created_at) FROM engagements e WHERE e.deal_id = d.id),
         (SELECT max(e.engagement_date) FROM engagements e WHERE e.deal_id = d.id AND e.work_mode = 'client' AND e.engagement_date <= current_date),
         (SELECT max(e.created_at) FROM engagements e WHERE e.deal_id = d.id),
         d.owner_id
    FROM deals d
   WHERE d.id = 4292 AND d.stage_id <> 6 AND NOT EXISTS (SELECT 1 FROM leads l WHERE l.promoted_deal_id = d.id)
  RETURNING id)
INSERT INTO t_map SELECT 4292, id, true FROM ins;

WITH ins AS (
  INSERT INTO leads (status, owner_id, created_by, created_at, updated_at, source_id, source_person_id,
                     target_org_id, site_id, region_id, branch_id, service_major_id, service_sub_id, service_major_ids,
                     fit, trigger_score, access, capacity, general_notes, working_at, nurture_started_at, nurture_cadence_days,
                     contacts, additional_contacts, est_value, first_engaged_at, last_touch_date, last_touch_at, last_touch_by)
  SELECT 'Nurture', d.owner_id, d.created_by, d.created_at, now(), 3001, 4116,
         d.org_id, d.site_id, d.region_id, d.branch_id, d.service_major_id, d.service_sub_id, ARRAY[d.service_major_id],
         2, 2, 2, 2,
         'Demoted from opportunity #' || d.id || ' "' || d.name || '" on 2026-11-01.' || coalesce(E'\n\n' || nullif(d.notes, ''), ''),
         d.created_at, now(), 30, '[]'::jsonb, '[]'::jsonb,
         (SELECT sum(m.opportunity_revenue) FROM revenue_streams s JOIN revenue_stream_months m ON m.stream_id = s.id WHERE s.deal_id = d.id),
         (SELECT min(e.created_at) FROM engagements e WHERE e.deal_id = d.id),
         (SELECT max(e.engagement_date) FROM engagements e WHERE e.deal_id = d.id AND e.work_mode = 'client' AND e.engagement_date <= current_date),
         (SELECT max(e.created_at) FROM engagements e WHERE e.deal_id = d.id),
         d.owner_id
    FROM deals d
   WHERE d.id = 4293 AND d.stage_id <> 6 AND NOT EXISTS (SELECT 1 FROM leads l WHERE l.promoted_deal_id = d.id)
  RETURNING id)
INSERT INTO t_map SELECT 4293, id, true FROM ins;

-- the new leads' estimated value, one row per service family from the deal's stream (est_value is derived from these)
INSERT INTO lead_service_estimates (lead_id, service_major_id, monthly_amount, months, amount, start_date, created_at, updated_at)
SELECT m.lead_id, d.service_major_id,
       round(sum(rm.opportunity_revenue) / count(*), 2), count(*), sum(rm.opportunity_revenue),
       (min(rm.month) || '-01')::date, now(), now()
  FROM t_map m JOIN deals d ON d.id = m.deal_id
  JOIN revenue_streams s ON s.deal_id = d.id AND s.stream_type = 'opportunity'
  JOIN revenue_stream_months rm ON rm.stream_id = s.id
 WHERE m.created AND rm.opportunity_revenue IS NOT NULL
 GROUP BY m.lead_id, d.service_major_id;

-- 2. Every engagement on each deal moves to its lead (milestones and people links follow by FK;
--    the next-action refresh trigger re-derives the lead's open action from them)
UPDATE engagements e
   SET lead_id = m.lead_id, deal_id = NULL
  FROM t_map m
 WHERE e.deal_id = m.deal_id;

-- 3. The record of the reversal, on each lead (internal: our own bookkeeping, never client contact)
INSERT INTO engagements (lead_id, engagement_date, engagement_type, stream_label, notes, work_mode, created_by, next_action_done)
SELECT m.lead_id, current_date, 'Demotion', 'Demotion',
       'Demoted from opportunity #' || d.id || ' "' || d.name || '" to a Nurture lead by Richard Groenewald on 2026-11-01 (recorded by Claude Code). '
       || 'Every engagement logged on the opportunity moved here with it; the opportunity is parked as Lost — demoted to lead — '
       || 'with its revenue stream, quote, probability answers and files kept.',
       'internal', 1, true
  FROM t_map m JOIN deals d ON d.id = m.deal_id;

-- 4. The two existing leads come back to life in Nurture, contacts rebuilt from the deal's
UPDATE leads l
   SET status = 'Nurture', nurture_cadence_days = 30, nurture_started_at = now(),
       promoted_deal_id = NULL, promoted_at = NULL, updated_at = now(),
       last_touch_date = (SELECT max(e.engagement_date) FROM engagements e
                           WHERE e.lead_id = l.id AND e.work_mode = 'client' AND e.engagement_date <= current_date),
       contacts = coalesce((
         SELECT jsonb_agg(jsonb_build_object(
                  'cid', c.rn, 'name', c.name, 'email', c.email, 'phone', c.phone, 'phone2', NULL,
                  'job_title', c.job_title, 'person_id', c.id, 'is_primary', c.rn = 1, 'moved', NULL) ORDER BY c.rn)
           FROM (SELECT p.id, trim(coalesce(p.first_name, '') || ' ' || coalesce(p.last_name, '')) AS name, p.email, p.phone,
                        (SELECT r.job_title FROM person_organisation_roles r WHERE r.person_id = p.id ORDER BY r.id DESC LIMIT 1) AS job_title,
                        row_number() OVER (ORDER BY (p.id = l.target_person_id) DESC, p.id) AS rn
                   FROM deal_contacts dc JOIN people p ON p.id = dc.person_id
                  WHERE dc.deal_id = m.deal_id) c), '[]'::jsonb)
  FROM t_map m
 WHERE l.id = m.lead_id AND NOT m.created AND l.status = 'Promoted';

-- 5. The deals leave the pipeline, everything on them kept
UPDATE deals d
   SET stage_id = 6, probability = 0, lost_date = current_date, lost_to = NULL,
       lost_reason = 'Demoted to lead',
       lost_notes = 'Demoted to lead #' || m.lead_id || ' on 2026-11-01 by Richard Groenewald (recorded by Claude Code): every engagement moved to the lead; the revenue stream, quote, probability answers and files stay here.',
       updated_at = now()
  FROM t_map m
 WHERE d.id = m.deal_id AND d.stage_id <> 6;

-- Checks
SELECT 'map' AS what, string_agg(deal_id || '→' || lead_id || CASE WHEN created THEN ' (new)' ELSE '' END, ', ' ORDER BY deal_id) AS detail FROM t_map
UNION ALL
SELECT 'lead ' || l.id, l.status || ' · cadence ' || coalesce(l.nurture_cadence_days::text, '-') || ' · promoted_deal ' || coalesce(l.promoted_deal_id::text, 'none')
       || ' · contacts ' || jsonb_array_length(coalesce(l.contacts, '[]')) || ' · engs ' || (SELECT count(*) FROM engagements e WHERE e.lead_id = l.id)
       || ' · next ' || coalesce(l.next_action || ' ' || l.next_action_date, '-') || ' · contact ' || coalesce(l.last_touch_date::text, '-')
       || ' · est ' || coalesce(l.est_value::text, '-') || ' · org ' || coalesce(l.target_org_id::text, '-') || ' · site ' || coalesce(l.site_id::text, '-')
  FROM leads l JOIN t_map m ON m.lead_id = l.id
UNION ALL
SELECT 'deal ' || d.id, s.name || ' · ' || d.probability || '% · ' || coalesce(d.lost_reason, '') || ' · engs left ' || (SELECT count(*) FROM engagements e WHERE e.deal_id = d.id)
  FROM deals d JOIN stages s ON s.id = d.stage_id JOIN t_map m ON m.deal_id = d.id
UNION ALL
SELECT 'milestones on leads', count(*)::text FROM engagement_milestones em JOIN engagements e ON e.id = em.engagement_id JOIN t_map m ON m.lead_id = e.lead_id
UNION ALL
SELECT 'stage events', string_agg(e.lead_id || ':' || coalesce(e.from_status, '') || '>' || e.to_status, ', ') FROM lead_stage_events e JOIN t_map m ON m.lead_id = e.lead_id WHERE e.at >= now() - interval '1 minute'
UNION ALL
SELECT 'family contact ' || v.org_id, v.last_contact || ' via ' || v.via_kind || ' ' || v.via_id || ' ' || v.via_label FROM v_org_contact v WHERE v.org_id IN (4145, 4172);
COMMIT;
