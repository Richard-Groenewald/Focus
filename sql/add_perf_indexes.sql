-- Performance indexes for growth (2026-07-05).
-- Volumes are small today, so these cost nothing now — they exist so the hot
-- filter paths stay O(log n) as engagements/deals/months accumulate.
-- Idempotent: safe to re-run. Run on Dev first; include in the next prod release.

-- Engagements: deal-side lookups had no index (only lead-side existed), and the
-- Engagement History / outstanding-actions views filter on next_action_done+date.
create index if not exists idx_engagements_deal            on engagements (deal_id);
create index if not exists idx_engagements_next_action     on engagements (next_action_done, next_action_date);

-- Deals: pipeline groups by stage, org pages filter by org, own/other by owner.
create index if not exists idx_deals_org                   on deals (org_id);
create index if not exists idx_deals_stage                 on deals (stage_id);
create index if not exists idx_deals_owner                 on deals (owner_id);

-- Affiliations: contact pickers query by org (the unique key leads on person_id,
-- which doesn't serve org_id=eq.X lookups).
create index if not exists idx_por_org                     on person_organisation_roles (org_id);

-- Child tables fetched per-parent.
create index if not exists idx_lead_red_flags_lead         on lead_red_flags (lead_id);
create index if not exists idx_deal_collaborators_person   on deal_collaborators (person_id);
create index if not exists idx_engagement_people_person    on engagement_people (person_id);
