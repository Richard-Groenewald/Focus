-- Focus CRM performance review, September 2026 — proposals 2.9 and 2.13 / 1.5
-- (findings POLL-1, CPU-10, TRG-A3, LR-02, ATT-2 in findings-catalogue.md)
--
-- Both functions are called through the existing proxy:
--   api('rpc/heartbeat',   'POST', { p_person_id, p_version })
--   api('rpc/sweep_leads', 'POST', {})
-- sb.js rewrites /.netlify/functions/sb/rpc/<fn> to /rest/v1/rpc/<fn> unchanged and
-- forwards X-Actor-Id, so audit attribution inside the functions is preserved.
-- api() refuses non-GET calls for read-only users unless the table is allow-listed:
-- add 'rpc/heartbeat' and 'rpc/sweep_leads' to READ_ONLY_WRITE_ALLOW (index.html ~11188).

begin;

-- ── 2.9  heartbeat: upsert presence + return live broadcasts in ONE call.
--        Replaces PATCH user_presence (+ POST fallback) + GET broadcasts every 60 s.
--        Needs the unique index on user_presence(person_id) from 01_add_perf_indexes.sql.
create or replace function public.heartbeat(p_person_id bigint, p_version text)
returns setof public.broadcasts
language sql security definer as $$
  insert into public.user_presence (person_id, last_seen_at, app_version)
  values (p_person_id, now(), p_version)
  on conflict (person_id) do update
    set last_seen_at = excluded.last_seen_at, app_version = excluded.app_version;
  select * from public.broadcasts
   where ended_at is null and expires_at > now()
   order by created_at desc;
$$;

-- ── 1.5 / 2.13  sweep_leads: the New→Working flip and the Hold wake as ONE
--        set-based statement each, mirroring computeLeadStatus / sweepNewToWorking /
--        sweepHoldWake in index.html (23431-23533). Today the client PATCHes one
--        lead per round trip on every register, cockpit and dashboard load.
--        Keep this SQL and the JS rules in step (or expose derived_status on a view
--        so there is one source of truth).
create or replace function public.lead_source_complete(l public.leads) returns boolean
language sql stable as $$
  select case s.name
    when 'Referral' then l.source_person_id is not null
         or (l.source_person_name ~ '\S+\s+\S+'
             and (nullif(trim(l.source_person_email), '') is not null
                  or length(regexp_replace(coalesce(l.source_person_phone, ''), '\D', '', 'g')) >= 10))
    when 'Client Expansion'   then l.source_org_id is not null
    when 'Marketing Campaign' then l.research_campaign_id is not null
    when 'Research Campaign'  then l.research_campaign_id is not null
    when 'Research'           then l.research_campaign_id is not null
    when 'Research Study'     then l.sales_campaign_id is not null
    when 'Sales Campaign'     then l.sales_campaign_id is not null
    else nullif(trim(l.source_detail), '') is not null end
  from public.lead_sources s where s.id = l.source_id
$$;

create or replace function public.lead_working_prereqs(l public.leads) returns boolean
language sql stable as $$
  select public.lead_source_complete(l)
     and nullif(trim(l.description), '') is not null
     and (l.target_person_id is not null
          or (l.target_person_name ~ '\S+\s+\S+'
              and (nullif(trim(l.target_person_email), '') is not null
                   or length(regexp_replace(coalesce(l.target_person_phone, ''), '\D', '', 'g')) >= 10)))
$$;

create or replace function public.sweep_leads() returns jsonb
language plpgsql security definer as $$
declare v_grace int; v_working bigint[]; v_woke bigint[];
begin
  select coalesce(nullif(value, '')::int, 0) into v_grace
    from public.settings where key = 'new_lead_waiting_minutes';

  -- New → Working
  with f as (
    update public.leads l
       set status = 'Working', working_at = coalesce(l.working_at, now()), updated_at = now()
     where l.status = 'New' and l.dead_reason is null and l.wake_date is null and l.promoted_at is null
       and l.first_engaged_at is not null and l.next_action is not null and l.next_action_date is not null
       and public.lead_working_prereqs(l)
    returning l.id)
  select coalesce(array_agg(id), '{}') into v_working from f;

  -- Hold → woke
  with w as (
    update public.leads l
       set wake_date = null, woke_at = now(), working_at = coalesce(l.working_at, now()), updated_at = now(),
           status = case
             when l.fit = 2 and l.trigger_score = 2 and l.access = 2 and l.capacity = 2
                  and l.service_major_id is not null
                  and (l.target_org_id is not null or nullif(trim(l.target_org_name), '') is not null)
                  and coalesce(l.qualification_demoted, false) = false then 'Qualified'
             when l.working_at is not null and now() - l.working_at >= make_interval(mins => v_grace) then 'Working'
             when public.lead_working_prereqs(l) and l.next_action is not null
                  and l.next_action_date is not null and l.first_engaged_at is not null then 'Working'
             else 'New' end
     where l.status = 'Hold' and l.wake_date <= current_date and l.promoted_at is null and l.dead_reason is null
    returning l.id)
  select coalesce(array_agg(id), '{}') into v_woke from w;

  return jsonb_build_object('working', to_jsonb(v_working), 'woke', to_jsonb(v_woke));
end $$;

commit;

-- Alternative to calling it from the client at all: schedule it every 10 minutes
-- and drop sweepNewToWorking / sweepHoldWake from the page loads entirely.
--   create extension if not exists pg_cron;
--   select cron.schedule('focus_sweep_leads', '*/10 * * * *', $$select public.sweep_leads()$$);
