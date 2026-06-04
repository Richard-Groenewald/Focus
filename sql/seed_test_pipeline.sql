-- Test-data seed for the Revenue Stream Pipeline (TEST DB ONLY).
--   ~/scoop/apps/postgresql/current/bin/psql.exe "$SUPABASE_TEST_DB_URL" -f sql/seed_test_pipeline.sql
--
-- Creates 3 login users (Sales User1, Sales User2 -> 'Sales User' role; Sales Manager
-- -> 'Sales Manager' role, both regions), 12 seed client orgs, and ~100 multiyear deals
-- with opportunity revenue streams. Secured/In-Progress/Complete deals also get a
-- fulfilment stream (Secured layer) and past-month actuals (Actual layer) so every
-- pipeline layer is populated. Re-runnable: it removes its own prior seed first.
--
-- Login is passwordless in test mode; passwords are set to '1' to satisfy NOT NULL.

do $$
declare
  p1 bigint; p2 bigint; pm bigint; sm bigint; tmp bigint;
  owners bigint[]; org_ids bigint[];
  today date := date '2026-06-01';
  cur_month date := date_trunc('month', date '2026-06-01')::date;
  i int; m int; v_owner bigint; v_region int; v_stage int; v_prob int;
  v_subid int; v_majid int; v_margin numeric; v_recurring boolean;
  v_dur int; v_base numeric; v_start date; v_monthdate date; v_ym text;
  v_rev numeric; v_oppm numeric; v_act numeric; v_actm numeric;
  did bigint; opp_sid bigint; ful_sid bigint; v_secured boolean;
  v_name text; v_orgidx int; stage_pick int;
begin
  -- ===== USERS (idempotent by username) =====
  select person_id into p1 from system_users where username = 'salesuser1';
  if p1 is null then
    insert into people(first_name, last_name) values ('Sales','User1') returning id into p1;
    insert into system_users(person_id, username, password, active) values (p1,'salesuser1','1',true) returning id into tmp;
    insert into user_roles(user_id, role_id) values (tmp, 3);   -- Sales User
  end if;
  select person_id into p2 from system_users where username = 'salesuser2';
  if p2 is null then
    insert into people(first_name, last_name) values ('Sales','User2') returning id into p2;
    insert into system_users(person_id, username, password, active) values (p2,'salesuser2','1',true) returning id into tmp;
    insert into user_roles(user_id, role_id) values (tmp, 3);   -- Sales User
  end if;
  select id, person_id into sm, pm from system_users where username = 'salesmanager';
  if pm is null then
    insert into people(first_name, last_name) values ('Sales','Manager') returning id into pm;
    insert into system_users(person_id, username, password, active) values (pm,'salesmanager','1',true) returning id into sm;
    insert into user_roles(user_id, role_id) values (sm, 2);    -- Sales Manager
  end if;
  insert into system_user_regions(system_user_id, region_id)
    select sm, x from unnest(array[1,2]) as x
    where not exists (select 1 from system_user_regions s where s.system_user_id = sm and s.region_id = x);

  owners := array[p1, p2, pm];

  -- ===== CLEANUP prior seed (re-runnable) =====
  delete from revenue_stream_months where stream_id in (
    select rs.id from revenue_streams rs join deals d on d.id = rs.deal_id
    join organisations o on o.id = d.org_id where o.name like 'Seed Org %');
  delete from revenue_streams where deal_id in (
    select d.id from deals d join organisations o on o.id = d.org_id where o.name like 'Seed Org %');
  delete from deals where org_id in (select id from organisations where name like 'Seed Org %');
  delete from organisations where name like 'Seed Org %';

  -- ===== ORGS =====
  org_ids := array[]::bigint[];
  for i in 1..12 loop
    insert into organisations(name, is_client) values ('Seed Org '||lpad(i::text,2,'0'), true) returning id into did;
    org_ids := org_ids || did;
  end loop;

  -- ===== DEALS + revenue streams =====
  for i in 1..100 loop
    v_owner  := owners[1 + (i % 3)];
    v_region := 1 + (i % 2);
    v_orgidx := 1 + (i % array_length(org_ids,1));

    case (i % 4)
      when 0 then v_subid:=1; v_majid:=1; v_margin:=25; v_recurring:=true;   -- Guarding Services
      when 1 then v_subid:=2; v_majid:=1; v_margin:=25; v_recurring:=true;   -- On-site Control Room
      when 2 then v_subid:=3; v_majid:=1; v_margin:=30; v_recurring:=true;   -- Off-site Control Room
      else        v_subid:=4; v_majid:=2; v_margin:=25; v_recurring:=false;  -- Technology Project
    end case;

    stage_pick := (i*7) % 100;
    if    stage_pick < 20 then v_stage:=2; v_prob:=40;   -- Prospect
    elsif stage_pick < 40 then v_stage:=3; v_prob:=60;   -- Proposal
    elsif stage_pick < 60 then v_stage:=4; v_prob:=80;   -- Negotiation
    elsif stage_pick < 80 then v_stage:=5; v_prob:=100;  -- Secured
    elsif stage_pick < 90 then v_stage:=7; v_prob:=100;  -- In Progress
    elsif stage_pick < 97 then v_stage:=8; v_prob:=100;  -- Complete
    else                       v_stage:=6; v_prob:=0;    -- Lost
    end if;
    v_secured := v_stage in (5,7,8);

    v_start := (cur_month + make_interval(months => (i % 30) - 18))::date;
    if v_recurring then
      v_dur  := 12 + (i % 5) * 12;          -- 12..60 months (multiyear)
      v_base := 150000 + (i % 10) * 40000;  -- R150k..R510k / month
    else
      v_dur  := 1 + (i % 3);                -- 1..3 month project
      v_base := 600000 + (i % 8) * 300000;  -- R600k..R2.7m / month
    end if;
    v_name := (case when v_majid=1 then 'Manpower' else 'Technology' end)
              ||' – Seed Org '||lpad(v_orgidx::text,2,'0')||' #'||i;

    insert into deals(name, org_id, region_id, stage_id, service_major_id, service_sub_id,
                      margin_pct, probability, order_date, start_date, owner_id, created_by)
      values (v_name, org_ids[v_orgidx], v_region, v_stage, v_majid, v_subid,
              v_margin, v_prob, v_start, v_start, v_owner, v_owner)
      returning id into did;

    insert into revenue_streams(deal_id, stream_type, locked) values (did,'opportunity',false) returning id into opp_sid;
    if v_secured then
      insert into revenue_streams(deal_id, stream_type, locked) values (did,'fulfilment',true) returning id into ful_sid;
    end if;

    for m in 0..(v_dur - 1) loop
      v_monthdate := (v_start + make_interval(months => m))::date;
      v_ym := to_char(v_monthdate, 'YYYY-MM');
      if v_recurring then v_rev := round(v_base * power(1.05, floor(m/12.0)));   -- ~5% yearly escalation
      else                v_rev := v_base; end if;
      v_oppm := round(v_rev * v_margin / 100.0, 2);

      insert into revenue_stream_months(stream_id, month, opportunity_revenue, opportunity_margin)
        values (opp_sid, v_ym, v_rev, v_oppm);

      if v_secured then
        if v_monthdate < cur_month then
          v_act  := round(v_rev * (0.9 + random() * 0.2));   -- realised actual ±10%
          v_actm := round(v_act * v_margin / 100.0, 2);
          insert into revenue_stream_months(stream_id, month, fulfilment_revenue, fulfilment_margin,
                                            actual_revenue, is_actual_revenue, actual_margin, is_actual_margin)
            values (ful_sid, v_ym, v_rev, v_oppm, v_act, true, v_actm, true);
        else
          insert into revenue_stream_months(stream_id, month, fulfilment_revenue, fulfilment_margin)
            values (ful_sid, v_ym, v_rev, v_oppm);
        end if;
      end if;
    end loop;
  end loop;

  raise notice 'Seed complete: users p1=% p2=% mgr=%, % orgs, deals now=%',
    p1, p2, pm, array_length(org_ids,1), (select count(*) from deals);
end $$;
