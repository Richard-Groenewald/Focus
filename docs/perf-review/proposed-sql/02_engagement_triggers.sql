-- Focus CRM performance review, September 2026 — proposals 1.2 and 1.3
-- (findings TRG-A2, TRG-1, TRG-A5, LI-3 in findings-catalogue.md)
--
-- Before running, dump what the live database actually has; the repo is missing
-- several migrations and there may be a first_engaged_at / last_touch trigger on
-- engagements that is not in sql/:
--   select tgrelid::regclass, tgname, pg_get_triggerdef(oid)
--     from pg_trigger where not tgisinternal order by 1, 2;

begin;

-- ── 1.2  refresh_lead_next_action: fire only when the relevant columns change,
--        and only rewrite the leads row when the derived values actually differ.
--        Today (sql/unify_engagements.sql:52-96) it fires on every engagement
--        write with no column list and does an unconditional UPDATE leads, which
--        in turn fires the leads audit diff and the stage-event trigger.
create or replace function public.refresh_lead_next_action(p_lead_id bigint) returns void
language plpgsql as $$
declare v_na text; v_nad date;
begin
  if p_lead_id is null then return; end if;
  select next_action, next_action_date into v_na, v_nad
    from public.engagements
   where lead_id = p_lead_id
     and next_action_done = false
     and next_action is not null
     and next_action_date is not null
   order by next_action_date asc, id desc
   limit 1;
  update public.leads
     set next_action = v_na, next_action_date = v_nad, updated_at = now()
   where id = p_lead_id
     and (next_action is distinct from v_na or next_action_date is distinct from v_nad);
end $$;

drop trigger if exists engagements_refresh_next_action on public.engagements;
create trigger engagements_refresh_next_action
  after insert or delete or update of lead_id, next_action, next_action_date, next_action_done
  on public.engagements
  for each row execute function public.trg_engagements_refresh_next_action();

-- ── 1.3  Default stream_id to the row's own id so the client no longer has to
--        PATCH the row it just inserted (index.html 26284, 22828, 22876).
--        Serial/identity defaults are applied before BEFORE ROW triggers, so
--        NEW.id is available here.
create or replace function public.engagements_default_stream() returns trigger
language plpgsql as $$
begin
  if new.stream_id is null then new.stream_id := new.id; end if;
  return new;
end $$;

drop trigger if exists engagements_default_stream on public.engagements;
create trigger engagements_default_stream
  before insert on public.engagements
  for each row execute function public.engagements_default_stream();

-- ── TRG-A5  orgs_link_freetext_leads: fire only when a name actually changed.
--        The expression index that serves its WHERE clause is in 01_add_perf_indexes.sql.
--        (A WHEN clause cannot reference OLD on INSERT, hence two triggers.)
drop trigger if exists orgs_link_freetext_leads on public.organisations;
create trigger orgs_link_freetext_leads_ins
  after insert on public.organisations
  for each row execute function public.trg_orgs_link_freetext_leads();
create trigger orgs_link_freetext_leads_upd
  after update of name, legal_name on public.organisations
  for each row
  when (new.name is distinct from old.name or new.legal_name is distinct from old.legal_name)
  execute function public.trg_orgs_link_freetext_leads();

commit;
