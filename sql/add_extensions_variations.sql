-- Extensions & Variations (deal lineage) — additive schema only.
-- Run once against each Supabase DB (SQL editor or psql). Safe to re-run.
--
-- A contract is a deals row at stage 5 (Secured / Opportunity-Closed) with a
-- fulfilment revenue stream. NOTE: the design handoff assumed stage 7
-- (In Progress) but the live DBs (verified 2026-06-10, prod + dev identical)
-- hold all 73 contracts at stage 5; stage 7 is unused. Backfill and the
-- secure-contract handler must key off stage 5.
--
-- Extensions  = new term starting the month after the parent term ends
--               (own streams, no month overlap with the parent).
-- Variations  = delta-only months against the live term (positive uplift or
--               negative reduction); the original months are never restated.
-- Money stays in revenue_stream_months — no new value columns here.

begin;

-- ---------------------------------------------------------------------------
-- deals: lineage columns
-- ---------------------------------------------------------------------------

-- 'new_business' | 'extension' | 'variation'
alter table deals add column if not exists opportunity_type text not null default 'new_business';

-- Lineage root: the original deal id. Groups the collapsible family and
-- drives value rollup. Deviation from the handoff ("self for a master"):
-- masters keep NULL here and readers use coalesce(master_deal_id, id) —
-- a self-link can't be set in the same insert (id unknown pre-insert) and
-- would force a two-step write or trigger for every new deal.
alter table deals add column if not exists master_deal_id bigint references deals(id);

-- Precise predecessor: the term this extends / the contract this varies.
-- Null for new business. Distinct from master on purpose — extensions chain.
alter table deals add column if not exists parent_deal_id bigint references deals(id);

-- End of the term this deal represents; phases extensions and feeds the
-- exception-report check query.
alter table deals add column if not exists contract_end_date date;

-- Allowed opportunity_type values (add constraint has no IF NOT EXISTS).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'deals_opportunity_type_check' and conrelid = 'deals'::regclass
  ) then
    alter table deals add constraint deals_opportunity_type_check
      check (opportunity_type in ('new_business', 'extension', 'variation'));
  end if;
end $$;

-- Extensions and variations must record their lineage.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'deals_lineage_links_check' and conrelid = 'deals'::regclass
  ) then
    alter table deals add constraint deals_lineage_links_check
      check (
        opportunity_type = 'new_business'
        or (master_deal_id is not null and parent_deal_id is not null)
      );
  end if;
end $$;

create index if not exists deals_master_deal_idx on deals (master_deal_id);
create index if not exists deals_parent_deal_idx on deals (parent_deal_id);
create index if not exists deals_opportunity_type_idx on deals (opportunity_type);

-- ---------------------------------------------------------------------------
-- revenue_streams: optional link from a variation's delta stream to the
-- original stream it modifies
-- ---------------------------------------------------------------------------

alter table revenue_streams add column if not exists parent_stream_id bigint references revenue_streams(id);

create index if not exists revenue_streams_parent_stream_idx on revenue_streams (parent_stream_id);

commit;

-- Verify:
--   select column_name, data_type, is_nullable from information_schema.columns
--   where table_schema='public' and table_name='deals'
--     and column_name in ('opportunity_type','master_deal_id','parent_deal_id','contract_end_date');
--
--   select column_name, data_type from information_schema.columns
--   where table_schema='public' and table_name='revenue_streams'
--     and column_name='parent_stream_id';
--
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--   where conrelid='deals'::regclass and conname like 'deals_%check';
--
--   -- All existing rows should read as masters-to-be: new_business, no links.
--   select opportunity_type, count(*) from deals group by opportunity_type;
