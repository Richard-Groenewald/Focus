-- Focus v7.9.66 — Conditions & Rules: one table replaces two (2026-09-18).
-- Richard, from the "Conditional Criteria" screenshot: combine the "Incentives and Allowances"
-- tile (quote_allowance_rules: exclusive / requires / implies between allowances and post
-- conditions) and the "Support Items and Training" tile (quote_support_item_rules: one
-- auto-include type, allowances/post conditions/other items driving support items and training)
-- into a single conditions/selection table that ALSO lets an allowance be auto-selected from
-- other criteria -- a support item or a training course -- which the old two-phase design could
-- never express (allowances always resolved first, support items only ever consumed that
-- result, never fed back into it).
--
-- quote_condition_rules / quote_condition_rule_members replace BOTH pairs of tables. A rule is
-- exclusive | requires | implies; a member's kind is statutory | discretionary | incentive |
-- post | support | training, in any combination as trigger or target (implies restricted to
-- statutory allowances, never discretionary/incentive -- see index.html's pbSupportEval comment
-- for why). The two old support-item-rule tables had no surrogate id -- their real primary key
-- was (rule_id, kind, code) -- so the new member table keeps that shape.
--
-- This is NOT an additive migration: it drops the two old table pairs the currently-deployed
-- code still reads. Run this only in the same window as deploying the matching index.html --
-- between this SQL and that deploy, anyone opening a quote or the Conditional Criteria page on
-- the old code will see it fail to load until the new code lands.
--
-- Run on Dev first, verify, then Prod, in the SAME release as the code. Not idempotent (it
-- drops what it migrates) -- do not run twice.

BEGIN;

CREATE TABLE quote_condition_rules (
  id         BIGSERIAL   PRIMARY KEY,
  rule_type  TEXT        NOT NULL DEFAULT 'exclusive' CHECK (rule_type IN ('exclusive','requires','implies')),
  name       TEXT        NOT NULL,
  active     BOOLEAN     NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by BIGINT      REFERENCES people(id)
);

CREATE TABLE quote_condition_rule_members (
  rule_id BIGINT NOT NULL REFERENCES quote_condition_rules(id) ON DELETE CASCADE,
  role    TEXT   NOT NULL DEFAULT 'member' CHECK (role IN ('member','trigger','target')),
  kind    TEXT   NOT NULL CHECK (kind IN ('statutory','discretionary','incentive','post','support','training')),
  code    TEXT   NOT NULL,
  PRIMARY KEY (rule_id, kind, code)
);
CREATE INDEX quote_condition_rule_members_rule_idx ON quote_condition_rule_members (rule_id);

-- 1) Allowance rules keep their ids: nothing outside these two tables references them by id.
INSERT INTO quote_condition_rules (id, rule_type, name, active, created_at, created_by)
  SELECT id, rule_type, name, active, created_at, created_by FROM quote_allowance_rules;
INSERT INTO quote_condition_rule_members (rule_id, role, kind, code)
  SELECT rule_id, COALESCE(role, 'member'), kind, code FROM quote_allowance_rule_members;

-- Explicit ids do not advance a BIGSERIAL's sequence: move it past them NOW, before step 2 asks
-- nextval() for its first id (which would otherwise be 1 — colliding with "Armed role").
SELECT setval(pg_get_serial_sequence('quote_condition_rules', 'id'), (SELECT COALESCE(MAX(id), 1) FROM quote_condition_rules));

-- 2) Support-item rules become 'implies' rows with NEW ids (they'd collide with the allowance
-- ids above); a temp mapping keyed by the real old id, not name, carries the members across.
CREATE TEMP TABLE _sup_id_map (old_id BIGINT PRIMARY KEY, new_id BIGINT NOT NULL);
DO $$
DECLARE r RECORD; nid BIGINT;
BEGIN
  FOR r IN SELECT * FROM quote_support_item_rules ORDER BY id LOOP
    INSERT INTO quote_condition_rules (rule_type, name, active, created_at, created_by)
      VALUES ('implies', r.name, r.active, r.created_at, r.created_by)
      RETURNING id INTO nid;
    INSERT INTO _sup_id_map VALUES (r.id, nid);
  END LOOP;
END $$;
INSERT INTO quote_condition_rule_members (rule_id, role, kind, code)
  SELECT map.new_id, m.role, m.kind, m.code
  FROM quote_support_item_rule_members m
  JOIN _sup_id_map map ON map.old_id = m.rule_id;

DROP TABLE quote_allowance_rule_members;
DROP TABLE quote_allowance_rules;
DROP TABLE quote_support_item_rule_members;
DROP TABLE quote_support_item_rules;

ALTER TABLE quote_condition_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE quote_condition_rule_members ENABLE ROW LEVEL SECURITY;

-- Statement-level audit for the rules table (it has an id). The members table has NO id column
-- (composite key), and audit_stmt()'s UPDATE branch joins old_rows to new_rows on id — so the
-- members table takes the row-level audit_row_change() trigger, as the old
-- quote_support_item_rule_members did (sql/support_item_conditions.sql).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['quote_condition_rules'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_ins_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_ins_%1$I AFTER INSERT ON %1$I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_upd_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_upd_%1$I AFTER UPDATE ON %1$I REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_del_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_del_%1$I AFTER DELETE ON %1$I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
  END LOOP;
END $$;
DO $$ BEGIN
  EXECUTE 'CREATE TRIGGER audit_quote_condition_rule_members
           AFTER INSERT OR UPDATE OR DELETE ON quote_condition_rule_members
           FOR EACH ROW EXECUTE FUNCTION audit_row_change()';
EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_function THEN NULL; END $$;

COMMIT;

-- Verify
SELECT id, rule_type, name, active FROM quote_condition_rules ORDER BY id;
SELECT rule_id, role, kind, code FROM quote_condition_rule_members ORDER BY rule_id, role, kind, code;
SELECT to_regclass('quote_allowance_rules') AS should_be_null, to_regclass('quote_support_item_rules') AS should_also_be_null;
SELECT tablename, rowsecurity FROM pg_tables WHERE tablename IN ('quote_condition_rules', 'quote_condition_rule_members');
SELECT tgrelid::regclass::text AS tbl, tgname FROM pg_trigger
  WHERE tgrelid IN ('quote_condition_rules'::regclass, 'quote_condition_rule_members'::regclass) AND NOT tgisinternal
  ORDER BY 1, 2;
