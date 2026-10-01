-- Billing schedules (v7.9.89, contract billing step 1), Richard 2026-10-01: "yes, start step 1, dev only".
-- Finance builds every contract invoice as one Excel sheet, types a one-line summary of each into a
-- Pastel Partner import file and imports it. Focus takes over: each sheet becomes a BILLING SCHEDULE —
-- the invoice as it recurs every month — from which the monthly run (step 2) makes numbered invoices,
-- the Pastel file and the detailed PDF.
--
--   billing_schedules       one per recurring invoice: the contract it bills (deal_id; NULL until
--                           matched), what the client document prints (title, bill-to block, client VAT
--                           no, order / proposal-or-contract / project numbers), what Pastel needs
--                           (customer code, GL code, cost centre, branch, description stem, date rule),
--                           escalation facts from finance's index (PSIRA %, CPI %, month, note), the
--                           client's own cost code (Harmony), and total_adjust: the hand-set cents
--                           finance's total formula adds, so a schedule reproduces the sheet exactly.
--   billing_schedule_lines  the itemised body in print order. kind: item (qty × unit price), amount (a
--                           line with only an amount — a share, a discount), subtotal (display only),
--                           heading, text. amount = what the sheet displays; in_total = the sheet's total
--                           formula counts it (some lines show a full site cost for information only).
--                           unit_formula keeps finance's formula (base × escalation factors) for step 3.
--
-- Totals: Σ amount where in_total + total_adjust = Total Excluding VAT; VAT 15% on that total.
-- Additive, re-runnable. DEV only for now; RLS on; statement-level audit like every id table.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS billing_schedules (
  id                     BIGSERIAL PRIMARY KEY,
  deal_id                BIGINT REFERENCES deals(id) ON DELETE SET NULL,
  match_note             TEXT,
  name                   TEXT NOT NULL,
  title                  TEXT,
  bill_to_name           TEXT,
  bill_to_address        TEXT,
  client_vat_no          TEXT,
  order_no               TEXT,
  ref_label              TEXT NOT NULL DEFAULT 'Proposal No',
  ref_value              TEXT,
  project_no             TEXT,
  client_cost_code       TEXT,
  pastel_customer_code   TEXT NOT NULL,
  pastel_gl_code         TEXT,
  pastel_cost_centre     TEXT,
  pastel_branch          TEXT,
  pastel_desc_stem       TEXT,
  date_rule              TEXT NOT NULL DEFAULT 'first_of_month'
                         CHECK (date_rule IN ('first_of_month', 'last_of_previous')),
  escalation_psira_pct   NUMERIC(8,5),
  escalation_cpi_pct     NUMERIC(8,5),
  escalation_month       TEXT,
  notes                  TEXT,
  total_adjust           NUMERIC(18,6) NOT NULL DEFAULT 0,
  active                 BOOLEAN NOT NULL DEFAULT true,
  sort_order             INTEGER NOT NULL DEFAULT 0,
  source_file            TEXT,
  source_sheet           TEXT,
  source_invoice_no      INTEGER,
  created_by             BIGINT REFERENCES people(id),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS billing_schedules_deal_idx ON billing_schedules (deal_id);
CREATE UNIQUE INDEX IF NOT EXISTS billing_schedules_source_uq ON billing_schedules (source_file, source_sheet)
  WHERE source_sheet IS NOT NULL;

CREATE TABLE IF NOT EXISTS billing_schedule_lines (
  id              BIGSERIAL PRIMARY KEY,
  schedule_id     BIGINT NOT NULL REFERENCES billing_schedules(id) ON DELETE CASCADE,
  sort_order      INTEGER NOT NULL DEFAULT 0,
  kind            TEXT NOT NULL CHECK (kind IN ('item', 'amount', 'subtotal', 'heading', 'text')),
  item_no         INTEGER,
  qty             NUMERIC(12,4),
  description     TEXT,
  unit_price      NUMERIC(18,6),
  amount          NUMERIC(18,6),
  in_total        BOOLEAN NOT NULL DEFAULT false,
  unit_formula    TEXT,
  amount_formula  TEXT
);
CREATE INDEX IF NOT EXISTS billing_schedule_lines_schedule_idx ON billing_schedule_lines (schedule_id, sort_order);

ALTER TABLE billing_schedules      ENABLE ROW LEVEL SECURITY;
ALTER TABLE billing_schedule_lines ENABLE ROW LEVEL SECURITY;
GRANT ALL ON billing_schedules, billing_schedule_lines TO service_role;
GRANT USAGE, SELECT ON SEQUENCE billing_schedules_id_seq, billing_schedule_lines_id_seq TO service_role;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['billing_schedules', 'billing_schedule_lines'] LOOP
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

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT (SELECT count(*) FROM billing_schedules) AS schedules, (SELECT count(*) FROM billing_schedule_lines) AS lines;
