-- Person / Affiliation / Job-title + unified deal-contacts model
-- Design: memory person-affiliation-jobtitle-model (locked 2026-07-01)
--
-- EXPAND phase (additive only — safe to run under the currently-deployed app).
-- The matching CONTRACT phase (drop lead_contacts + opportunity_contacts) lives in
-- drop_legacy_contact_tables.sql and runs ONLY after the app is cut over + verified.
--
-- Three axes:
--   * people                    = permanent identity + honorific (people.title)
--   * person_organisation_roles = affiliation: job_title + tenure (start/end), history via close-and-open
--   * deal_contacts (NEW)       = a person's role in a lead/deal (dmu_role_id), unified across leads + deals

begin;

-- 1) Job title belongs to the affiliation, not the person. Add it + audit columns
--    (BIGINT / TIMESTAMPTZ / people(id) per house convention).
alter table person_organisation_roles
  add column if not exists job_title  text,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists created_by bigint references people(id);

-- 2) Unified deal-contacts junction. Mirrors the engagements unification:
--    exactly one of lead_id / deal_id. Contract phase is covered via deal_id
--    (a contract is the same deal row post-securing).
create table if not exists deal_contacts (
  id          bigserial primary key,
  person_id   bigint not null references people(id),
  lead_id     bigint references leads(id),
  deal_id     bigint references deals(id),
  dmu_role_id bigint references dmu_roles(id),
  is_primary  boolean not null default false,
  note        text,
  created_at  timestamptz not null default now(),
  created_by  bigint references people(id),
  constraint deal_contacts_one_parent
    check ((lead_id is not null)::int + (deal_id is not null)::int = 1)
);

create index if not exists deal_contacts_lead_idx   on deal_contacts (lead_id);
create index if not exists deal_contacts_deal_idx   on deal_contacts (deal_id);
create index if not exists deal_contacts_person_idx on deal_contacts (person_id);

-- 3) Carry the existing opportunity_contacts rows across (lead_contacts is empty).
--    Idempotent: only copy deal rows not already present for the same (deal, person).
insert into deal_contacts (person_id, deal_id, dmu_role_id, is_primary, note, created_at)
select oc.person_id, oc.deal_id, oc.dmu_role_id, false, oc.note, oc.created_at
from opportunity_contacts oc
where oc.person_id is not null
  and not exists (
    select 1 from deal_contacts dc
    where dc.deal_id = oc.deal_id and dc.person_id = oc.person_id
  );

commit;
