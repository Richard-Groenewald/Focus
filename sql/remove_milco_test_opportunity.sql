-- Richard 2026-10-31: "milco has an opportunity... give me the audit log of how it got there" → "Yes, clean it up".
-- Deal 4296 "Milco SA (Pty) Ltd — Control Room" was a test of the promotion flow run on PRODUCTION on
-- 2026-10-29 12:06–12:13 UTC by Richard (actor 1) on Lesley-Anne's Raw lead 4216 (captured 2026-10-19,
-- source Referral, source person Vagn Nielsen): a placeholder contact "adfsdf WEFrg" (A@A), an Email
-- engagement noted "ASDFGHJKGFD", all four gates Strong, service Control Room, site "we", Qualified,
-- then promoted directly — creating site 105, person 4130, deal 4296 with an empty opportunity stream,
-- a quote with three posts, two deal engagements (the carried Call and the Promotion row), a deal
-- contact, a collaborator row and three lead stage events. Nothing on it was real.
--
-- This removes all of it and returns lead 4216 to Lesley-Anne's capture state. PROD only, attributed
-- to Claude Code (people 4128) for Richard (people 1); focus.system set so the Last Touch triggers
-- stay silent (the lead's Last Touch is restored to her 19 October edit). Idempotent: guarded.

BEGIN;
SELECT set_config('request.headers', '{"x-actor-id":"4128","x-real-actor-id":"1"}', true);
SELECT set_config('focus.system', 'data-fix', true);

-- 1. The quote the promotion created, and its posts
DELETE FROM public.quote_posts WHERE quote_id IN (SELECT id FROM public.quote_quotes WHERE deal_id = 4296);
DELETE FROM public.quote_quotes WHERE deal_id = 4296;

-- 2. The three test engagements (deal 4824 carried Call, 4825 Promotion row; lead 4823 "ASDFGHJKGFD")
DELETE FROM public.engagement_people WHERE engagement_id IN (4823, 4824, 4825);
DELETE FROM public.engagements WHERE id IN (4824, 4825) AND deal_id = 4296;
DELETE FROM public.engagements WHERE id = 4823 AND lead_id = 4216;

-- 3. The deal and what hangs off it (leads.promoted_deal_id is SET NULL by its FK)
DELETE FROM public.deal_contacts WHERE deal_id = 4296;
DELETE FROM public.deal_collaborators WHERE deal_id = 4296;
DELETE FROM public.revenue_stream_months WHERE stream_id IN (SELECT id FROM public.revenue_streams WHERE deal_id = 4296);
DELETE FROM public.revenue_streams WHERE deal_id = 4296;
DELETE FROM public.deals WHERE id = 4296 AND name = 'Milco SA (Pty) Ltd — Control Room';

-- 4. The lead back to Lesley-Anne's capture of 2026-10-19 (Raw, Referral, source person kept, nothing else)
UPDATE public.leads
   SET status = 'New', fit = 0, access = 0, capacity = 0, trigger_score = 0,
       contacts = '[]'::jsonb, additional_contacts = '[]'::jsonb,
       next_action = NULL, next_action_date = NULL, first_engaged_at = NULL, last_touch_date = NULL,
       working_at = NULL, working_eligible_at = NULL, qualified_at = NULL, promoted_at = NULL, promoted_deal_id = NULL,
       service_major_id = NULL, service_sub_id = NULL, service_major_ids = NULL,
       site_id = NULL, site_name = NULL, target_org_id = NULL, target_person_id = NULL,
       branch_id = NULL, region_id = NULL,
       last_touch_at = '2026-10-19 14:41:28+00', last_touch_by = 4105,
       updated_at = '2026-10-19 14:41:28+00'
 WHERE id = 4216 AND created_by = 4105 AND status = 'Promoted';

-- 5. The stage events the test wrote (394 is her capture; the status change above wrote one more)
DELETE FROM public.lead_stage_events WHERE lead_id = 4216 AND id <> 394;

-- 6. The placeholder person and site
DELETE FROM public.person_organisation_roles WHERE person_id = 4130;
DELETE FROM public.people WHERE id = 4130 AND first_name = 'adfsdf' AND last_name = 'WEFrg';
DELETE FROM public.sites WHERE id = 105 AND name = 'we' AND organisation_id = 4223;

-- Checks
SELECT 'deal_left' AS what, count(*)::text AS n FROM public.deals WHERE id = 4296
UNION ALL SELECT 'engs_left', count(*)::text FROM public.engagements WHERE id IN (4823, 4824, 4825)
UNION ALL SELECT 'quotes_left', count(*)::text FROM public.quote_quotes WHERE deal_id = 4296
UNION ALL SELECT 'person_left', count(*)::text FROM public.people WHERE id = 4130
UNION ALL SELECT 'site_left', count(*)::text FROM public.sites WHERE id = 105
UNION ALL SELECT 'stage_events', string_agg(id::text || ':' || to_status, ',') FROM public.lead_stage_events WHERE lead_id = 4216
UNION ALL SELECT 'lead', status || ' org=' || coalesce(target_org_id::text, 'none') || ' site=' || coalesce(site_id::text, 'none') || ' gates=' || fit || access || capacity || trigger_score || ' src_person=' || coalesce(source_person_id::text, 'none') || ' touch=' || coalesce(last_touch_at::text, 'none') || ' by ' || coalesce(last_touch_by::text, 'none') || ' contact=' || coalesce(last_touch_date::text, 'none') FROM public.leads WHERE id = 4216
UNION ALL SELECT 'milco_family_contact', last_contact::text || ' via ' || via_kind || ' ' || via_id || ' ' || via_label FROM public.v_org_contact WHERE org_id = 4223;
COMMIT;
