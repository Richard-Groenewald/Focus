-- ═══════════════════════════════════════════════════════════════════════
-- Quote Tool — Phase A schema (PROPOSAL, NOT EXECUTED)
-- ═══════════════════════════════════════════════════════════════════════
-- Target: Dev (test branch) only. Do NOT run on Production until reviewed.
--
-- Scope:
--   • 4 lookup tables (grades, areas, leave types, shared salary option types)
--   • 8 effective-dated rate / catalog tables (HR Setup tiles)
--   • Indexes for the "latest rate as of X" lookup pattern
--   • Current-rate views (one per rate-card table)
--   • 1 new permission row (administer_quote_rates)
--
-- Conventions (matches Focus CLAUDE.md):
--   • IDs: BIGINT / BIGSERIAL
--   • Timestamps: TIMESTAMPTZ for audit, DATE for calendar-day effective dates
--   • Ownership: owner_id, created_by → people(id)
--   • Table prefix: quote_ (namespacing under public; avoids collisions)
--   • Naming: snake_case, typos fixed vs. Xone (e.g. "multiplier" not "muliplier",
--     "occurrence_type" not "occurance_type")
--
-- RLS:
--   • This file does NOT enable RLS — matches Focus's existing pattern.
--   • If you choose Option B (RLS on rate cards), an additional file
--     quote_tool_phase_a_rls.sql will add policies + a helper function.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. LOOKUPS ────────────────────────────────────────────────────────

CREATE TABLE quote_grades (
  id            BIGSERIAL    PRIMARY KEY,
  code          TEXT         NOT NULL UNIQUE,        -- 'A','B','C','D','E'
  description   TEXT         NOT NULL,               -- 'Grade A'
  display_order SMALLINT,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE quote_areas (
  id            BIGSERIAL    PRIMARY KEY,
  code          TEXT         NOT NULL UNIQUE,        -- 'area_1','area_2','area_3'
  description   TEXT         NOT NULL,               -- 'Area 1 (Major Urban)'
  display_order SMALLINT,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE quote_leave_types (
  id            BIGSERIAL    PRIMARY KEY,
  code          TEXT         NOT NULL UNIQUE,        -- 'sick','annual','family_responsibility','maternity','study'
  description   TEXT         NOT NULL,               -- 'Sick Leave'
  display_order SMALLINT,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE quote_shared_salary_option_types (
  id            BIGSERIAL    PRIMARY KEY,
  code          TEXT         NOT NULL UNIQUE,        -- 'health_insurance','provident_fund','bargaining_council','compensation_commissioner','uif','sdl'
  description   TEXT         NOT NULL,               -- 'Health Insurance'
  display_order SMALLINT,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 2. RATE-CARD TABLES ──────────────────────────────────────────────
--
-- Each rate-card row has an effective_date. To find the rate for a given
-- as-of date, query: WHERE effective_date <= $as_of ORDER BY effective_date DESC LIMIT 1
-- per natural key. The current-rate views below do this for "today".

-- ── 2.1 Statutory Salary Rates ───────────────────────────────────────

CREATE TABLE quote_salary_rates (
  id              BIGSERIAL    PRIMARY KEY,
  effective_date  DATE         NOT NULL,
  grade_id        BIGINT       NOT NULL REFERENCES quote_grades(id),
  area_id         BIGINT       NOT NULL REFERENCES quote_areas(id),
  monthly_salary  NUMERIC(12,2) NOT NULL,
  hourly_rate     NUMERIC(8,4)  NOT NULL,
  owner_id        BIGINT       REFERENCES people(id),
  created_by      BIGINT       REFERENCES people(id),
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (effective_date, grade_id, area_id)
);
CREATE INDEX idx_salary_rates_lookup
  ON quote_salary_rates (grade_id, area_id, effective_date DESC);

-- ── 2.2 Extraordinary Hours Rates ────────────────────────────────────
-- Only one row per effective_date. Multipliers are "premium-only" on top
-- of monthly salary (see xone-multiplier-convention memory note).

CREATE TABLE quote_extraordinary_hour_rates (
  id                          BIGSERIAL    PRIMARY KEY,
  effective_date              DATE         NOT NULL UNIQUE,
  overtime_multiplier         NUMERIC(5,3) NOT NULL,
  sunday_multiplier           NUMERIC(5,3) NOT NULL,
  public_holiday_multiplier   NUMERIC(5,3) NOT NULL,
  owner_id                    BIGINT       REFERENCES people(id),
  created_by                  BIGINT       REFERENCES people(id),
  created_at                  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at                  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 2.3 Statutory Allowances ─────────────────────────────────────────
-- Each statutory allowance (Night Shift, Cleaning, Control Centre Op etc.)
-- has a code/slug for stable calc-engine reference, plus a human description
-- for the UI. occurrence_type tells the engine whether the rate is per shift
-- or per month.

CREATE TABLE quote_statutory_allowances (
  id              BIGSERIAL    PRIMARY KEY,
  effective_date  DATE         NOT NULL,
  code            TEXT         NOT NULL,            -- 'cleaning','night_shift','control_centre_operator'…
  description     TEXT         NOT NULL,            -- 'Cleaning Allowance','Night Shift'…
  rate            NUMERIC(10,2) NOT NULL,
  occurrence_type TEXT         NOT NULL CHECK (occurrence_type IN ('shift','monthly')),
  owner_id        BIGINT       REFERENCES people(id),
  created_by      BIGINT       REFERENCES people(id),
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (effective_date, code)
);
CREATE INDEX idx_statutory_allowances_lookup
  ON quote_statutory_allowances (code, effective_date DESC);

-- ── 2.4 Leave Allocations ────────────────────────────────────────────

CREATE TABLE quote_leave_allocations (
  id                  BIGSERIAL    PRIMARY KEY,
  effective_from_date DATE         NOT NULL,
  leave_type_id       BIGINT       NOT NULL REFERENCES quote_leave_types(id),
  no_of_days          INTEGER      NOT NULL CHECK (no_of_days >= 0),
  cycle_days          INTEGER      NOT NULL CHECK (cycle_days > 0),
  average_utilisation NUMERIC(5,2) NOT NULL CHECK (average_utilisation BETWEEN 0 AND 100),  -- percentage
  owner_id            BIGINT       REFERENCES people(id),
  created_by          BIGINT       REFERENCES people(id),
  created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (effective_from_date, leave_type_id)
);
CREATE INDEX idx_leave_allocations_lookup
  ON quote_leave_allocations (leave_type_id, effective_from_date DESC);

-- ── 2.5 Shared Salary Options ────────────────────────────────────────
-- Covers Health Insurance, Provident Fund, Bargaining Council Levy,
-- Compensation Commissioner, UIF Recovery, SDL Recovery.
-- The UI surfaces these as 6 separate tiles, filtered by type.

CREATE TABLE quote_shared_salary_options (
  id                            BIGSERIAL    PRIMARY KEY,
  effective_date                DATE         NOT NULL,
  shared_salary_option_type_id  BIGINT       NOT NULL REFERENCES quote_shared_salary_option_types(id),
  employee_contribution         NUMERIC(10,4) NOT NULL,    -- % or absolute, depending on type
  employer_contribution         NUMERIC(10,4) NOT NULL,
  threshold                     NUMERIC(12,2) NOT NULL DEFAULT 0,
  owner_id                      BIGINT       REFERENCES people(id),
  created_by                    BIGINT       REFERENCES people(id),
  created_at                    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at                    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (effective_date, shared_salary_option_type_id)
);
CREATE INDEX idx_shared_salary_options_lookup
  ON quote_shared_salary_options (shared_salary_option_type_id, effective_date DESC);

-- ── 2.6 Calculation Ratios ───────────────────────────────────────────
-- Covers Replacement Pool Provision, Area Management Overhead, HR Calculation Ratios.
-- code is the stable calc-engine reference; description is the human label.
-- ratio_value is TEXT to support various units (percentage, hours, days, multiplier).

CREATE TABLE quote_calculation_ratios (
  id                BIGSERIAL    PRIMARY KEY,
  effective_date    DATE         NOT NULL,
  code              TEXT         NOT NULL,    -- 'replacement_pool_provision','area_manager_overhead','avg_shifts_per_month','sunday_hours_per_month'…
  description       TEXT         NOT NULL,    -- 'Replacement Pool Provision','Area Manager Overhead'…
  ratio_value       TEXT         NOT NULL,    -- the actual number (stored as text to preserve precision of computed ratios)
  unit              TEXT,                     -- 'hours','shifts','%','Rand','Days','Numeric Multiplier'
  enabled           BOOLEAN      NOT NULL DEFAULT true,
  calculation_note  TEXT,
  owner_id          BIGINT       REFERENCES people(id),
  created_by        BIGINT       REFERENCES people(id),
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (effective_date, code)
);
CREATE INDEX idx_calculation_ratios_lookup
  ON quote_calculation_ratios (code, effective_date DESC);

-- ── 2.7 Discretionary Allowances (catalog) ───────────────────────────
-- These are catalog entries used to drive the per-post allowance UI.
-- Effective-dated for consistency (Xone has no date on these; you said
-- to add it).

CREATE TABLE quote_discretionary_allowances (
  id              BIGSERIAL    PRIMARY KEY,
  effective_date  DATE         NOT NULL,
  code            TEXT         NOT NULL,    -- 'seniority','supervisor','drivers','transport'…
  name            TEXT         NOT NULL,    -- 'Seniority Allowance'
  description     TEXT,
  display_order   SMALLINT,
  owner_id        BIGINT       REFERENCES people(id),
  created_by      BIGINT       REFERENCES people(id),
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (effective_date, code)
);

-- ── 2.8 Discretionary Incentives (catalog) ───────────────────────────

CREATE TABLE quote_discretionary_incentives (
  id              BIGSERIAL    PRIMARY KEY,
  effective_date  DATE         NOT NULL,
  code            TEXT         NOT NULL,    -- 'performance','attendance'
  name            TEXT         NOT NULL,    -- 'Performance Incentive'
  description     TEXT,
  display_order   SMALLINT,
  owner_id        BIGINT       REFERENCES people(id),
  created_by      BIGINT       REFERENCES people(id),
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  UNIQUE (effective_date, code)
);

-- ── 3. CURRENT-RATE VIEWS ────────────────────────────────────────────
-- One view per rate-card table. Returns the latest row per natural key
-- whose effective_date <= today. The calc engine uses these to answer
-- "what's the rate right now?" without joining/filtering itself.

CREATE OR REPLACE VIEW v_quote_salary_rates_current AS
SELECT DISTINCT ON (grade_id, area_id) *
FROM quote_salary_rates
WHERE effective_date <= CURRENT_DATE
ORDER BY grade_id, area_id, effective_date DESC;

CREATE OR REPLACE VIEW v_quote_extraordinary_hour_rates_current AS
SELECT *
FROM quote_extraordinary_hour_rates
WHERE effective_date <= CURRENT_DATE
ORDER BY effective_date DESC
LIMIT 1;

CREATE OR REPLACE VIEW v_quote_statutory_allowances_current AS
SELECT DISTINCT ON (code) *
FROM quote_statutory_allowances
WHERE effective_date <= CURRENT_DATE
ORDER BY code, effective_date DESC;

CREATE OR REPLACE VIEW v_quote_leave_allocations_current AS
SELECT DISTINCT ON (leave_type_id) *
FROM quote_leave_allocations
WHERE effective_from_date <= CURRENT_DATE
ORDER BY leave_type_id, effective_from_date DESC;

CREATE OR REPLACE VIEW v_quote_shared_salary_options_current AS
SELECT DISTINCT ON (shared_salary_option_type_id) *
FROM quote_shared_salary_options
WHERE effective_date <= CURRENT_DATE
ORDER BY shared_salary_option_type_id, effective_date DESC;

CREATE OR REPLACE VIEW v_quote_calculation_ratios_current AS
SELECT DISTINCT ON (code) *
FROM quote_calculation_ratios
WHERE effective_date <= CURRENT_DATE AND enabled = true
ORDER BY code, effective_date DESC;

CREATE OR REPLACE VIEW v_quote_discretionary_allowances_current AS
SELECT DISTINCT ON (code) *
FROM quote_discretionary_allowances
WHERE effective_date <= CURRENT_DATE
ORDER BY code, effective_date DESC;

CREATE OR REPLACE VIEW v_quote_discretionary_incentives_current AS
SELECT DISTINCT ON (code) *
FROM quote_discretionary_incentives
WHERE effective_date <= CURRENT_DATE
ORDER BY code, effective_date DESC;

-- ── 4. PERMISSION ────────────────────────────────────────────────────

INSERT INTO permissions (name, description)
VALUES ('administer_quote_rates', 'Edit Quote Tool rate cards (HR Setup, etc.)')
ON CONFLICT (name) DO NOTHING;

-- After this runs, manually wire this permission to the Administrator role
-- via Focus's existing Role Permissions UI.

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════
-- SEED DATA (separate file)
-- ═══════════════════════════════════════════════════════════════════════
-- Seed inserts for lookups + rate cards (from the prototype data) will
-- live in sql/quote_tool_phase_a_seed.sql. Run that file ONLY after this
-- one has been applied and reviewed.
