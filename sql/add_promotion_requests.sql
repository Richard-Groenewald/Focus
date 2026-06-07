-- Promotion requests — owner assembles the full deal package at REQUEST time;
-- a manager simply Accepts (commits → creates the deal) or Rejects (with reason).
-- Run once against the DEV/test Supabase DB (SQL editor). Safe to re-run.
--
-- Nothing real (org/person/deal) is created until Accept: the request stores the
-- whole prepared package as JSONB. A rejected request creates zero junk records.
-- Applies to both standard (fully Qualified) and special (below-threshold) requests.
-- Managers keep a one-step direct Promote (commits immediately, no request row).

-- Reject reason lookup (managed in Lookups → Promotion Reject Reasons).
create table if not exists promotion_reject_reasons (
  id          bigserial primary key,
  name        text not null,
  description text,
  sort_order  integer,
  active      boolean default true,
  created_at  timestamptz default now()
);

insert into promotion_reject_reasons (name, description, sort_order) values
  ('Financials need rework',     'Revenue stream / margin / dates are off.',        1),
  ('Wrong organisation match',   'Linked or created the wrong client organisation.', 2),
  ('Not genuinely qualified',    'Does not yet warrant an opportunity.',            3),
  ('Timing — revisit later',     'Real but not now; park and re-request.',          4),
  ('Insufficient justification', 'Special request motivation is too thin.',         5)
on conflict do nothing;

-- The request record + frozen package + decision trail.
create table if not exists promotion_requests (
  id               bigserial primary key,
  lead_id          bigint not null references leads(id),
  request_type     text not null default 'standard',   -- 'standard' | 'special'
  justification    text,                                -- special below-threshold motivation
  status           text not null default 'pending',     -- 'pending' | 'accepted' | 'rejected'
  package          jsonb not null,                      -- full deal-draft snapshot
  requested_by     bigint references people(id),
  requested_at     timestamptz default now(),
  decided_by       bigint references people(id),
  decided_at       timestamptz,
  reject_reason_id bigint references promotion_reject_reasons(id),
  reject_note      text,
  created_deal_id  bigint references deals(id),          -- set on accept
  created_at       timestamptz default now()
);

-- One pending request per lead at a time (re-requests reuse after a decision).
create unique index if not exists promotion_requests_one_pending_per_lead
  on promotion_requests (lead_id) where status = 'pending';

create index if not exists promotion_requests_lead_idx   on promotion_requests (lead_id);
create index if not exists promotion_requests_status_idx on promotion_requests (status);

-- Verify:
--   select id, lead_id, request_type, status, requested_by, decided_by, created_deal_id
--   from promotion_requests order by created_at desc;
--   select * from promotion_reject_reasons order by sort_order;
