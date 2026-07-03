-- Sites — the natural unit users talk in ("Access World West Gate") sitting
-- between organisation (legal/billing entity) and deal.
-- Design: memory quote-cardinality (organisations 1:N sites) + this session.
--
-- Cardinality:  organisations 1─N sites 1─N leads/deals
-- Progressive:  site_id is soft at lead stage, firms up by opportunity.
--               sites.organisation_id is NULLABLE at birth (a lead may name a
--               site before the org is nailed down) and set once the org is known.
-- NOTE: address/geo live HERE, not on the org — kills duplication for multi-site
--       clients and later feeds the geographic_region concept.
-- Dev only (additive; safe to run under the currently-deployed app).

begin;

-- 1) The entity. House conventions: BIGSERIAL / TIMESTAMPTZ / people(id) audit.
create table if not exists sites (
  id              bigserial primary key,
  organisation_id bigint references organisations(id) on delete restrict,  -- nullable: progressive
  name            text not null,

  -- Physical address (mirrors the organisations physical block)
  physical_line1  text,
  physical_line2  text,
  physical_line3  text,
  physical_line4  text,
  physical_code   text,
  province        text,
  country         text default 'South Africa',

  -- Geo (room for later)
  latitude        numeric,
  longitude       numeric,

  is_primary      boolean not null default false,  -- the org's default/"same as company" site
  active          boolean not null default true,
  notes           text,

  owner_id        bigint references people(id),
  created_by      bigint references people(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists sites_org_idx on sites (organisation_id);

-- 2) Wire sites onto leads + deals. ON DELETE SET NULL so removing a site never
--    blocks a lead/deal — it just falls back to showing the org.
alter table leads add column if not exists site_id bigint references sites(id) on delete set null;
alter table deals add column if not exists site_id bigint references sites(id) on delete set null;

-- Prospective site name on a lead: mirrors target_org_name. A lead can NAME a site
-- ("West Gate") before it exists as a row — it materialises into a real sites row on
-- promotion, exactly as a typed new organisation does. Deals never need this (the org
-- is always known by opportunity stage, so a site row can be created immediately).
alter table leads add column if not exists site_name text;

create index if not exists leads_site_idx on leads (site_id);
create index if not exists deals_site_idx on deals (site_id);

-- 3) Backfill. For every org that currently has a deal or lead, create ONE default
--    site named after the org (carrying its physical address) — the "same as company"
--    site for 1:1 clients. Idempotent: skip orgs that already have any site.
insert into sites (organisation_id, name, is_primary,
                   physical_line1, physical_line2, physical_line3, physical_line4,
                   physical_code, province, country)
select o.id, o.name, true,
       o.physical_line1, o.physical_line2, o.physical_line3, o.physical_line4,
       o.physical_code, o.province, coalesce(o.country, 'South Africa')
from organisations o
where (
        exists (select 1 from deals d where d.org_id = o.id)
     or exists (select 1 from leads l where l.target_org_id = o.id)
      )
  and not exists (select 1 from sites s where s.organisation_id = o.id);

-- 4) Link existing deals to their org's primary site.
update deals d
   set site_id = s.id
  from sites s
 where s.organisation_id = d.org_id
   and s.is_primary
   and d.site_id is null;

-- 5) Link existing leads to their target org's primary site.
update leads l
   set site_id = s.id
  from sites s
 where s.organisation_id = l.target_org_id
   and s.is_primary
   and l.target_org_id is not null
   and l.site_id is null;

commit;
