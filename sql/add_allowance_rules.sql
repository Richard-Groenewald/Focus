-- Allowance conditions (2026-08-23). Run on BOTH databases.
--
-- Richard: "some allowances cannot be active with others - armed response and armed security
-- can't both be chosen." The mechanism is admin data, like the night auto-rule: a RULE is a
-- named group with a type, and its members reference items by KIND + CODE so a rule survives
-- the annual versions. The first type is 'exclusive': at most one member of the group may be
-- active on a post. rule_type leaves room for other condition types later.

begin;

create table if not exists quote_allowance_rules (
  id         bigserial primary key,
  rule_type  text not null default 'exclusive' check (rule_type in ('exclusive')),
  name       text not null,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  created_by bigint references people(id)
);

create table if not exists quote_allowance_rule_members (
  rule_id bigint not null references quote_allowance_rules(id) on delete cascade,
  kind    text not null check (kind in ('statutory', 'discretionary', 'incentive')),
  code    text not null,
  primary key (rule_id, kind, code)
);

do $$ begin
  execute 'create trigger audit_quote_allowance_rules
           after insert or update or delete on quote_allowance_rules
           for each row execute function audit_row_change()';
exception when duplicate_object then null; when undefined_function then null; end $$;
do $$ begin
  execute 'create trigger audit_quote_allowance_rule_members
           after insert or update or delete on quote_allowance_rule_members
           for each row execute function audit_row_change()';
exception when duplicate_object then null; when undefined_function then null; end $$;

-- The stated rule, seeded: an officer is armed response OR armed security, never both.
insert into quote_allowance_rules (rule_type, name)
select 'exclusive', 'Armed role'
where not exists (select 1 from quote_allowance_rules where name = 'Armed role');

insert into quote_allowance_rule_members (rule_id, kind, code)
select r.id, 'statutory', c.code
  from quote_allowance_rules r
  cross join (values ('armed_response_officer'), ('armed_security_operator')) as c(code)
 where r.name = 'Armed role'
on conflict do nothing;

commit;

-- Verify:
--   select r.name, r.rule_type, m.kind, m.code from quote_allowance_rules r
--     join quote_allowance_rule_members m on m.rule_id = r.id order by r.name, m.code;
