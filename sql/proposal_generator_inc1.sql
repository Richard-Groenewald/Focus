-- Focus v7.9.41 — Proposal Generator, Increment 1 (2026-09-10).
-- Design: docs/proposal-generator/DESIGN.md (sections 4, 5 and 9).
--
-- Installs the template and document tables the Proposal tab reads, seeds the
-- default template, and puts the Accessories / Training catalogues (already
-- created by quote_tool_phase_b2.sql) into the order the current Xone tool
-- shows them. Increment 1 is preview-and-print only: proposal_documents rows
-- stay at status 'draft'; numbering, issue_proposal() and the ledger side
-- effects arrive with Increment 2. The client hides the Proposal tab when
-- proposal_templates is absent (404 / PGRST205), so this file can ship before
-- or after the deploy. Idempotent. Dev first, then prod.

BEGIN;

-- ── 1. Templates ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS proposal_templates (
  id            BIGSERIAL    PRIMARY KEY,
  name          TEXT         NOT NULL UNIQUE,
  service_scope TEXT,
  is_default    BOOLEAN      NOT NULL DEFAULT false,
  active        BOOLEAN      NOT NULL DEFAULT true,
  created_by    BIGINT       REFERENCES people(id),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_proposal_templates_default
  ON proposal_templates (is_default) WHERE is_default;

CREATE TABLE IF NOT EXISTS proposal_template_sections (
  id                BIGSERIAL    PRIMARY KEY,
  template_id       BIGINT       NOT NULL REFERENCES proposal_templates(id) ON DELETE CASCADE,
  section_key       TEXT         NOT NULL,
  title             TEXT         NOT NULL,
  display_order     SMALLINT     NOT NULL DEFAULT 0,
  kind              TEXT         NOT NULL DEFAULT 'boilerplate'
                                 CHECK (kind IN ('boilerplate','prompt','generated')),
  body              TEXT,
  mandatory         BOOLEAN      NOT NULL DEFAULT false,
  page_break_before BOOLEAN      NOT NULL DEFAULT false,
  UNIQUE (template_id, section_key)
);
CREATE INDEX IF NOT EXISTS idx_proposal_template_sections_template
  ON proposal_template_sections (template_id, display_order);

-- ── 2. Documents (drafts only in Increment 1) ──────────────────────────
CREATE SEQUENCE IF NOT EXISTS proposal_ref_seq;

CREATE TABLE IF NOT EXISTS proposal_documents (
  id            BIGSERIAL    PRIMARY KEY,
  quote_id      BIGINT       NOT NULL REFERENCES quote_quotes(id) ON DELETE CASCADE,
  template_id   BIGINT       NOT NULL REFERENCES proposal_templates(id),
  snapshot_id   BIGINT       REFERENCES quote_snapshots(id),
  version       SMALLINT     NOT NULL DEFAULT 1,
  status        TEXT         NOT NULL DEFAULT 'draft'
                             CHECK (status IN ('draft','issued','superseded','withdrawn')),
  proposal_ref  TEXT,
  issued_at     TIMESTAMPTZ,
  issued_by     BIGINT       REFERENCES people(id),
  valid_until   DATE,
  content_json  JSONB        NOT NULL DEFAULT '{}'::jsonb,
  rendered_html TEXT,
  owner_id      BIGINT       REFERENCES people(id),
  created_by    BIGINT       REFERENCES people(id),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (quote_id, version)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_proposal_documents_one_draft
  ON proposal_documents (quote_id) WHERE status = 'draft';
CREATE UNIQUE INDEX IF NOT EXISTS ux_proposal_documents_ref
  ON proposal_documents (proposal_ref) WHERE proposal_ref IS NOT NULL;

CREATE TABLE IF NOT EXISTS proposal_document_sections (
  document_id   BIGINT   NOT NULL REFERENCES proposal_documents(id) ON DELETE CASCADE,
  section_key   TEXT     NOT NULL,
  included      BOOLEAN  NOT NULL DEFAULT true,
  body_override TEXT,
  PRIMARY KEY (document_id, section_key)
);

-- ── 3. Permission (granted to roles in Increment 2; harmless now) ──────
INSERT INTO permissions (name, description)
VALUES ('issue_proposal', 'Issue (number and freeze) a proposal document to a client')
ON CONFLICT (name) DO NOTHING;

-- ── 4. Xone details the cover and acceptance sections merge in ─────────
-- Registration and VAT numbers come from the home organisation row
-- (organisations.home_organisation = true); PSIRA is not on that row.
INSERT INTO settings (key, value) VALUES
  ('proposal_xone_psira_no',      ''),
  ('proposal_default_validity_days', '30'),
  ('proposal_vat_pct',            '15')
ON CONFLICT DO NOTHING;

-- ── 5. Default template ────────────────────────────────────────────────
INSERT INTO proposal_templates (name, service_scope, is_default)
SELECT 'Manpower — On-Site Guarding (standard)', 'Manpower', true
WHERE NOT EXISTS (SELECT 1 FROM proposal_templates);

INSERT INTO proposal_template_sections (template_id, section_key, title, display_order, kind, body, mandatory, page_break_before)
SELECT t.id, s.section_key, s.title, s.display_order, s.kind, s.body, s.mandatory, s.page_break_before
FROM proposal_templates t
CROSS JOIN (VALUES
  ('cover', 'Cover', 1, 'generated', NULL, true, false),
  ('intro_letter', 'Introduction', 2, 'boilerplate',
   E'Dear {{contact.name}}\n\nThank you for the opportunity to submit this proposal for the provision of security services at {{site.name}}. This document sets out our understanding of your requirements, the service we propose, and the associated pricing.\n\nThis proposal is valid until {{proposal.valid_until}}.\n\nYours sincerely\n\n{{owner.name}}\n{{owner.title}}\n{{xone.legal_name}}',
   true, false),
  ('about_xone', 'About Xone', 3, 'boilerplate',
   E'{{xone.legal_name}} is an integrated security solutions provider delivering manpower, technology and control-room services to the mining, hospitality, residential estate and FMCG sectors across South Africa. Our people are PSIRA-registered, trained in-house and supported by regional management and a 24-hour control room.\n\nLead by Example.',
   false, false),
  ('understanding', 'Our understanding of your requirement', 4, 'prompt',
   E'Describe the client''s environment, the risks identified and the outcomes the client expects from the service. Replace this text.',
   true, false),
  ('scope_posts', 'Proposed deployment', 5, 'generated', NULL, true, true),
  ('pricing', 'Pricing', 6, 'generated', NULL, true, true),
  ('assumptions', 'Assumptions', 7, 'boilerplate',
   E'• Pricing is based on the deployment schedule shown above and the contract start date of {{quote.start_date}}.\n• Public holidays are staffed as shown in the schedule and priced at the applicable statutory rates.\n• A replacement pool provision is included so that leave and absence do not reduce cover on site.\n• Annual escalation follows the applicable sectoral determination and PSIRA-published increases.\n• Prices exclude VAT unless stated otherwise.',
   true, false),
  ('terms', 'Terms and conditions', 8, 'boilerplate',
   E'• Contract term: {{quote.duration_months}} months from {{quote.start_date}}.\n• Invoices are rendered monthly in advance and are payable within 30 days of invoice date.\n• Either party may terminate on 90 days'' written notice after the initial term.\n• This proposal is valid until {{proposal.valid_until}}.',
   true, false),
  ('acceptance', 'Acceptance', 9, 'generated', NULL, true, true)
) AS s(section_key, title, display_order, kind, body, mandatory, page_break_before)
WHERE t.is_default
ON CONFLICT (template_id, section_key) DO NOTHING;

-- ── 6. Catalogue order — as the current Xone tool lists them ───────────
UPDATE quote_accessories a SET display_order = v.o FROM (VALUES
  ('officer_pocket_book',1),('restraints_pouch',2),('baton',3),('torch_rubberized',4),('umbrella',5),
  ('tazer',6),('pepper_spray',7),('bullet_proof_vest',8),('non_lethal_paintball',9),('non_lethal_9mm_pellet',10),
  ('bodyworn_camera',11),('extendable_baton',12),('rubberized_baton',13),('bullet_trap',14),('site_gun_safe',15),
  ('handheld_metal_detector',16),('occurrence_book',17),('bodyworn_harness',18),('torch_zartek',19),('parabellum_9mm',20)
) AS v(code, o) WHERE a.code = v.code;

COMMIT;

-- Verification:
-- SELECT 'templates', count(*) FROM proposal_templates
-- UNION ALL SELECT 'sections', count(*) FROM proposal_template_sections
-- UNION ALL SELECT 'accessories', count(*) FROM quote_accessories
-- UNION ALL SELECT 'training', count(*) FROM quote_training_courses;
-- Expected: 1 / 9 / 20 / 12
