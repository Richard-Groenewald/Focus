-- Focus CRM — Research Studies (sales_campaigns) expanded fields
-- ----------------------------------------------------------------------------
-- Adds Purpose + Industry Sector to sales_campaigns, and participant junctions
-- (a study can involve multiple organisations and multiple people).
-- Additive + idempotent. Run on Dev first; Prod at promotion.
-- ----------------------------------------------------------------------------

alter table sales_campaigns add column if not exists purpose text;
alter table sales_campaigns add column if not exists industry_sector_id bigint references industry_sectors(id);

create table if not exists sales_campaign_organisations (
  id                bigserial primary key,
  sales_campaign_id bigint not null references sales_campaigns(id) on delete cascade,
  organisation_id   bigint not null references organisations(id)  on delete cascade,
  created_at        timestamptz not null default now(),
  unique (sales_campaign_id, organisation_id)
);

create table if not exists sales_campaign_people (
  id                bigserial primary key,
  sales_campaign_id bigint not null references sales_campaigns(id) on delete cascade,
  person_id         bigint not null references people(id)         on delete cascade,
  created_at        timestamptz not null default now(),
  unique (sales_campaign_id, person_id)
);
