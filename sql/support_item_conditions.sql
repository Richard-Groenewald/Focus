-- Focus v7.9.55 — Conditional Criteria → Support Items (2026-09-15). Idempotent.
-- Run on BOTH databases, Test first.
--
-- A Support Items condition: IF any TRIGGER is active THEN its TARGET support items tick
-- themselves. Triggers are allowances / incentives active on a post (kind statutory /
-- discretionary / incentive, by code), post conditions (kind 'post': staffed, midnight_shift,
-- public_holiday, saturday, sunday, weekend) or other support items (kind 'support', code =
-- quote_accessories.id as text). Targets are support items of any category (kind 'support').
-- A workforce target ticks on each post whose trigger is active; a contract or service target
-- ticks once on the quote when any post has the trigger.
--
-- Like an auto-includes allowance, an item a condition ticked may be overridden off with a
-- reason: the tick row carries state 'off' and the reason. Existing rows keep state 'on'
-- (presence = ticked, as before), so nothing changes for quotes already captured.
--
-- The Incentives and Allowances conditions (quote_allowance_rules) are unchanged; they only
-- moved on screen from Human Resources to Conditional Criteria.

BEGIN;

CREATE TABLE IF NOT EXISTS quote_support_item_rules (
  id         BIGSERIAL   PRIMARY KEY,
  name       TEXT        NOT NULL,
  active     BOOLEAN     NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by BIGINT      REFERENCES people(id)
);

CREATE TABLE IF NOT EXISTS quote_support_item_rule_members (
  rule_id BIGINT NOT NULL REFERENCES quote_support_item_rules(id) ON DELETE CASCADE,
  role    TEXT   NOT NULL CHECK (role IN ('trigger','target')),
  kind    TEXT   NOT NULL CHECK (kind IN ('statutory','discretionary','incentive','post','support')),
  code    TEXT   NOT NULL,
  PRIMARY KEY (rule_id, kind, code)
);

-- Overrides on the tick rows.
ALTER TABLE quote_post_accessories
  ADD COLUMN IF NOT EXISTS state TEXT NOT NULL DEFAULT 'on' CHECK (state IN ('on','off')),
  ADD COLUMN IF NOT EXISTS override_reason TEXT;

ALTER TABLE quote_contract_accessories
  ADD COLUMN IF NOT EXISTS state TEXT NOT NULL DEFAULT 'on' CHECK (state IN ('on','off')),
  ADD COLUMN IF NOT EXISTS override_reason TEXT;

DO $$ BEGIN
  EXECUTE 'CREATE TRIGGER audit_quote_support_item_rules
           AFTER INSERT OR UPDATE OR DELETE ON quote_support_item_rules
           FOR EACH ROW EXECUTE FUNCTION audit_row_change()';
EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_function THEN NULL; END $$;
DO $$ BEGIN
  EXECUTE 'CREATE TRIGGER audit_quote_support_item_rule_members
           AFTER INSERT OR UPDATE OR DELETE ON quote_support_item_rule_members
           FOR EACH ROW EXECUTE FUNCTION audit_row_change()';
EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_function THEN NULL; END $$;

COMMIT;

-- Verify:
--   SELECT r.name, r.active, m.role, m.kind, m.code FROM quote_support_item_rules r
--     JOIN quote_support_item_rule_members m ON m.rule_id = r.id ORDER BY r.name, m.role, m.kind, m.code;
--   SELECT column_name FROM information_schema.columns
--    WHERE table_name IN ('quote_post_accessories','quote_contract_accessories') AND column_name IN ('state','override_reason');
