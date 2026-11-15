-- Quote tools (Focus v7.10.46, Richard 2026-11-14: "manpower quotes, both control rooms and guarding use
-- the proposal tool we are creating, but other deal types wont … there will be more than one tool";
-- 2026-11-15: the tool list stands, the tool is picked PER QUOTE with the service type as the default,
-- a project's revenue spreads evenly by default).
--
--   service_sub.quote_tool          the DEFAULT tool offered when a quote is created on a deal of this type
--                                   (NULL = by family: manpower for an annuity type under Manpower, else simple)
--   quote_quotes.quote_tool         the tool that BUILT the quote — every quote before this release is manpower
--   proposal_templates.quote_tool   the tool whose quotes print from the template
--   quote_simple_lines              the simple tool's typed lines: description, quantity, unit price (excl. VAT),
--                                   monthly | once_off
-- Tools: manpower (built) · project (not built — the simple tool stands in) · maintenance (not built — likewise)
-- · simple (built). Adding a tool: the three CHECKs here and QUOTE_TOOLS in index.html.
--
-- Additive, re-runnable, SQL-editor safe, no DROP. Run on BOTH databases before or after the code: a
-- database without these columns reads every quote as a manpower quote, disables the tool pickers naming
-- this file, and the simple tool's Pricing tab says the table is missing.

BEGIN;

ALTER TABLE service_sub ADD COLUMN IF NOT EXISTS quote_tool TEXT;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'service_sub_quote_tool_chk') THEN
    ALTER TABLE service_sub ADD CONSTRAINT service_sub_quote_tool_chk CHECK (quote_tool IS NULL OR quote_tool IN ('manpower','project','maintenance','simple'));
  END IF;
END $$;

ALTER TABLE quote_quotes ADD COLUMN IF NOT EXISTS quote_tool TEXT NOT NULL DEFAULT 'manpower';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'quote_quotes_quote_tool_chk') THEN
    ALTER TABLE quote_quotes ADD CONSTRAINT quote_quotes_quote_tool_chk CHECK (quote_tool IN ('manpower','project','maintenance','simple'));
  END IF;
END $$;

ALTER TABLE proposal_templates ADD COLUMN IF NOT EXISTS quote_tool TEXT NOT NULL DEFAULT 'manpower';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'proposal_templates_quote_tool_chk') THEN
    ALTER TABLE proposal_templates ADD CONSTRAINT proposal_templates_quote_tool_chk CHECK (quote_tool IN ('manpower','project','maintenance','simple'));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS quote_simple_lines (
  id             BIGSERIAL     PRIMARY KEY,
  quote_id       BIGINT        NOT NULL REFERENCES quote_quotes(id) ON DELETE CASCADE,
  description    TEXT          NOT NULL DEFAULT '',
  quantity       NUMERIC(12,2) NOT NULL DEFAULT 1 CHECK (quantity >= 0),
  unit_price     NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),   -- the PRICE, excl. VAT
  billing        TEXT          NOT NULL DEFAULT 'monthly' CHECK (billing IN ('monthly','once_off')),
  display_order  SMALLINT      NOT NULL DEFAULT 0,
  created_by     BIGINT        REFERENCES people(id),
  created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_quote_simple_lines_quote ON quote_simple_lines (quote_id, display_order);
ALTER TABLE quote_simple_lines ENABLE ROW LEVEL SECURITY;
GRANT ALL ON quote_simple_lines TO service_role;
GRANT USAGE, SELECT ON SEQUENCE quote_simple_lines_id_seq TO service_role;

-- Statement-level audit, like every other quote table (audit_stmt() from perf_tier1_audit_statement_level.sql).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'audit_stmt') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'quote_simple_lines'::regclass AND tgname = 'audit_ins_quote_simple_lines') THEN
      CREATE TRIGGER audit_ins_quote_simple_lines AFTER INSERT ON quote_simple_lines REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'quote_simple_lines'::regclass AND tgname = 'audit_upd_quote_simple_lines') THEN
      CREATE TRIGGER audit_upd_quote_simple_lines AFTER UPDATE ON quote_simple_lines REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt();
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'quote_simple_lines'::regclass AND tgname = 'audit_del_quote_simple_lines') THEN
      CREATE TRIGGER audit_del_quote_simple_lines AFTER DELETE ON quote_simple_lines REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt();
    END IF;
  END IF;
END $$;

-- Seed the service types' DEFAULT tool once, by name, only where nothing is set yet (a later hand edit on
-- Admin -> Lookups -> Service Sub survives a re-run). The three manpower types -> manpower; Maintenance ->
-- maintenance; every other project-revenue type -> project. Anything else is left NULL (by family).
UPDATE service_sub SET quote_tool = 'manpower'
 WHERE quote_tool IS NULL AND name ~* '(guard|control room)';
UPDATE service_sub SET quote_tool = 'maintenance'
 WHERE quote_tool IS NULL AND name ~* 'maintenance';
UPDATE service_sub SET quote_tool = 'project'
 WHERE quote_tool IS NULL AND (revenue_type = 'project' OR (revenue_type IS NULL AND is_recurring = false));

-- The simple quote's template, once (keyed on its name): cover, a letter, a written scope, the line table,
-- terms, acceptance. Richard edits the wording under Admin -> Proposal Builder -> Proposal Templates.
INSERT INTO proposal_templates (name, service_scope, is_default, active, quote_tool)
SELECT 'Simple quote (standard)', 'Any', false, true, 'simple'
WHERE NOT EXISTS (SELECT 1 FROM proposal_templates WHERE name = 'Simple quote (standard)');

INSERT INTO proposal_template_sections (template_id, section_key, title, display_order, kind, body, mandatory, page_break_before)
SELECT t.id, s.section_key, s.title, s.display_order, s.kind, s.body, s.mandatory, s.page_break_before
FROM proposal_templates t
CROSS JOIN (VALUES
  ('cover', 'Cover', 1, 'generated', NULL, true, false),
  ('intro_letter', 'Introduction', 2, 'boilerplate',
   E'Dear {{contact.name}}\n\nThank you for the opportunity to submit this proposal to {{client.name}}. It sets out the services we propose, the price and the terms on which we would deliver them.',
   true, false),
  ('scope', 'Proposed services', 3, 'prompt',
   E'Describe the services quoted: what will be delivered, where, by whom and by when. Replace this text.',
   true, false),
  ('pricing', 'Pricing', 4, 'generated', NULL, true, true),
  ('terms', 'Terms and conditions', 5, 'boilerplate',
   E'• Prices exclude VAT and hold until {{proposal.valid_until}}.\n• Monthly amounts are invoiced monthly in advance; once-off amounts on acceptance unless agreed otherwise.\n• Invoices are payable within 30 days of invoice date.\n• {{xone.legal_name}} is registered with PSIRA (No. {{xone.psira_no}}).',
   true, false),
  ('acceptance', 'Acceptance', 6, 'generated', NULL, true, true)
) AS s(section_key, title, display_order, kind, body, mandatory, page_break_before)
WHERE t.name = 'Simple quote (standard)' AND t.quote_tool = 'simple'
ON CONFLICT (template_id, section_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- Check: SELECT name, revenue_type, quote_tool FROM service_sub ORDER BY major_id, name;
-- Check: SELECT name, quote_tool FROM proposal_templates;
