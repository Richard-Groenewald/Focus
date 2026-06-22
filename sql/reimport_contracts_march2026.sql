-- Re-import Focus contracts from "Contracts List March'2026.xlsx"  (DEV ONLY)
-- Generated: wipe all deals + streams, re-import secured contracts (flat 12mo 2026-03..2027-02).
-- Extensions are created afterwards by sql/backfill_extension_opportunities.sql.
begin;
-- 1. WIPE existing business data
delete from revenue_streams;   -- cascades revenue_stream_months
delete from secured_snapshots;
delete from deals;             -- cascades collaborators, contacts, engagements, quotes
-- 2. RE-IMPORT secured contracts (70 billable rows)
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Access World (Durban) (Pty) Ltd - ACCESS World - Durban', 4000, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',1131280.40),('2026-04',1131280.40),('2026-05',1131280.40),('2026-06',1131280.40),('2026-07',1131280.40),('2026-08',1131280.40),('2026-09',1131280.40),('2026-10',1131280.40),('2026-11',1131280.40),('2026-12',1131280.40),('2027-01',1131280.40),('2027-02',1131280.40)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Access World South Africa (Pty) Ltd - ACCESS World - Gosforth Park', 4001, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',455710.05),('2026-04',455710.05),('2026-05',455710.05),('2026-06',455710.05),('2026-07',455710.05),('2026-08',455710.05),('2026-09',455710.05),('2026-10',455710.05),('2026-11',455710.05),('2026-12',455710.05),('2027-01',455710.05),('2027-02',455710.05)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Adcock Ingram - Adcock Ingram', 4002, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',166736.50),('2026-04',166736.50),('2026-05',166736.50),('2026-06',166736.50),('2026-07',166736.50),('2026-08',166736.50),('2026-09',166736.50),('2026-10',166736.50),('2026-11',166736.50),('2026-12',166736.50),('2027-01',166736.50),('2027-02',166736.50)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Airport City POA Phase1-3 - Airport City Monitoring', 4006, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',12300.00),('2026-04',12300.00),('2026-05',12300.00),('2026-06',12300.00),('2026-07',12300.00),('2026-08',12300.00),('2026-09',12300.00),('2026-10',12300.00),('2026-11',12300.00),('2026-12',12300.00),('2027-01',12300.00),('2027-02',12300.00)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Airport City POA Phase 4-7 - Airport City', 4005, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',188329.96),('2026-04',188329.96),('2026-05',188329.96),('2026-06',188329.96),('2026-07',188329.96),('2026-08',188329.96),('2026-09',188329.96),('2026-10',188329.96),('2026-11',188329.96),('2026-12',188329.96),('2027-01',188329.96),('2027-02',188329.96)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Barberton Mines - Barbeton', 4011, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',794705.78),('2026-04',794705.78),('2026-05',794705.78),('2026-06',794705.78),('2026-07',794705.78),('2026-08',794705.78),('2026-09',794705.78),('2026-10',794705.78),('2026-11',794705.78),('2026-12',794705.78),('2027-01',794705.78),('2027-02',794705.78)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Bronberg Estate - Bronberg Estate', 4014, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',101856.20),('2026-04',101856.20),('2026-05',101856.20),('2026-06',101856.20),('2026-07',101856.20),('2026-08',101856.20),('2026-09',101856.20),('2026-10',101856.20),('2026-11',101856.20),('2026-12',101856.20),('2027-01',101856.20),('2027-02',101856.20)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('The Somerset Lifestyle & Retirement Village - The Somerset Master HOA', 4135, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',185366.37),('2026-04',185366.37),('2026-05',185366.37),('2026-06',185366.37),('2026-07',185366.37),('2026-08',185366.37),('2026-09',185366.37),('2026-10',185366.37),('2026-11',185366.37),('2026-12',185366.37),('2027-01',185366.37),('2027-02',185366.37)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Caroline Rupert & Hanneli Rupert - Caroline Rupert & Hanneli Rupert', 4152, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',104421.08),('2026-04',104421.08),('2026-05',104421.08),('2026-06',104421.08),('2026-07',104421.08),('2026-08',104421.08),('2026-09',104421.08),('2026-10',104421.08),('2026-11',104421.08),('2026-12',104421.08),('2027-01',104421.08),('2027-02',104421.08)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Cloetesdal Developments (Newinbosch) - Cloetestal Development - Newinbosch', 4021, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',459290.83),('2026-04',459290.83),('2026-05',459290.83),('2026-06',459290.83),('2026-07',459290.83),('2026-08',459290.83),('2026-09',459290.83),('2026-10',459290.83),('2026-11',459290.83),('2026-12',459290.83),('2027-01',459290.83),('2027-02',459290.83)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Croydon Vineyard Estate - Croydon', 4024, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',141600.72),('2026-04',141600.72),('2026-05',141600.72),('2026-06',141600.72),('2026-07',141600.72),('2026-08',141600.72),('2026-09',141600.72),('2026-10',141600.72),('2026-11',141600.72),('2026-12',141600.72),('2027-01',141600.72),('2027-02',141600.72)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('DGB (Pty) Ltd - DGB: All sites combined', 4031, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',364605.90),('2026-04',364605.90),('2026-05',364605.90),('2026-06',364605.90),('2026-07',364605.90),('2026-08',364605.90),('2026-09',364605.90),('2026-10',364605.90),('2026-11',364605.90),('2026-12',364605.90),('2027-01',364605.90),('2027-02',364605.90)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('De Werf 1: Simons Way, De Wijnlanden Estate - De Werf', 4027, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',53552.05),('2026-04',53552.05),('2026-05',53552.05),('2026-06',53552.05),('2026-07',53552.05),('2026-08',53552.05),('2026-09',53552.05),('2026-10',53552.05),('2026-11',53552.05),('2026-12',53552.05),('2027-01',53552.05),('2027-02',53552.05)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('De Wijnlanden HOA - De Wijnlanden Estate', 4029, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',180791.21),('2026-04',180791.21),('2026-05',180791.21),('2026-06',180791.21),('2026-07',180791.21),('2026-08',180791.21),('2026-09',180791.21),('2026-10',180791.21),('2026-11',180791.21),('2026-12',180791.21),('2027-01',180791.21),('2027-02',180791.21)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Drostdy Hotel - Drosty Hotel', 4035, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',188181.59),('2026-04',188181.59),('2026-05',188181.59),('2026-06',188181.59),('2026-07',188181.59),('2026-08',188181.59),('2026-09',188181.59),('2026-10',188181.59),('2026-11',188181.59),('2026-12',188181.59),('2027-01',188181.59),('2027-02',188181.59)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Erca Management & Secretarial Service (Pty) Ltd - Erca Management', 4039, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',144217.55),('2026-04',144217.55),('2026-05',144217.55),('2026-06',144217.55),('2026-07',144217.55),('2026-08',144217.55),('2026-09',144217.55),('2026-10',144217.55),('2026-11',144217.55),('2026-12',144217.55),('2027-01',144217.55),('2027-02',144217.55)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Ergo - Ergo Mining - Far West - DRD Gold', 4040, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',595488.12),('2026-04',595488.12),('2026-05',595488.12),('2026-06',595488.12),('2026-07',595488.12),('2026-08',595488.12),('2026-09',595488.12),('2026-10',595488.12),('2026-11',595488.12),('2026-12',595488.12),('2027-01',595488.12),('2027-02',595488.12)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Evander Gold Mining (Pty) Ltd - Evander - PAR', 4041, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',531878.78),('2026-04',531878.78),('2026-05',531878.78),('2026-06',531878.78),('2026-07',531878.78),('2026-08',531878.78),('2026-09',531878.78),('2026-10',531878.78),('2026-11',531878.78),('2026-12',531878.78),('2027-01',531878.78),('2027-02',531878.78)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Harmony Gold Mining Company Limited - Harmony', 4050, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',1755449.78),('2026-04',1755449.78),('2026-05',1755449.78),('2026-06',1755449.78),('2026-07',1755449.78),('2026-08',1755449.78),('2026-09',1755449.78),('2026-10',1755449.78),('2026-11',1755449.78),('2026-12',1755449.78),('2027-01',1755449.78),('2027-02',1755449.78)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Helderberg Society for the Aged - Helderberg Society for the Aged', 4052, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',178307.92),('2026-04',178307.92),('2026-05',178307.92),('2026-06',178307.92),('2026-07',178307.92),('2026-08',178307.92),('2026-09',178307.92),('2026-10',178307.92),('2026-11',178307.92),('2026-12',178307.92),('2027-01',178307.92),('2027-02',178307.92)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Pick n Pay - Graaff-Reinet - Homestead/ Pick & Pay', 4099, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',59728.52),('2026-04',59728.52),('2026-05',59728.52),('2026-06',59728.52),('2026-07',59728.52),('2026-08',59728.52),('2026-09',59728.52),('2026-10',59728.52),('2026-11',59728.52),('2026-12',59728.52),('2027-01',59728.52),('2027-02',59728.52)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Imibala Gallery - IMIBALA: Hermanus', 4055, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',63403.10),('2026-04',63403.10),('2026-05',63403.10),('2026-06',63403.10),('2026-07',63403.10),('2026-08',63403.10),('2026-09',63403.10),('2026-10',63403.10),('2026-11',63403.10),('2026-12',63403.10),('2027-01',63403.10),('2027-02',63403.10)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Imibala Retail Store - IMIBALA: Somerset West', 4057, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',63615.98),('2026-04',63615.98),('2026-05',63615.98),('2026-06',63615.98),('2026-07',63615.98),('2026-08',63615.98),('2026-09',63615.98),('2026-10',63615.98),('2026-11',63615.98),('2026-12',63615.98),('2027-01',63615.98),('2027-02',63615.98)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Interwaste - Interwaste', 4059, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',127353.46),('2026-04',127353.46),('2026-05',127353.46),('2026-06',127353.46),('2026-07',127353.46),('2026-08',127353.46),('2026-09',127353.46),('2026-10',127353.46),('2026-11',127353.46),('2026-12',127353.46),('2027-01',127353.46),('2027-02',127353.46)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('JP Rupert - Onrus - JP Rupert - Onrus', 4153, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',200959.30),('2026-04',200959.30),('2026-05',200959.30),('2026-06',200959.30),('2026-07',200959.30),('2026-08',200959.30),('2026-09',200959.30),('2026-10',200959.30),('2026-11',200959.30),('2026-12',200959.30),('2027-01',200959.30),('2027-02',200959.30)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Kainos Rosh - Graaff Reinet Airport - Kainos Rosh - Graff Reinet Airport', 4064, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',61444.78),('2026-04',61444.78),('2026-05',61444.78),('2026-06',61444.78),('2026-07',61444.78),('2026-08',61444.78),('2026-09',61444.78),('2026-10',61444.78),('2026-11',61444.78),('2026-12',61444.78),('2027-01',61444.78),('2027-02',61444.78)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Kanonberg - Kanonberg Estate', 4066, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',179715.55),('2026-04',179715.55),('2026-05',179715.55),('2026-06',179715.55),('2026-07',179715.55),('2026-08',179715.55),('2026-09',179715.55),('2026-10',179715.55),('2026-11',179715.55),('2026-12',179715.55),('2027-01',179715.55),('2027-02',179715.55)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('The Karino Farms - Karino Farm - Riverside', 4134, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',226926.36),('2026-04',226926.36),('2026-05',226926.36),('2026-06',226926.36),('2026-07',226926.36),('2026-08',226926.36),('2026-09',226926.36),('2026-10',226926.36),('2026-11',226926.36),('2026-12',226926.36),('2027-01',226926.36),('2027-02',226926.36)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Klein Slangkop Homeowners Association - Klein Slangkop Estate', 4069, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',142979.55),('2026-04',142979.55),('2026-05',142979.55),('2026-06',142979.55),('2026-07',142979.55),('2026-08',142979.55),('2026-09',142979.55),('2026-10',142979.55),('2026-11',142979.55),('2026-12',142979.55),('2027-01',142979.55),('2027-02',142979.55)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Kleine Parys II HOA - Klein Parys - CCTV Monitoring', 4070, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',6712.14),('2026-04',6712.14),('2026-05',6712.14),('2026-06',6712.14),('2026-07',6712.14),('2026-08',6712.14),('2026-09',6712.14),('2026-10',6712.14),('2026-11',6712.14),('2026-12',6712.14),('2027-01',6712.14),('2027-02',6712.14)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Kopanang - Kopaneng', 4073, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',170479.84),('2026-04',170479.84),('2026-05',170479.84),('2026-06',170479.84),('2026-07',170479.84),('2026-08',170479.84),('2026-09',170479.84),('2026-10',170479.84),('2026-11',170479.84),('2026-12',170479.84),('2027-01',170479.84),('2027-02',170479.84)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('L''Ormarins - Camdeboo Farm - L''Ormarins - Camdeboo Farm', 4074, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',151168.87),('2026-04',151168.87),('2026-05',151168.87),('2026-06',151168.87),('2026-07',151168.87),('2026-08',151168.87),('2026-09',151168.87),('2026-10',151168.87),('2026-11',151168.87),('2026-12',151168.87),('2027-01',151168.87),('2027-02',151168.87)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('La Veritas - La Veritas', 4078, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',59269.24),('2026-04',59269.24),('2026-05',59269.24),('2026-06',59269.24),('2026-07',59269.24),('2026-08',59269.24),('2026-09',59269.24),('2026-10',59269.24),('2026-11',59269.24),('2026-12',59269.24),('2027-01',59269.24),('2027-02',59269.24)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Lake Michelle - Lake Michelle - CCTV Monitoring', 4079, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',7044.52),('2026-04',7044.52),('2026-05',7044.52),('2026-06',7044.52),('2026-07',7044.52),('2026-08',7044.52),('2026-09',7044.52),('2026-10',7044.52),('2026-11',7044.52),('2026-12',7044.52),('2027-01',7044.52),('2027-02',7044.52)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Leonard Dingler (Pty) Ltd - Leonard Dindler (PMSA)', 4081, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',308406.30),('2026-04',308406.30),('2026-05',308406.30),('2026-06',308406.30),('2026-07',308406.30),('2026-08',308406.30),('2026-09',308406.30),('2026-10',308406.30),('2026-11',308406.30),('2026-12',308406.30),('2027-01',308406.30),('2027-02',308406.30)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Leopard Creek - Crim Check Sundry - Leopard Creek Airport', 4082, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',57829.75),('2026-04',57829.75),('2026-05',57829.75),('2026-06',57829.75),('2026-07',57829.75),('2026-08',57829.75),('2026-09',57829.75),('2026-10',57829.75),('2026-11',57829.75),('2026-12',57829.75),('2027-01',57829.75),('2027-02',57829.75)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Leopard Creek Country Club - Leopard Creek :Maintenance &Control Room', 4083, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',742056.68),('2026-04',742056.68),('2026-05',742056.68),('2026-06',742056.68),('2026-07',742056.68),('2026-08',742056.68),('2026-09',742056.68),('2026-10',742056.68),('2026-11',742056.68),('2026-12',742056.68),('2027-01',742056.68),('2027-02',742056.68)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Maersk - Maersk Logistics', 4087, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',120678.23),('2026-04',120678.23),('2026-05',120678.23),('2026-06',120678.23),('2026-07',120678.23),('2026-08',120678.23),('2026-09',120678.23),('2026-10',120678.23),('2026-11',120678.23),('2026-12',120678.23),('2027-01',120678.23),('2027-02',120678.23)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Mogale Tailings Retreatment - Mogale', 4090, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',317202.68),('2026-04',317202.68),('2026-05',317202.68),('2026-06',317202.68),('2026-07',317202.68),('2026-08',317202.68),('2026-09',317202.68),('2026-10',317202.68),('2026-11',317202.68),('2026-12',317202.68),('2027-01',317202.68),('2027-02',317202.68)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Mr C Searle c/o Grant - HQM Properties - Searle Residence - Manpower/CO', 4091, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',63352.63),('2026-04',63352.63),('2026-05',63352.63),('2026-06',63352.63),('2026-07',63352.63),('2026-08',63352.63),('2026-09',63352.63),('2026-10',63352.63),('2026-11',63352.63),('2026-12',63352.63),('2027-01',63352.63),('2027-02',63352.63)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('N’Komati - N''Komati Anthracite', 4097, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',156587.54),('2026-04',156587.54),('2026-05',156587.54),('2026-06',156587.54),('2026-07',156587.54),('2026-08',156587.54),('2026-09',156587.54),('2026-10',156587.54),('2026-11',156587.54),('2026-12',156587.54),('2027-01',156587.54),('2027-02',156587.54)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Pesca Atlantic Frozen Foods - Pesca Atlantic', 4098, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',49086.27),('2026-04',49086.27),('2026-05',49086.27),('2026-06',49086.27),('2026-07',49086.27),('2026-08',49086.27),('2026-09',49086.27),('2026-10',49086.27),('2026-11',49086.27),('2026-12',49086.27),('2027-01',49086.27),('2027-02',49086.27)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Raubex Security Services - Raubex', 4103, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',196785.61),('2026-04',196785.61),('2026-05',196785.61),('2026-06',196785.61),('2026-07',196785.61),('2026-08',196785.61),('2026-09',196785.61),('2026-10',196785.61),('2026-11',196785.61),('2026-12',196785.61),('2027-01',196785.61),('2027-02',196785.61)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Remgro Management Service Ltd - Remgro : PAREL VALLEI-MANPOWER', 4106, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',208124.03),('2026-04',208124.03),('2026-05',208124.03),('2026-06',208124.03),('2026-07',208124.03),('2026-08',208124.03),('2026-09',208124.03),('2026-10',208124.03),('2026-11',208124.03),('2026-12',208124.03),('2027-01',208124.03),('2027-02',208124.03)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('RCL Foods - RCL', 4104, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',260372.57),('2026-04',260372.57),('2026-05',260372.57),('2026-06',260372.57),('2026-07',260372.57),('2026-08',260372.57),('2026-09',260372.57),('2026-10',260372.57),('2026-11',260372.57),('2026-12',260372.57),('2027-01',260372.57),('2027-02',260372.57)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Rupert & Rothschild Vignerons (Pty) Ltd - Rupert & Rothschild Vignerons', 4110, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',75543.69),('2026-04',75543.69),('2026-05',75543.69),('2026-06',75543.69),('2026-07',75543.69),('2026-08',75543.69),('2026-09',75543.69),('2026-10',75543.69),('2026-11',75543.69),('2026-12',75543.69),('2027-01',75543.69),('2027-02',75543.69)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Rupert Museum NPC - Rupert Art Museum', 4111, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',18112.20),('2026-04',18112.20),('2026-05',18112.20),('2026-06',18112.20),('2026-07',18112.20),('2026-08',18112.20),('2026-09',18112.20),('2026-10',18112.20),('2026-11',18112.20),('2026-12',18112.20),('2027-01',18112.20),('2027-02',18112.20)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('SA College for Tourism - SA College', 4112, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',89456.11),('2026-04',89456.11),('2026-05',89456.11),('2026-06',89456.11),('2026-07',89456.11),('2026-08',89456.11),('2026-09',89456.11),('2026-10',89456.11),('2026-11',89456.11),('2026-12',89456.11),('2027-01',89456.11),('2027-02',89456.11)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Samrand Owners Association - Samrand', 4113, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',69012.74),('2026-04',69012.74),('2026-05',69012.74),('2026-06',69012.74),('2026-07',69012.74),('2026-08',69012.74),('2026-09',69012.74),('2026-10',69012.74),('2026-11',69012.74),('2026-12',69012.74),('2027-01',69012.74),('2027-02',69012.74)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Scania South Africa - Scania', 4114, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',210017.83),('2026-04',210017.83),('2026-05',210017.83),('2026-06',210017.83),('2026-07',210017.83),('2026-08',210017.83),('2026-09',210017.83),('2026-10',210017.83),('2026-11',210017.83),('2026-12',210017.83),('2027-01',210017.83),('2027-02',210017.83)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Smith Power - Smith Mining Equipment', 4118, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',93316.31),('2026-04',93316.31),('2026-05',93316.31),('2026-06',93316.31),('2026-07',93316.31),('2026-08',93316.31),('2026-09',93316.31),('2026-10',93316.31),('2026-11',93316.31),('2026-12',93316.31),('2027-01',93316.31),('2027-02',93316.31)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Spier Resort Management (Pty) Ltd - Spier Resort Management', 4123, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',293295.01),('2026-04',293295.01),('2026-05',293295.01),('2026-06',293295.01),('2026-07',293295.01),('2026-08',293295.01),('2026-09',293295.01),('2026-10',293295.01),('2026-11',293295.01),('2026-12',293295.01),('2027-01',293295.01),('2027-02',293295.01)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Spier Farm Management (Pty) Ltd - Spier Farm Management (Buitepost)', 4120, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',55120.80),('2026-04',55120.80),('2026-05',55120.80),('2026-06',55120.80),('2026-07',55120.80),('2026-08',55120.80),('2026-09',55120.80),('2026-10',55120.80),('2026-11',55120.80),('2026-12',55120.80),('2027-01',55120.80),('2027-02',55120.80)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Spier Wine Estate (Pty) Ltd - Spier Tactical', 4124, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',53284.61),('2026-04',53284.61),('2026-05',53284.61),('2026-06',53284.61),('2026-07',53284.61),('2026-08',53284.61),('2026-09',53284.61),('2026-10',53284.61),('2026-11',53284.61),('2026-12',53284.61),('2027-01',53284.61),('2027-02',53284.61)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Stellenbosch Bridge Properties - Stellenbosch Bridge Properties', 4127, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',126232.82),('2026-04',126232.82),('2026-05',126232.82),('2026-06',126232.82),('2026-07',126232.82),('2026-08',126232.82),('2026-09',126232.82),('2026-10',126232.82),('2026-11',126232.82),('2026-12',126232.82),('2027-01',126232.82),('2027-02',126232.82)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Stellenbosch Bridge (Smart City) - Stellenbosch Smart City', 4126, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',34420.61),('2026-04',34420.61),('2026-05',34420.61),('2026-06',34420.61),('2026-07',34420.61),('2026-08',34420.61),('2026-09',34420.61),('2026-10',34420.61),('2026-11',34420.61),('2026-12',34420.61),('2027-01',34420.61),('2027-02',34420.61)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('University of the Western Cape - University of Western Cape', 4138, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',556972.76),('2026-04',556972.76),('2026-05',556972.76),('2026-06',556972.76),('2026-07',556972.76),('2026-08',556972.76),('2026-09',556972.76),('2026-10',556972.76),('2026-11',556972.76),('2026-12',556972.76),('2027-01',556972.76),('2027-02',556972.76)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Villa Italia - Villa Italia', 4141, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',207563.21),('2026-04',207563.21),('2026-05',207563.21),('2026-06',207563.21),('2026-07',207563.21),('2026-08',207563.21),('2026-09',207563.21),('2026-10',207563.21),('2026-11',207563.21),('2026-12',207563.21),('2027-01',207563.21),('2027-02',207563.21)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Welgedacht Home Owners Association - Welgedatch HOA', 4144, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',587965.48),('2026-04',587965.48),('2026-05',587965.48),('2026-06',587965.48),('2026-07',587965.48),('2026-08',587965.48),('2026-09',587965.48),('2026-10',587965.48),('2026-11',587965.48),('2026-12',587965.48),('2027-01',587965.48),('2027-02',587965.48)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Welgevonden Home Owners Association - Welgevonden Estate', 4145, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',474728.93),('2026-04',474728.93),('2026-05',474728.93),('2026-06',474728.93),('2026-07',474728.93),('2026-08',474728.93),('2026-09',474728.93),('2026-10',474728.93),('2026-11',474728.93),('2026-12',474728.93),('2027-01',474728.93),('2027-02',474728.93)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Woodhill Estate - Woodhill H.O.:On Site Manpower', 4148, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',1190561.60),('2026-04',1190561.60),('2026-05',1190561.60),('2026-06',1190561.60),('2026-07',1190561.60),('2026-08',1190561.60),('2026-09',1190561.60),('2026-10',1190561.60),('2026-11',1190561.60),('2026-12',1190561.60),('2027-01',1190561.60),('2027-02',1190561.60)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Xneelo - Xneelo (Hetzner)', 4149, 5, 1, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',157752.46),('2026-04',157752.46),('2026-05',157752.46),('2026-06',157752.46),('2026-07',157752.46),('2026-08',157752.46),('2026-09',157752.46),('2026-10',157752.46),('2026-11',157752.46),('2026-12',157752.46),('2027-01',157752.46),('2027-02',157752.46)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('The Somerset Lifestyle & Retirement Village - The Somerset Estate', 4135, 5, 2, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',11296.33),('2026-04',11296.33),('2026-05',11296.33),('2026-06',11296.33),('2026-07',11296.33),('2026-08',11296.33),('2026-09',11296.33),('2026-10',11296.33),('2026-11',11296.33),('2026-12',11296.33),('2027-01',11296.33),('2027-02',11296.33)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('JP Rupert - Bakoven - JP Rupert Bakoven', 4062, 5, 2, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',5016.93),('2026-04',5016.93),('2026-05',5016.93),('2026-06',5016.93),('2026-07',5016.93),('2026-08',5016.93),('2026-09',5016.93),('2026-10',5016.93),('2026-11',5016.93),('2026-12',5016.93),('2027-01',5016.93),('2027-02',5016.93)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('JP Rupert - Parel Vallei - JP Rupert Onrus', 4063, 5, 2, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',11660.96),('2026-04',11660.96),('2026-05',11660.96),('2026-06',11660.96),('2026-07',11660.96),('2026-08',11660.96),('2026-09',11660.96),('2026-10',11660.96),('2026-11',11660.96),('2026-12',11660.96),('2027-01',11660.96),('2027-02',11660.96)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('JP Rupert - Parel Vallei - JP Rupert Parel Vallei', 4063, 5, 2, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',11706.16),('2026-04',11706.16),('2026-05',11706.16),('2026-06',11706.16),('2026-07',11706.16),('2026-08',11706.16),('2026-09',11706.16),('2026-10',11706.16),('2026-11',11706.16),('2026-12',11706.16),('2027-01',11706.16),('2027-02',11706.16)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Imibala Gallery - Imibala', 4055, 5, 2, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',3579.50),('2026-04',3579.50),('2026-05',3579.50),('2026-06',3579.50),('2026-07',3579.50),('2026-08',3579.50),('2026-09',3579.50),('2026-10',3579.50),('2026-11',3579.50),('2026-12',3579.50),('2027-01',3579.50),('2027-02',3579.50)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('La Montagne HOA - La Montagne', 4076, 5, 2, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',2016.73),('2026-04',2016.73),('2026-05',2016.73),('2026-06',2016.73),('2026-07',2016.73),('2026-08',2016.73),('2026-09',2016.73),('2026-10',2016.73),('2026-11',2016.73),('2026-12',2016.73),('2027-01',2016.73),('2027-02',2016.73)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Scania South Africa - Scania', 4114, 5, 2, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',96788.63),('2026-04',96788.63),('2026-05',96788.63),('2026-06',96788.63),('2026-07',96788.63),('2026-08',96788.63),('2026-09',96788.63),('2026-10',96788.63),('2026-11',96788.63),('2026-12',96788.63),('2027-01',96788.63),('2027-02',96788.63)) m(month,rev);
with d as (
  insert into deals (name, org_id, stage_id, service_major_id, margin_pct, probability, order_date, start_date, contract_end_date, owner_id, created_by, opportunity_type)
  values ('Welgevonden Home Owners Association - Welgevonden', 4145, 5, 2, 25.00, 100, '2026-03-01','2026-03-01','2027-02-28', 1, 1, 'new_business') returning id),
s as (insert into revenue_streams (deal_id, stream_type, locked) select id,'fulfilment',false from d returning id)
insert into revenue_stream_months (stream_id, month, opportunity_revenue, secured_revenue, opportunity_margin)
select s.id, m.month, m.rev, m.rev, 0.00 from s cross join (values ('2026-03',23215.92),('2026-04',23215.92),('2026-05',23215.92),('2026-06',23215.92),('2026-07',23215.92),('2026-08',23215.92),('2026-09',23215.92),('2026-10',23215.92),('2026-11',23215.92),('2026-12',23215.92),('2027-01',23215.92),('2027-02',23215.92)) m(month,rev);
commit;
-- 3. Verification
select count(*) secured_deals, sum(opportunity_revenue) total_monthly from deals d join revenue_streams rs on rs.deal_id=d.id join revenue_stream_months m on m.stream_id=rs.id where m.month='2026-03';
