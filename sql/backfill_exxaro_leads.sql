-- Richard 2026-11-04: "the customer exaro has opportunities that were created in opportunities and not
-- leads. this means there is no record in leads. Please give me a plan to update the database to show
-- these as having been leads first to suit the one created as a lead".
--
-- The model is lead 4157 → deal 4287 "Exxaro Resources - Control Room Build" (promoted by Lesley-Anne on
-- 2026-08-19). Deals 4294 "CR Operator Training" and 4295 "Control Room Operators Annuity" (both Exxaro
-- Resources 4173, site 83 Matla, Lesley-Anne, captured directly on 2026-10-01) have no lead behind them.
--
-- What this does, in ONE attributed transaction (Claude Code, people 4128, for Richard, people 1;
-- focus.system set so the Last Touch triggers stay silent and the stamps below are written by hand):
--   • one NEW lead per deal, shaped exactly as commitPromotion() leaves a promoted lead: status Promoted,
--     origin Client Expansion (3003) via Xone (source_org_id 1) like every Exxaro lead, target org 4173,
--     site 83, Rudzani Netshiendelulu (4117) as the contact, the deal's region / branch / service, all four
--     gates Strong, est_value = the deal's opportunity stream, general_notes = the deal's notes (promotion
--     copies General Notes onto the deal, so the mirror is exact), promoted_deal_id = the deal;
--   • the lead's stage trail (New → Working → Qualified → Promoted) as reconstructed lead_stage_events
--     rows (source 'backfill'), the trigger silenced for the insert so no row stamped "now" survives;
--   • a 'Promotion' engagement on each deal ("Promoted from lead #n: …", activity type 8, stream Sales)
--     as the HEAD of the deal's Sales stream: the deal's first real engagement (4736 / 4734, dated
--     2026-10-09, today the head carrying the Sales label) is re-pointed under it, as on 4287;
--   • Rudzani (4117) as a deal contact on both deals — promotion always writes the Q3 contact and both
--     deals have none today — and the owner collaborator row where it is missing;
--   • one INTERNAL 'Note' engagement on each lead recording the backfill (work_mode internal: our own
--     bookkeeping, never a client contact, so Last Contact is untouched).
-- Timestamps (Option A, recommended): the lead is born two minutes before its deal and promoted ten
-- seconds after it — the shape of a lead created and promoted in one sitting, which is what happened in
-- substance. Nothing is pre-dated to August.
-- Idempotent: every statement is guarded by the state it expects (a deal that already has a lead is
-- skipped). PROD only — DEV holds neither deal (it was cloned on 2026-09-30, the deals were captured on
-- 2026-10-01). Dry run on PROD in a rolled-back transaction by Claude 2026-11-04: leads 4252 / 4253,
-- promotion engagements 4899 / 4900, trails and streams as intended, 14 audit rows, nothing kept.
-- NOT RUN LIVE — awaiting Richard's approval of the plan.

BEGIN;
SELECT set_config('request.headers', '{"x-actor-id":"4128","x-real-actor-id":"1"}', true);
SELECT set_config('focus.system', 'data-fix', true);

-- The stage-event trigger would stamp the insert "now"; the trail is reconstructed by hand below.
ALTER TABLE leads DISABLE TRIGGER leads_log_stage_event;

CREATE TEMP TABLE t_map (deal_id bigint PRIMARY KEY, lead_id bigint, promo_id bigint, t0 timestamptz) ON COMMIT DROP;

-- 1. One lead per deal, as promotion leaves it
WITH ins AS (
  INSERT INTO leads (status, owner_id, created_by, created_at, updated_at,
                     source_id, source_org_id,
                     target_org_id, site_id, target_person_id,
                     region_id, branch_id, service_major_id, service_sub_id, service_major_ids,
                     fit, trigger_score, access, capacity,
                     general_notes, est_value,
                     working_at, first_engaged_at, qualified_at, promoted_at, promoted_deal_id,
                     last_touch_date, last_touch_at, last_touch_by,
                     contacts, additional_contacts, is_hq)
  SELECT 'Promoted', d.owner_id, d.created_by, d.created_at - interval '2 minutes', d.created_at + interval '10 seconds',
         3003, 1,
         d.org_id, d.site_id, 4117,
         d.region_id, d.branch_id, d.service_major_id, d.service_sub_id, ARRAY[d.service_major_id],
         2, 2, 2, 2,
         nullif(d.notes, ''),
         (SELECT sum(m.opportunity_revenue) FROM revenue_streams s JOIN revenue_stream_months m ON m.stream_id = s.id
           WHERE s.deal_id = d.id AND s.stream_type = 'opportunity'),
         d.created_at - interval '2 minutes', d.created_at - interval '2 minutes', d.created_at - interval '2 minutes',
         d.created_at + interval '10 seconds', d.id,
         d.created_at::date, d.created_at + interval '10 seconds', d.owner_id,
         '[]'::jsonb, '[]'::jsonb, false
    FROM deals d
   WHERE d.id IN (4294, 4295) AND d.org_id = 4173
     AND NOT EXISTS (SELECT 1 FROM leads l WHERE l.promoted_deal_id = d.id)
  RETURNING id, promoted_deal_id, promoted_at)
INSERT INTO t_map (deal_id, lead_id, t0) SELECT promoted_deal_id, id, promoted_at - interval '10 seconds' FROM ins;

ALTER TABLE leads ENABLE TRIGGER leads_log_stage_event;

-- 2. The reconstructed stage trail (the same four steps lead 4157 shows)
INSERT INTO lead_stage_events (lead_id, from_status, to_status, at, actor_id, source)
SELECT m.lead_id, v.from_s, v.to_s, m.t0 + v.off, 4105, 'backfill'
  FROM t_map m
  CROSS JOIN LATERAL (VALUES (NULL,        'New',       interval '-2 minutes'),
                             ('New',       'Working',   interval '-2 minutes' + interval '1 second'),
                             ('Working',   'Qualified', interval '-2 minutes' + interval '2 seconds'),
                             ('Qualified', 'Promoted',  interval '10 seconds')) AS v(from_s, to_s, off)
ON CONFLICT DO NOTHING;

-- 3. The Promotion engagement on each deal, then made the head of its Sales stream
WITH ins AS (
  INSERT INTO engagements (deal_id, engagement_date, engagement_type, activity_type_id, notes,
                           next_action, next_action_done, created_by, created_at, work_mode, contacts)
  SELECT m.deal_id, m.t0::date, 'Promotion', 8,
         'Promoted from lead #' || m.lead_id || ': ' || coalesce(nullif(d.notes, ''), ''),
         NULL, true, d.owner_id, m.t0 + interval '9 seconds', 'client', '[]'::jsonb
    FROM t_map m JOIN deals d ON d.id = m.deal_id
   WHERE NOT EXISTS (SELECT 1 FROM engagements e WHERE e.deal_id = m.deal_id AND e.engagement_type = 'Promotion')
  RETURNING id, deal_id)
UPDATE t_map m SET promo_id = ins.id FROM ins WHERE ins.deal_id = m.deal_id;

UPDATE engagements e SET stream_id = m.promo_id, stream_label = 'Sales'
  FROM t_map m WHERE e.id = m.promo_id;

-- the deal's existing Sales stream (its first engagement was the head) now hangs under the Promotion row
UPDATE engagements e
   SET stream_id = m.promo_id,
       stream_label = NULL,
       related_interaction_id = CASE WHEN e.id = e.stream_id THEN m.promo_id ELSE e.related_interaction_id END
  FROM t_map m
 WHERE e.deal_id = m.deal_id AND m.promo_id IS NOT NULL AND e.id <> m.promo_id
   AND e.stream_id IN (SELECT h.id FROM engagements h WHERE h.deal_id = m.deal_id AND h.stream_label = 'Sales' AND h.id <> m.promo_id);

-- 4. The contact and the owner collaborator promotion always writes
INSERT INTO deal_contacts (deal_id, person_id, dmu_role_id, note, is_primary, created_at)
SELECT m.deal_id, 4117, NULL, '', false, m.t0 + interval '1 second' FROM t_map m
 WHERE NOT EXISTS (SELECT 1 FROM deal_contacts dc WHERE dc.deal_id = m.deal_id AND dc.person_id = 4117);

INSERT INTO deal_collaborators (deal_id, person_id, role, is_owner)
SELECT m.deal_id, d.owner_id, 'Owner', true FROM t_map m JOIN deals d ON d.id = m.deal_id
 WHERE d.owner_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM deal_collaborators c WHERE c.deal_id = m.deal_id AND c.person_id = d.owner_id);

-- 5. The record of the backfill, on each lead (internal: never a client contact)
INSERT INTO engagements (lead_id, engagement_date, engagement_type, activity_type_id, notes,
                         next_action_done, created_by, created_at, work_mode, contacts)
SELECT m.lead_id, current_date, 'Note', 7,
       'Lead record backfilled by Richard Groenewald on ' || to_char(current_date, 'YYYY-MM-DD') || ' (recorded by Claude Code): '
       || 'opportunity #' || m.deal_id || ' "' || d.name || '" was captured directly in Opportunities on '
       || to_char(d.created_at, 'YYYY-MM-DD') || '; this lead and its promotion were reconstructed so the Exxaro record reads as its sibling lead 4157 does.',
       true, 1, now(), 'internal', '[]'::jsonb
  FROM t_map m JOIN deals d ON d.id = m.deal_id;

-- Checks (collected into a temp table so the SQL editor and the MCP tool show them whole)
CREATE TEMP TABLE t_out ON COMMIT DROP AS
SELECT 'map' AS what, string_agg(deal_id || '→ lead ' || lead_id || ' · promo eng ' || coalesce(promo_id::text, '-'), ', ' ORDER BY deal_id) AS detail FROM t_map
UNION ALL
SELECT 'lead ' || l.id, l.status || ' · src ' || l.source_id || ' · org ' || l.target_org_id || ' · site ' || l.site_id || ' · person ' || l.target_person_id
       || ' · est ' || coalesce(l.est_value::text, '-') || ' · created ' || l.created_at || ' · promoted ' || l.promoted_at || ' → deal ' || l.promoted_deal_id
       || ' · touch ' || l.last_touch_date || ' · engs ' || (SELECT count(*) FROM engagements e WHERE e.lead_id = l.id)
  FROM leads l JOIN t_map m ON m.lead_id = l.id
UNION ALL
SELECT 'trail ' || m.lead_id, string_agg(coalesce(s.from_status, '∅') || '>' || s.to_status || ' @ ' || to_char(s.at, 'HH24:MI:SS') || ' (' || s.source || ')', ', ' ORDER BY s.at)
  FROM t_map m JOIN lead_stage_events s ON s.lead_id = m.lead_id GROUP BY m.lead_id
UNION ALL
SELECT 'stream ' || m.deal_id, string_agg(e.id || ':' || e.engagement_type || ' ' || e.engagement_date || ' stream ' || e.stream_id || coalesce(' [' || e.stream_label || ']', '') || coalesce(' ←' || e.related_interaction_id, ''), ', ' ORDER BY e.created_at)
  FROM t_map m JOIN engagements e ON e.deal_id = m.deal_id GROUP BY m.deal_id
UNION ALL
SELECT 'contacts ' || m.deal_id, string_agg(dc.person_id::text, ', ') FROM t_map m JOIN deal_contacts dc ON dc.deal_id = m.deal_id GROUP BY m.deal_id
UNION ALL
SELECT 'audit', count(*)::text || ' rows by actor 4128 (real actor 1) in this run' FROM audit_log a WHERE a.actor_id = 4128 AND a.at > now() - interval '1 minute'
UNION ALL
SELECT 'family contact 4173', v.last_contact || ' via ' || v.via_kind || ' ' || v.via_id || ' ' || v.via_label FROM v_org_contact v WHERE v.org_id = 4173;
SELECT * FROM t_out;
COMMIT;
