-- ═══════════════════════════════════════════════════════════════════════
-- Quote Tool — Phase B-2 schema + accessory/training seed (PROPOSAL, NOT EXECUTED)
-- ═══════════════════════════════════════════════════════════════════════
-- Target: Dev (test branch) only. Run AFTER Phase B (quote_tool_phase_b.sql).
--
-- Scope:
--   • quote_accessories         — catalog of required accessories (BPV, baton…)
--   • quote_training_courses    — catalog of training requirements (Induction…)
--   • quote_post_discretionary_allowances  — m2m posts ↔ disc allowances + per-post rate
--   • quote_post_discretionary_incentives  — m2m posts ↔ disc incentives + per-post rate
--   • quote_post_statutory_allowances      — m2m posts ↔ statutory toggles (no rate, lives on master)
--   • quote_post_accessories               — m2m posts ↔ accessories
--   • quote_post_training                  — m2m posts ↔ training
--   • Seed data for both catalogs (from the Xone post-edit screen)
--
-- All m2m junction tables use a composite PK (post_id, ref_id) — natural for
-- "is this toggle on for this post" and de-dups by definition.
--
-- For discretionary allowances/incentives the *rate is per-post* (each post
-- can have a different rand amount for the same allowance type). The catalog
-- only holds the name; the actual rand value lives on the junction.
-- ═══════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. ACCESSORIES CATALOG ───────────────────────────────────────────
-- Equipment/items required at a post (Body armour, batons, comms, etc.).
-- Cost info lives elsewhere (will be in Contract Support Items in a later
-- phase). For now we only need the catalog so the toggle works.

CREATE TABLE quote_accessories (
  id              BIGSERIAL    PRIMARY KEY,
  code            TEXT         NOT NULL UNIQUE,
  name            TEXT         NOT NULL,
  display_order   SMALLINT,
  active          BOOLEAN      NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 2. TRAINING COURSES CATALOG ──────────────────────────────────────

CREATE TABLE quote_training_courses (
  id              BIGSERIAL    PRIMARY KEY,
  code            TEXT         NOT NULL UNIQUE,
  name            TEXT         NOT NULL,
  display_order   SMALLINT,
  active          BOOLEAN      NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── 3. POST × DISCRETIONARY ALLOWANCES ───────────────────────────────
-- One row per (post, allowance) the user has set on this post. rate_amount
-- is the rand value for THIS post (can differ from any default).

CREATE TABLE quote_post_discretionary_allowances (
  post_id                    BIGINT       NOT NULL REFERENCES quote_posts(id) ON DELETE CASCADE,
  discretionary_allowance_id BIGINT       NOT NULL REFERENCES quote_discretionary_allowances(id),
  rate_amount                NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_at                 TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at                 TIMESTAMPTZ  NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, discretionary_allowance_id)
);

-- ── 4. POST × DISCRETIONARY INCENTIVES ───────────────────────────────

CREATE TABLE quote_post_discretionary_incentives (
  post_id                    BIGINT       NOT NULL REFERENCES quote_posts(id) ON DELETE CASCADE,
  discretionary_incentive_id BIGINT       NOT NULL REFERENCES quote_discretionary_incentives(id),
  rate_amount                NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_at                 TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at                 TIMESTAMPTZ  NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, discretionary_incentive_id)
);

-- ── 5. POST × STATUTORY ALLOWANCES (toggles) ─────────────────────────
-- These are pure toggles — the rate lives on quote_statutory_allowances
-- (rate-card table). Presence of the row = the toggle is ON.

CREATE TABLE quote_post_statutory_allowances (
  post_id                BIGINT       NOT NULL REFERENCES quote_posts(id) ON DELETE CASCADE,
  statutory_allowance_id BIGINT       NOT NULL REFERENCES quote_statutory_allowances(id),
  created_at             TIMESTAMPTZ  NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, statutory_allowance_id)
);

-- ── 6. POST × ACCESSORIES (toggles) ──────────────────────────────────

CREATE TABLE quote_post_accessories (
  post_id        BIGINT       NOT NULL REFERENCES quote_posts(id) ON DELETE CASCADE,
  accessory_id   BIGINT       NOT NULL REFERENCES quote_accessories(id),
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, accessory_id)
);

-- ── 7. POST × TRAINING (toggles) ─────────────────────────────────────

CREATE TABLE quote_post_training (
  post_id            BIGINT       NOT NULL REFERENCES quote_posts(id) ON DELETE CASCADE,
  training_course_id BIGINT       NOT NULL REFERENCES quote_training_courses(id),
  created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, training_course_id)
);

-- ── 8. SEED — ACCESSORIES (from the Xone post-edit screen) ───────────

INSERT INTO quote_accessories (code, name, display_order) VALUES
  ('tazer',                 'Tazer (Electric Paralyzer)',  1),
  ('pepper_spray',          'Pepper Spray',                2),
  ('bullet_proof_vest',     'Bullet Proof Vest',           3),
  ('bodyworn_camera',       'Bodyworn Camera',             4),
  ('extendable_baton',      'Extendable Baton',            5),
  ('rubberized_baton',      'Rubberized Baton',            6),
  ('bullet_trap',           'Bullet Trap',                 7),
  ('site_gun_safe',         'Site Gun Safe',               8),
  ('bodyworn_harness',      'Bodyworn Harness',            9),
  ('torch_zartek',          'Torch/Spotlight - Zartek hand held', 10),
  ('occurrence_book',       'Occurrence Book',            11),
  ('handheld_metal_detector','Handheld Metal Detector',   12),
  ('parabellum_9mm',        '9mm Parabellum',             13),
  ('officer_pocket_book',   'Security Officer Pocket Book',14),
  ('restraints_pouch',      'Restraints & Pouch',         15),
  ('baton',                 'Baton',                      16),
  ('torch_rubberized',      'Torch/Spotlight - Rubberized',17),
  ('umbrella',              'Umbrella',                   18),
  ('non_lethal_paintball',  'Non-Lethal - Paintball Gun', 19),
  ('non_lethal_9mm_pellet', 'Non-Lethal - 9mm Pellet Gun',20)
ON CONFLICT (code) DO NOTHING;

-- ── 9. SEED — TRAINING COURSES (from the Xone post-edit screen) ──────

INSERT INTO quote_training_courses (code, name, display_order) VALUES
  ('induction_all_staff',         'Induction training - All staff',     1),
  ('control_room_operators',      'Control Room Operators',             2),
  ('security_officer_semi_skilled','Security Officer (Semi-skilled)',   3),
  ('supervisors_shift_leaders',   'Supervisors/Shift Leaders',          4),
  ('contract_manager_site_seniors','Contract Manager/Site Seniors',     5),
  ('dog_handler',                 'Dog Handler',                        6),
  ('regulation_21',               'Regulation 21',                      7),
  ('fire_fighting',               'Fire Fighting',                      8),
  ('specialised_training',        'Specialised Training',               9),
  ('armed_response_officers',     'Armed Response Officers',           10),
  ('snake_handling',              'Snake Handling',                    11),
  ('first_aid_1_3',               'First Aid 1-3',                     12)
ON CONFLICT (code) DO NOTHING;

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════
-- Verification:
--
-- SELECT 'accessories', count(*) FROM quote_accessories
-- UNION ALL SELECT 'training_courses', count(*) FROM quote_training_courses
-- UNION ALL SELECT 'post_disc_allowances (0)',  count(*) FROM quote_post_discretionary_allowances
-- UNION ALL SELECT 'post_disc_incentives (0)',  count(*) FROM quote_post_discretionary_incentives
-- UNION ALL SELECT 'post_statutory (0)',        count(*) FROM quote_post_statutory_allowances
-- UNION ALL SELECT 'post_accessories (0)',      count(*) FROM quote_post_accessories
-- UNION ALL SELECT 'post_training (0)',         count(*) FROM quote_post_training;
--
-- Expected: 20 / 12 / 0 / 0 / 0 / 0 / 0
-- ═══════════════════════════════════════════════════════════════════════
