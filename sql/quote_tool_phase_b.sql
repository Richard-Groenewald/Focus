-- ═══════════════════════════════════════════════════════════════════════
-- Quote Tool — Phase B schema (PROPOSAL, NOT EXECUTED)
-- ═══════════════════════════════════════════════════════════════════════
-- Target: Dev (test branch) only. Run AFTER Phase A (quote_tool_phase_a.sql
-- and quote_tool_phase_a_seed.sql) is applied and verified.
--
-- Scope (Phase B-1):
--   • quote_sites      — Organisation → Site → Quote linkage
--   • quote_quotes     — quote header; mandatory FK to deals(id)
--   • quote_posts      — posts within a quote, FK to quote
--   • quote_post_shifts — shift schedule cells per post
--   • quote_snapshots  — frozen rate-card values used at calc time (audit)
--   • Permissions: create_quote, view_all_quotes
--
-- Deferred to Phase B-2 (when the UI surfaces them):
--   • quote_post_allowances    (m2m to quote_discretionary_allowances)
--   • quote_post_incentives    (m2m to quote_discretionary_incentives)
--   • quote_post_statutory     (m2m to quote_statutory_allowances)
--   • quote_post_accessories, quote_post_training (catalogs not yet built)
--
-- Proposal Builder integration:
--   • The Proposal Builder UI is a new tab on Focus's Opportunity page
--   • A deal can have N quotes; each quote points to its deal
--   • Site context optionally sits on the quote (not the deal) for now —
--     a deal could have quotes for different sites later
--
-- Conventions (same as Phase A):
--   • IDs: BIGINT / BIGSERIAL
--   • Audit: owner_id, created_by → people(id); created_at/updated_at TIMESTAMPTZ
--   • Table prefix: quote_
--   • Naming: snake_case
--   • No RLS (matches Focus pattern; tighten later — see focus-no-rls-app-layer-security memory)
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. SITES ──────────────────────────────────────────────────────────
-- A physical location belonging to an organisation. One org can have many
-- sites; one site can host many quotes over time.

CREATE TABLE quote_sites (
  id              BIGSERIAL    PRIMARY KEY,
  organisation_id BIGINT       NOT NULL REFERENCES organisations(id) ON DELETE RESTRICT,
  name            TEXT         NOT NULL,                                -- 'RCL Sugar Komati Plant'
  address_line1   TEXT,
  address_city    TEXT,
  region          TEXT,                                                  -- 'Western Cape', 'Gauteng', 'Mpumalanga' (matches existing Focus region usage)
  area_id         BIGINT       REFERENCES quote_areas(id),              -- which salary area applies (for rate lookups)
  notes           TEXT,
  owner_id        BIGINT       REFERENCES people(id),
  created_by      BIGINT       REFERENCES people(id),
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_quote_sites_org ON quote_sites (organisation_id);

-- ── 2. QUOTES ─────────────────────────────────────────────────────────
-- The quote header. Every quote is anchored to a deal (the Proposal Builder
-- tab is inside the deal). Sites are optional but the calc engine uses the
-- site's area_id for salary lookups if present, falling back to a default.
--
-- A "regeneration at a different date" creates a new row with original_quote_id
-- pointing at the source — both rows survive (coexist + linked).

CREATE TABLE quote_quotes (
  id                       BIGSERIAL    PRIMARY KEY,
  deal_id                  BIGINT       NOT NULL REFERENCES deals(id) ON DELETE CASCADE,
  site_id                  BIGINT       REFERENCES quote_sites(id),
  original_quote_id        BIGINT       REFERENCES quote_quotes(id),  -- self-ref for revisions/regenerations
  version                  SMALLINT     NOT NULL DEFAULT 1,
  contract_name            TEXT         NOT NULL,
  quote_date               DATE         NOT NULL DEFAULT CURRENT_DATE,
  contract_start_date      DATE         NOT NULL,
  contract_duration_months SMALLINT     NOT NULL CHECK (contract_duration_months > 0),
  shifts_per_day           SMALLINT     NOT NULL DEFAULT 2 CHECK (shifts_per_day BETWEEN 1 AND 4),
  margin_pct               NUMERIC(5,2) NOT NULL DEFAULT 20.00,           -- true gross margin (price-side formula — see xone-margin-convention)
  status                   TEXT         NOT NULL DEFAULT 'draft'
                                       CHECK (status IN ('draft','sent','accepted','rejected','lost','expired')),
  valid_until              DATE,                                          -- typically quote_date + 30
  notes                    TEXT,
  owner_id                 BIGINT       REFERENCES people(id),
  created_by               BIGINT       REFERENCES people(id),
  created_at               TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_quote_quotes_deal     ON quote_quotes (deal_id);
CREATE INDEX idx_quote_quotes_status   ON quote_quotes (status);
CREATE INDEX idx_quote_quotes_original ON quote_quotes (original_quote_id) WHERE original_quote_id IS NOT NULL;

-- ── 3. POSTS ──────────────────────────────────────────────────────────
-- A post inside a quote. heading_text is freeform (e.g. 'Main Gate',
-- 'Response Team'); could be promoted to a FK lookup later. fixed_salary
-- overrides the grade-based salary if set (with the MinimumFixedSalaryPSIRA
-- ratio enforced in the calc engine).
--
-- ON DELETE CASCADE on quote_id: deleting a quote removes its posts.

CREATE TABLE quote_posts (
  id                        BIGSERIAL    PRIMARY KEY,
  quote_id                  BIGINT       NOT NULL REFERENCES quote_quotes(id) ON DELETE CASCADE,
  heading_text              TEXT,                                         -- 'Main Gate', 'Response Team', NULL = ungrouped
  display_order             SMALLINT     NOT NULL DEFAULT 0,
  name                      TEXT         NOT NULL,                        -- 'Security Officer', 'Senior Supervisor'
  grade_id                  BIGINT       REFERENCES quote_grades(id),
  area_id                   BIGINT       REFERENCES quote_areas(id),     -- can override the site's area
  uniform                   TEXT,                                         -- 'Combat', 'Formal', etc.
  description               TEXT,
  fixed_salary              NUMERIC(12,2),                                -- NULL = use grade-based salary lookup
  exclude_replacement_pool  BOOLEAN      NOT NULL DEFAULT false,
  margin_pct_override       NUMERIC(5,2),                                 -- NULL = use quote-level margin
  owner_id                  BIGINT       REFERENCES people(id),
  created_by                BIGINT       REFERENCES people(id),
  created_at                TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at                TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_quote_posts_quote ON quote_posts (quote_id);

-- ── 4. POST SHIFTS ────────────────────────────────────────────────────
-- One row per (post × shift_index × day_type). For a 2-shift post:
-- 2 shifts × 8 day-types = 16 rows. Max 4 × 8 = 32 rows per post.
-- num_officers = concurrent officers on duty for that shift on that day.

CREATE TABLE quote_post_shifts (
  post_id      BIGINT      NOT NULL REFERENCES quote_posts(id) ON DELETE CASCADE,
  shift_index  SMALLINT    NOT NULL CHECK (shift_index BETWEEN 1 AND 4),
  day_type     TEXT        NOT NULL CHECK (day_type IN
                            ('monday','tuesday','wednesday','thursday','friday',
                             'saturday','sunday','public_holiday')),
  num_officers SMALLINT    NOT NULL DEFAULT 0 CHECK (num_officers >= 0),
  start_time   TIME        NOT NULL,
  end_time     TIME        NOT NULL,
  PRIMARY KEY (post_id, shift_index, day_type)
);

-- ── 5. QUOTE SNAPSHOTS ────────────────────────────────────────────────
-- Frozen copy of the rate cards used at calc time. Allows "regenerate this
-- quote at the original date" + audit ("show me what rates we quoted off").
-- One row per calc event; the latest one is the canonical state.

CREATE TABLE quote_snapshots (
  id           BIGSERIAL    PRIMARY KEY,
  quote_id     BIGINT       NOT NULL REFERENCES quote_quotes(id) ON DELETE CASCADE,
  snapshot_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  as_of_date   DATE         NOT NULL,                                  -- the date the rates were looked up for
  rate_data    JSONB        NOT NULL,                                  -- full rate-card values applied: salary_rates, statutory_allowances, calculation_ratios, etc.
  created_by   BIGINT       REFERENCES people(id)
);
CREATE INDEX idx_quote_snapshots_quote ON quote_snapshots (quote_id, snapshot_at DESC);

-- ── 6. VIEWS ──────────────────────────────────────────────────────────
-- Display helpers — the Proposal Builder tab can SELECT from these.

CREATE OR REPLACE VIEW v_quote_quotes_full AS
SELECT
  q.id, q.deal_id, q.site_id, q.original_quote_id, q.version,
  q.contract_name, q.quote_date, q.contract_start_date,
  q.contract_duration_months, q.shifts_per_day, q.margin_pct,
  q.status, q.valid_until, q.notes,
  q.owner_id, q.created_by, q.created_at, q.updated_at,
  d.name        AS deal_name,
  o.id          AS organisation_id,
  o.name        AS organisation_name,
  s.name        AS site_name
FROM quote_quotes q
JOIN deals d            ON d.id = q.deal_id
JOIN organisations o    ON o.id = d.org_id
LEFT JOIN quote_sites s ON s.id = q.site_id;

CREATE OR REPLACE VIEW v_quote_posts_full AS
SELECT
  p.*,
  g.code AS grade_code, g.description AS grade_description,
  a.code AS area_code,  a.description AS area_description
FROM quote_posts p
LEFT JOIN quote_grades g ON g.id = p.grade_id
LEFT JOIN quote_areas  a ON a.id = p.area_id;

-- ── 7. PERMISSIONS ────────────────────────────────────────────────────

INSERT INTO permissions (name, description)
VALUES
  ('create_quote',     'Create and edit quotes in the Proposal Builder'),
  ('view_all_quotes',  'View quotes owned by other users (managers)')
ON CONFLICT (name) DO NOTHING;

-- Wire these to the appropriate roles via Focus's existing Role Permissions UI.

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════
-- POST-RUN: no seed data for Phase B (quotes are user-created, not seeded).
-- Optional smoke test: insert one quote against an existing deal, verify
-- the v_quote_quotes_full view shows it with org/site joined correctly.
-- ═══════════════════════════════════════════════════════════════════════
