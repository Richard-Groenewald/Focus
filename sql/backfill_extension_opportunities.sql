-- Backfill: one forward extension opportunity per existing contract.
-- Run once against each Supabase DB after sql/add_extensions_variations.sql.
-- Safe to re-run: every step is guarded; deals that already have an open
-- extension child are skipped.
--
-- Contracts are deals at stage 5 (Secured) with a fulfilment revenue stream
-- (verified 2026-06-10 — stage 7 is unused; see EXTENSIONS_VARIATIONS_HANDOFF.md).
--
-- Per contract this creates:
--   deals row            opportunity_type='extension', stage 2 (Prospect),
--                        probability = extension_initial_probability setting,
--                        start_date = parent term end + 1 day,
--                        contract_end_date = same term length forward,
--                        master/parent lineage links set, owner inherited.
--   revenue_streams row  stream_type='opportunity' (unlocked).
--   revenue_stream_months  parent's FINAL-month run-rate (opportunity_revenue
--                        and opportunity_margin copied verbatim — month-level
--                        margins are 0.00 in the bulk-loaded data; we do not
--                        invent values from margin_pct), phased from the month
--                        after the parent term ends, for the parent's term length.
--
-- ELIGIBILITY: only recurring service types extend. The flag lives on
-- service_sub.is_recurring, but the bulk-loaded contracts carry only
-- service_major_id (service_sub_id is NULL on all 73) — so the rule is:
-- use service_sub.is_recurring when the sub is set, otherwise the deal is
-- eligible if its major has any active recurring sub (true for Manpower,
-- false for Technology Works, whose only sub 'Project' is non-recurring).
--
-- Deliberately SKIPPED (surfaced by the exception report at the bottom):
--   - non-recurring service types (per the eligibility rule above);
--   - contracts whose fulfilment stream has no month rows (no derivable term);
--   - contracts whose final-month revenue is null/zero (incl. cancelled) —
--     a human should decide whether those extend.

begin;

-- ---------------------------------------------------------------------------
-- 0. Flat creation probability (settings-driven; ramp comes later, app-side)
-- ---------------------------------------------------------------------------
insert into settings (key, value)
select 'extension_initial_probability', '20'
where not exists (select 1 from settings where key = 'extension_initial_probability');

-- ---------------------------------------------------------------------------
-- 1. Derive contract_end_date for existing contracts (last day of the final
--    fulfilment month). Only fills NULLs — never restates a captured date.
-- ---------------------------------------------------------------------------
update deals d
set contract_end_date = e.end_date, updated_at = now()
from (
  select rs.deal_id,
         (to_date(max(m.month) || '-01', 'YYYY-MM-DD')
            + interval '1 month' - interval '1 day')::date as end_date
  from revenue_streams rs
  join revenue_stream_months m on m.stream_id = rs.id
  where rs.stream_type = 'fulfilment'
  group by rs.deal_id
) e
where d.id = e.deal_id
  and d.stage_id = 5
  and d.contract_end_date is null;

-- ---------------------------------------------------------------------------
-- 2. Create the forward extension opportunities
-- ---------------------------------------------------------------------------
with parents as (
  select d.id, d.name, d.org_id, d.region_id, d.service_major_id, d.service_sub_id,
         d.margin_pct, d.owner_id, d.created_by, d.contract_end_date,
         coalesce(d.master_deal_id, d.id) as master_id,
         t.term_months, t.run_rate_revenue, t.run_rate_margin
  from deals d
  join lateral (
    select count(*)::int as term_months,
           (array_agg(m.opportunity_revenue order by m.month desc))[1] as run_rate_revenue,
           (array_agg(m.opportunity_margin  order by m.month desc))[1] as run_rate_margin
    from revenue_streams rs
    join revenue_stream_months m on m.stream_id = rs.id
    where rs.deal_id = d.id and rs.stream_type = 'fulfilment'
  ) t on true
  where d.stage_id = 5
    and d.contract_end_date is not null
    and coalesce(t.run_rate_revenue, 0) > 0
    -- recurring service types only (sub-level flag, major-level fallback)
    and case
          when d.service_sub_id is not null then
            coalesce((select ss.is_recurring from service_sub ss where ss.id = d.service_sub_id), false)
          else exists (
            select 1 from service_sub ss
            where ss.major_id = d.service_major_id and ss.is_recurring and ss.active
          )
        end
    and not exists (
      select 1 from deals c
      where c.parent_deal_id = d.id and c.opportunity_type = 'extension'
    )
),
new_deals as (
  insert into deals (name, org_id, region_id, stage_id, service_major_id, service_sub_id,
                     margin_pct, probability, start_date, owner_id, created_by, notes,
                     opportunity_type, master_deal_id, parent_deal_id, contract_end_date)
  select p.name || ' - Extension ' || to_char(p.contract_end_date + interval '1 day', 'Mon YYYY'),
         p.org_id, p.region_id,
         2,                                            -- Prospect
         p.service_major_id, p.service_sub_id,
         p.margin_pct,
         (select value::int from settings where key = 'extension_initial_probability'),
         (p.contract_end_date + interval '1 day')::date,
         p.owner_id, p.created_by,
         'Forward extension opportunity created by backfill (sql/backfill_extension_opportunities.sql). '
           || 'Seeded from the parent contract''s final-month run-rate.',
         'extension', p.master_id, p.id,
         (p.contract_end_date + interval '1 day'
            + (p.term_months * interval '1 month') - interval '1 day')::date
  from parents p
  returning id, parent_deal_id, start_date
),
new_streams as (
  insert into revenue_streams (deal_id, stream_type, locked)
  select nd.id, 'opportunity', false
  from new_deals nd
  returning id, deal_id
)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, opportunity_margin)
select ns.id,
       to_char(date_trunc('month', nd.start_date::timestamp)
                 + (gs.i * interval '1 month'), 'YYYY-MM'),
       p.run_rate_revenue,
       p.run_rate_margin
from new_streams ns
join new_deals nd on nd.id = ns.deal_id
join parents p   on p.id  = nd.parent_deal_id
cross join lateral generate_series(0, p.term_months - 1) as gs(i);

commit;

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------

-- Created extensions: one per covered contract, Prospect, flat probability.
select count(*)                          as extensions,
       min(probability)                  as min_prob,
       max(probability)                  as max_prob,
       min(start_date)                   as earliest_start,
       max(contract_end_date)            as latest_end
from deals
where opportunity_type = 'extension';

-- Seeded months: term length and value per extension (spot-check totals).
select count(distinct rs.deal_id) as extensions_with_streams,
       count(*)                   as seeded_months,
       sum(m.opportunity_revenue) as seeded_revenue
from revenue_streams rs
join revenue_stream_months m on m.stream_id = rs.id
join deals d on d.id = rs.deal_id
where d.opportunity_type = 'extension';

-- Exception report: ELIGIBLE (recurring) stage-5 contracts with zero or >1
-- open extension children, plus any NON-eligible contract that wrongly has one.
-- (Expected after backfill: only the no-months / zero-run-rate skips, with 0.)
with eligibility as (
  select d.id, d.name,
         case
           when d.service_sub_id is not null then
             coalesce((select ss.is_recurring from service_sub ss where ss.id = d.service_sub_id), false)
           else exists (
             select 1 from service_sub ss
             where ss.major_id = d.service_major_id and ss.is_recurring and ss.active
           )
         end as eligible
  from deals d
  where d.stage_id = 5
)
select e.id, e.name, e.eligible, count(c.id) as open_extension_children
from eligibility e
left join deals c on c.parent_deal_id = e.id
                 and c.opportunity_type = 'extension'
                 and c.stage_id in (select s.id from stages s where s.category_id = 1)
group by e.id, e.name, e.eligible
having count(c.id) <> case when e.eligible then 1 else 0 end
order by e.id;
