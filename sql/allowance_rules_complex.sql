-- Focus v7.9.52 — Allowance conditions: requires / auto-includes (2026-09-13). Idempotent.
-- Run on BOTH databases, Test first.
--
-- Three rule types now:
--   exclusive  at most one MEMBER may be active on a post (unchanged)
--   requires   when any TRIGGER is active, every TARGET must already be active; activating a
--              trigger without them is refused, and clearing a target while a trigger is
--              active is refused
--   implies    when any TRIGGER is active, every TARGET (statutory only) ticks itself, like the
--              night rule; it can be overridden off with a reason
-- A trigger is an item (kind statutory / discretionary / incentive, by code) or a POST
-- condition (kind 'post': midnight_shift, public_holiday, saturday, sunday, weekend).

BEGIN;

ALTER TABLE quote_allowance_rules DROP CONSTRAINT IF EXISTS quote_allowance_rules_rule_type_check;
ALTER TABLE quote_allowance_rules
  ADD CONSTRAINT quote_allowance_rules_rule_type_check
  CHECK (rule_type IN ('exclusive','requires','implies'));

ALTER TABLE quote_allowance_rule_members
  ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'member';
ALTER TABLE quote_allowance_rule_members DROP CONSTRAINT IF EXISTS quote_allowance_rule_members_role_check;
ALTER TABLE quote_allowance_rule_members
  ADD CONSTRAINT quote_allowance_rule_members_role_check
  CHECK (role IN ('member','trigger','target'));

ALTER TABLE quote_allowance_rule_members DROP CONSTRAINT IF EXISTS quote_allowance_rule_members_kind_check;
ALTER TABLE quote_allowance_rule_members
  ADD CONSTRAINT quote_allowance_rule_members_kind_check
  CHECK (kind IN ('statutory','discretionary','incentive','post'));

COMMIT;

-- Verify:
--   SELECT r.name, r.rule_type, m.role, m.kind, m.code FROM quote_allowance_rules r
--     JOIN quote_allowance_rule_members m ON m.rule_id = r.id ORDER BY r.name, m.role, m.code;
