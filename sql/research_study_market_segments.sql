-- Focus CRM — Research Studies: multiple Market Segments
-- A study can span several sectors. Adds industry_sector_ids[] and backfills it
-- from the existing single industry_sector_id (kept as the primary). Additive +
-- idempotent. Run on Dev first; Prod at promotion.

alter table sales_campaigns add column if not exists industry_sector_ids bigint[];

update sales_campaigns
   set industry_sector_ids = array[industry_sector_id]
 where industry_sector_id is not null
   and industry_sector_ids is null;
