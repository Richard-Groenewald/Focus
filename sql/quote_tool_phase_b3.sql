-- ═══════════════════════════════════════════════════════════════════════
-- Quote Tool — Phase B-3 schema (PROPOSAL, NOT EXECUTED)
-- ═══════════════════════════════════════════════════════════════════════
-- Target: Dev (test branch) only. Run AFTER Phase B-2.
--
-- Adds the two catalog tables backing the Standard Posts and Standard
-- Headings admin screens (these were localStorage-only in the prototype).
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE quote_standard_post_names (
  id            BIGSERIAL    PRIMARY KEY,
  name          TEXT         NOT NULL UNIQUE,    -- 'Security Officer', 'Supervisor', etc.
  display_order SMALLINT,
  active        BOOLEAN      NOT NULL DEFAULT true,
  created_by    BIGINT       REFERENCES people(id),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE quote_standard_heading_names (
  id            BIGSERIAL    PRIMARY KEY,
  name          TEXT         NOT NULL UNIQUE,    -- 'Main Gate', 'Response Team', etc.
  display_order SMALLINT,
  active        BOOLEAN      NOT NULL DEFAULT true,
  created_by    BIGINT       REFERENCES people(id),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Seed (from the prototype defaults)

INSERT INTO quote_standard_post_names (name, display_order) VALUES
  ('Security Officer',          1),
  ('Senior Security Officer',   2),
  ('Supervisor',                3),
  ('Armed Response Officer',    4),
  ('Patrol Officer',            5),
  ('Control Room Operator',     6),
  ('Dog Handler',               7),
  ('Mobile Supervisor',         8),
  ('Site Manager',              9)
ON CONFLICT (name) DO NOTHING;

INSERT INTO quote_standard_heading_names (name, display_order) VALUES
  ('Main Gate',          1),
  ('Side Gate',          2),
  ('Reception',          3),
  ('Weighbridge',        4),
  ('Response Team',      5),
  ('Control Room',       6),
  ('Perimeter Patrol',   7),
  ('Management',         8),
  ('Specialist Posts',   9)
ON CONFLICT (name) DO NOTHING;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════
-- Verification:
-- SELECT 'standard_posts',    count(*) FROM quote_standard_post_names
-- UNION ALL SELECT 'standard_headings', count(*) FROM quote_standard_heading_names;
-- Expected: 9 / 9
-- ═══════════════════════════════════════════════════════════════════════
