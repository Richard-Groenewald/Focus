-- v7.10.48 — PROPOSAL TYPE BY DEAL TYPE (Richard, 2026-11-19: "each deal type has a proposal type (set in
-- site admin). where a proposal type has not been created for the deal type, say so under proposal and have
-- the user create one outside focus").
--
-- proposal_types is the list of proposal tools Focus offers (Site Admin → Lookups → Proposal Types); `tool`
-- names the code path — today only the manpower quote tool exists. A SERVICE TYPE (service_sub) points at
-- one through proposal_type_id (Lookups → Service Sub); a deal whose type points at nothing gets a note on
-- its Proposal Builder tab instead of the quote tool. One home per rule — the service type row, beside its
-- revenue type and margin rule.
--
-- Additive, re-runnable, SQL-editor safe. Run on BOTH databases, before or after the code: a database
-- without the table keeps today's behaviour (the quote tool on every deal) and the Service Sub form's
-- Proposal type select is refused naming this file. Seeds ONCE: the one tool row (keyed on `tool`), and the
-- link from the manpower service types — Guarding Services, On-site and Off-site Control Room (annuity types
-- named guarding / control room; the project-revenue Control Room Build / Upgrade / Design are left unlinked)
-- — only while they point at nothing, so a later edit on the admin page survives a re-run.

CREATE TABLE IF NOT EXISTS proposal_types (
  id             BIGSERIAL    PRIMARY KEY,
  name           TEXT         NOT NULL,
  tool           TEXT         NOT NULL DEFAULT 'manpower_quote' CHECK (tool IN ('manpower_quote')),
  description    TEXT,
  display_order  INTEGER      NOT NULL DEFAULT 0,
  active         BOOLEAN      NOT NULL DEFAULT true,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE proposal_types IS 'The proposal tools Focus offers; a service type (service_sub.proposal_type_id) points at one. tool = the code path (PROPOSAL_TOOLS in the app).';

ALTER TABLE proposal_types ENABLE ROW LEVEL SECURITY;
GRANT ALL ON proposal_types TO service_role;
GRANT USAGE, SELECT ON SEQUENCE proposal_types_id_seq TO service_role;

DO $$
DECLARE t text := 'proposal_types';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_ins_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_ins_%1$I AFTER INSERT ON %1$I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_upd_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_upd_%1$I AFTER UPDATE ON %1$I REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_del_' || t) THEN
    EXECUTE format('CREATE TRIGGER audit_del_%1$I AFTER DELETE ON %1$I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
  END IF;
END $$;

ALTER TABLE service_sub ADD COLUMN IF NOT EXISTS proposal_type_id BIGINT REFERENCES proposal_types(id);
COMMENT ON COLUMN service_sub.proposal_type_id IS 'The proposal tool a deal of this service type builds its proposal with (proposal_types); NULL = none in Focus, the proposal is made outside and attached under Files → Proposals.';
CREATE INDEX IF NOT EXISTS idx_service_sub_proposal_type ON service_sub (proposal_type_id);

-- Seed once.
INSERT INTO proposal_types (name, tool, description, display_order)
SELECT 'Manpower quote', 'manpower_quote', 'Posts and shifts, support items, site mobility, the labour engine and the generated proposal', 1
 WHERE NOT EXISTS (SELECT 1 FROM proposal_types WHERE tool = 'manpower_quote');

UPDATE service_sub s
   SET proposal_type_id = (SELECT id FROM proposal_types WHERE tool = 'manpower_quote' ORDER BY id LIMIT 1)
 WHERE s.proposal_type_id IS NULL
   AND COALESCE(s.revenue_type, CASE WHEN s.is_recurring = false THEN 'project' ELSE 'annuity' END) = 'annuity'
   AND (s.name ~* 'guarding' OR s.name ~* 'control room');

NOTIFY pgrst, 'reload schema';

SELECT s.id, s.name, s.revenue_type, p.name AS proposal_type
  FROM service_sub s LEFT JOIN proposal_types p ON p.id = s.proposal_type_id
 ORDER BY s.major_id, s.id;
