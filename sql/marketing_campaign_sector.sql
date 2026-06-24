-- Focus CRM — Marketing Campaigns (research_campaigns): Sector field
-- The "Target segment" free-text field becomes an Industry Sector dropdown.
-- Additive + idempotent. Run on Dev first; Prod at promotion.
-- (Legacy `segment` column kept; display falls back to it where no sector is set.)

alter table research_campaigns add column if not exists industry_sector_id bigint references industry_sectors(id);
