-- Re-window all deals to the FY (Jul–Jun) basis  (DEV ONLY)
-- Secured deals (stage 5): hold the secured value across 2026-07 .. 2027-06.
-- Extension prospects (stage 2): project forward 2027-07 .. 2028-06 at 80% probability.
-- Monthly values are constant per stream, so we capture the value and regenerate months.
begin;

-- 1. capture the constant monthly value per stream
create temp table _v on commit drop as
select rs.id as stream_id, rs.deal_id, d.stage_id, d.opportunity_type,
       max(m.opportunity_revenue) as opp, max(m.secured_revenue) as sec
from revenue_streams rs
join deals d on d.id = rs.deal_id
left join revenue_stream_months m on m.stream_id = rs.id
group by rs.id, rs.deal_id, d.stage_id, d.opportunity_type;

-- 2. clear existing month rows (all belong to these deals)
delete from revenue_stream_months;

-- 3. secured: 12 months 2026-07 .. 2027-06 (opportunity_revenue = secured_revenue = value)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select v.stream_id, to_char(g.m, 'YYYY-MM'), v.opp, v.sec, 0.00
from _v v
cross join generate_series(date '2026-07-01', date '2027-06-01', interval '1 month') g(m)
where v.stage_id = 5;

-- 4. extension prospects: 12 months 2027-07 .. 2028-06 (opportunity_revenue only)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, opportunity_margin)
select v.stream_id, to_char(g.m, 'YYYY-MM'), v.opp, 0.00
from _v v
cross join generate_series(date '2027-07-01', date '2028-06-01', interval '1 month') g(m)
where v.opportunity_type = 'extension';

-- 5. align deal date fields and prospect probability
update deals set start_date = '2026-07-01', contract_end_date = '2027-06-30', updated_at = now()
where stage_id = 5;

update deals set start_date = '2027-07-01', contract_end_date = '2028-06-30', probability = 80, updated_at = now()
where opportunity_type = 'extension';

commit;

-- verification
select s.name stage, d.opportunity_type, d.probability,
       count(*) months, min(m.month) first_m, max(m.month) last_m,
       sum(m.opportunity_revenue) opp_rev
from deals d
join stages s on s.id = d.stage_id
join revenue_streams rs on rs.deal_id = d.id
join revenue_stream_months m on m.stream_id = rs.id
group by 1,2,3 order by 1,2;
