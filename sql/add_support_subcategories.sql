-- Focus v7.9.71 — Support item subcategories (Richard, 2026-09-19).
-- "I want to create a number of subcategories to make working with them easier." Agreed list:
--   Offensive   — Lethal · Less-lethal · Impact · Restraint
--   Defensive   — Protective · Detection · Lighting
--   Communications
--   Evidence and Recording
--   Welfare
-- Ten leaves, each carrying its group; an item picks exactly one leaf (quote_accessories.
-- subcategory_id). A small admin list (Proposal Builder → Support Item Subcategories) owns the
-- names and their order; the Workforce Support Items page, each post's checklist and the quote's
-- Workforce Support Items tab group by it. Workforce only for now — the table carries a category
-- so contract / service can join later without a second table.
--
-- Seeded rows carry a stable `code` (the seed keys on it, so renaming a row on the admin page
-- never resurrects the old name on a re-run); rows added on the admin page have no code and no
-- uniqueness on their names (the generic editor inserts a blank placeholder first, so a name key
-- would refuse a second "+ Add row"). Deleting a subcategory that still files items is refused by
-- the database — set it inactive instead; its items keep their heading. The one-time backfill of
-- today's items runs only while nothing has been filed yet.
-- Re-runnable, and upgrades a database that ran the first cut of this file. Additive: old code
-- ignores the new column and table. Run on BOTH databases.

BEGIN;

CREATE TABLE IF NOT EXISTS quote_support_subcategories (
  id            BIGSERIAL    PRIMARY KEY,
  category      TEXT         NOT NULL DEFAULT 'workforce' CHECK (category IN ('workforce','contract','service')),
  code          TEXT,
  group_name    TEXT         NOT NULL,
  name          TEXT         NOT NULL,
  display_order SMALLINT,
  active        BOOLEAN      NOT NULL DEFAULT true,
  created_by    BIGINT       REFERENCES people(id),
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
ALTER TABLE quote_support_subcategories ADD COLUMN IF NOT EXISTS code TEXT;
ALTER TABLE quote_support_subcategories DROP CONSTRAINT IF EXISTS quote_support_subcategories_category_group_name_name_key;
CREATE UNIQUE INDEX IF NOT EXISTS quote_support_subcategories_code_key ON quote_support_subcategories (code) WHERE code IS NOT NULL;

-- A database that ran the first cut has the ten rows without codes: give them theirs.
UPDATE quote_support_subcategories s
   SET code = v.code
  FROM (VALUES
    ('Offensive', 'Lethal', 'wf_lethal'), ('Offensive', 'Less-lethal', 'wf_less_lethal'), ('Offensive', 'Impact', 'wf_impact'), ('Offensive', 'Restraint', 'wf_restraint'),
    ('Defensive', 'Protective', 'wf_protective'), ('Defensive', 'Detection', 'wf_detection'), ('Defensive', 'Lighting', 'wf_lighting'),
    ('Communications', 'Communications', 'wf_communications'), ('Evidence and Recording', 'Evidence and Recording', 'wf_evidence_recording'), ('Welfare', 'Welfare', 'wf_welfare')
  ) AS v(group_name, name, code)
 WHERE s.code IS NULL AND s.category = 'workforce' AND s.group_name = v.group_name AND s.name = v.name;

INSERT INTO quote_support_subcategories (category, code, group_name, name, display_order) VALUES
  ('workforce', 'wf_lethal',             'Offensive',              'Lethal',                  1),
  ('workforce', 'wf_less_lethal',        'Offensive',              'Less-lethal',             2),
  ('workforce', 'wf_impact',             'Offensive',              'Impact',                  3),
  ('workforce', 'wf_restraint',          'Offensive',              'Restraint',               4),
  ('workforce', 'wf_protective',         'Defensive',              'Protective',              5),
  ('workforce', 'wf_detection',          'Defensive',              'Detection',               6),
  ('workforce', 'wf_lighting',           'Defensive',              'Lighting',                7),
  ('workforce', 'wf_communications',     'Communications',         'Communications',          8),
  ('workforce', 'wf_evidence_recording', 'Evidence and Recording', 'Evidence and Recording',  9),
  ('workforce', 'wf_welfare',            'Welfare',                'Welfare',                10)
ON CONFLICT (code) WHERE code IS NOT NULL DO NOTHING;

-- The item's filing. Plain REFERENCES (RESTRICT): a subcategory with items cannot be deleted.
ALTER TABLE quote_accessories ADD COLUMN IF NOT EXISTS subcategory_id BIGINT;
ALTER TABLE quote_accessories DROP CONSTRAINT IF EXISTS quote_accessories_subcategory_id_fkey;
ALTER TABLE quote_accessories ADD CONSTRAINT quote_accessories_subcategory_id_fkey
  FOREIGN KEY (subcategory_id) REFERENCES quote_support_subcategories(id);

-- One-time backfill of today's workforce items by code — only while nothing has been filed yet,
-- so a later run never re-files an item someone deliberately set back to unfiled. Anything not
-- listed (e.g. the 'a1' test row) stays unfiled until it is filed on the admin page.
UPDATE quote_accessories a
   SET subcategory_id = s.id
  FROM quote_support_subcategories s
 WHERE s.category = 'workforce' AND a.category = 'workforce' AND a.subcategory_id IS NULL
   AND NOT EXISTS (SELECT 1 FROM quote_accessories x WHERE x.subcategory_id IS NOT NULL)
   AND s.code = CASE a.code
     WHEN 'parabellum_9mm'          THEN 'wf_lethal'
     WHEN 'tazer'                   THEN 'wf_less_lethal'
     WHEN 'pepper_spray'            THEN 'wf_less_lethal'
     WHEN 'pepper_spray_old'        THEN 'wf_less_lethal'
     WHEN 'non_lethal_paintball'    THEN 'wf_less_lethal'
     WHEN 'non_lethal_9mm_pellet'   THEN 'wf_less_lethal'
     WHEN 'baton'                   THEN 'wf_impact'
     WHEN 'extendable_baton'        THEN 'wf_impact'
     WHEN 'rubberized_baton'        THEN 'wf_impact'
     WHEN 'restraints_pouch'        THEN 'wf_restraint'
     WHEN 'bullet_proof_vest'       THEN 'wf_protective'
     WHEN 'handheld_metal_detector' THEN 'wf_detection'
     WHEN 'torch_rubberized'        THEN 'wf_lighting'
     WHEN 'torch_zartek'            THEN 'wf_lighting'
     WHEN 'officer_pocket_book'     THEN 'wf_evidence_recording'
     WHEN 'occurrence_book'         THEN 'wf_evidence_recording'
     WHEN 'bodyworn_camera'         THEN 'wf_evidence_recording'
     WHEN 'bodyworn_harness'        THEN 'wf_evidence_recording'
     WHEN 'umbrella'                THEN 'wf_welfare'
   END;

ALTER TABLE quote_support_subcategories ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text := 'quote_support_subcategories';
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

COMMIT;

-- Verify
SELECT id, code, group_name, name, display_order, active FROM quote_support_subcategories ORDER BY display_order, id;
SELECT s.group_name, s.name AS subcategory, a.name AS item
  FROM quote_accessories a LEFT JOIN quote_support_subcategories s ON s.id = a.subcategory_id
 WHERE a.category = 'workforce' ORDER BY s.display_order NULLS LAST, a.display_order, a.id;
SELECT count(*) AS unfiled_workforce_items FROM quote_accessories WHERE category = 'workforce' AND subcategory_id IS NULL;
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'quote_accessories_subcategory_id_fkey';
