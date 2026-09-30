-- Files on opportunities, contracts and projects (v7.9.82–83), Richard 2026-09-30:
--   "time to be able to attach files to opportunities" — 50 MB a file, a warning over 10 MB;
--   "functionality will extend to contracts and project too";
--   "set up standard folders for attached files in site admin" — a sub level; one list with
--   opportunity / contract / project ticks; extra per-record folders only under one main
--   non-standard folder; Proposals and Invoices "auto attach based on other routines in focus
--   with option to direct attach".
--
--   attachment_folders  STANDARD folders (deal_id and work_project_id NULL): a main folder or,
--                       via parent_id, one sub level beneath it; applies_to_* ticks say where a
--                       folder is offered (a folder holding files always shows); allows_custom
--                       marks the main folder users may add their own subfolders under;
--                       auto_source names the routine that files into it (Proposals: issued
--                       proposal versions, shown read-only, never copied; Invoices: reserved).
--                       CUSTOM folders carry deal_id (or work_project_id) and a parent_id.
--   attachments         one row per file, exactly one home (deal | work project), folder_id,
--                       soft removal (removed_at / removed_by — the stored object is kept).
--   storage bucket      'attachments', PRIVATE, 50 MB per object; the sb proxy signs a one-time
--                       upload URL and 5-minute download URLs with the service key.
--
-- Re-runnable and non-destructive. Run on PROD before or with the code. Dev ran an earlier draft
-- (attachment_categories + attachments.category_id, v7.9.82); the first block upgrades that shape
-- in place by RENAMING (table, sequence, audit triggers, column, three names) — nothing is dropped.
\set ON_ERROR_STOP on
BEGIN;

DO $$
BEGIN
  IF to_regclass('public.attachment_categories') IS NOT NULL AND to_regclass('public.attachment_folders') IS NULL THEN
    ALTER TABLE attachment_categories RENAME TO attachment_folders;
    ALTER SEQUENCE IF EXISTS attachment_categories_id_seq RENAME TO attachment_folders_id_seq;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_ins_attachment_categories') THEN
      ALTER TRIGGER audit_ins_attachment_categories ON attachment_folders RENAME TO audit_ins_attachment_folders;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_upd_attachment_categories') THEN
      ALTER TRIGGER audit_upd_attachment_categories ON attachment_folders RENAME TO audit_upd_attachment_folders;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'audit_del_attachment_categories') THEN
      ALTER TRIGGER audit_del_attachment_categories ON attachment_folders RENAME TO audit_del_attachment_folders;
    END IF;
    UPDATE attachment_folders SET name = 'Proposals'   WHERE name = 'Proposal / Tender';
    UPDATE attachment_folders SET name = 'Contracts'   WHERE name = 'Contract / SLA';
    UPDATE attachment_folders SET name = 'Site Survey' WHERE name = 'Site survey';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'attachments' AND column_name = 'category_id') THEN
    ALTER TABLE attachments RENAME COLUMN category_id TO folder_id;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS attachment_folders (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  active      BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE attachment_folders
  ADD COLUMN IF NOT EXISTS parent_id              BIGINT REFERENCES attachment_folders(id),
  ADD COLUMN IF NOT EXISTS applies_to_opportunity BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS applies_to_contract    BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS applies_to_project     BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS allows_custom          BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS auto_source            TEXT CHECK (auto_source IN ('Proposals', 'Invoices')),
  ADD COLUMN IF NOT EXISTS deal_id                BIGINT REFERENCES deals(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS work_project_id        BIGINT REFERENCES work_projects(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS created_by             BIGINT REFERENCES people(id);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'attachment_folders_one_home') THEN
    ALTER TABLE attachment_folders ADD CONSTRAINT attachment_folders_one_home
      CHECK (num_nonnulls(deal_id, work_project_id) <= 1);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'attachment_folders_custom_sub') THEN
    ALTER TABLE attachment_folders ADD CONSTRAINT attachment_folders_custom_sub
      CHECK (num_nonnulls(deal_id, work_project_id) = 0 OR parent_id IS NOT NULL);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'attachment_folders_not_self') THEN
    ALTER TABLE attachment_folders ADD CONSTRAINT attachment_folders_not_self
      CHECK (parent_id IS NULL OR parent_id <> id);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS attachment_folders_deal_idx ON attachment_folders (deal_id) WHERE deal_id IS NOT NULL;

-- The agreed standard folders. A fresh install inserts all six; an upgraded draft already holds
-- five of them by name and gains Invoices. The ticks are then set once, only while no folder has
-- ever carried an auto source (so a re-run never overwrites what an admin has since changed).
INSERT INTO attachment_folders (name, sort_order)
SELECT v.name, v.ord
  FROM (VALUES ('Proposals', 1), ('Correspondence', 2), ('Site Survey', 3),
               ('Contracts', 4), ('Invoices', 5), ('Other', 6)) AS v(name, ord)
 WHERE NOT EXISTS (SELECT 1 FROM attachment_folders f
                    WHERE f.deal_id IS NULL AND f.work_project_id IS NULL AND lower(f.name) = lower(v.name));
UPDATE attachment_folders f
   SET applies_to_opportunity = v.opp, applies_to_contract = v.con, applies_to_project = v.prj,
       allows_custom = v.cus, auto_source = v.auto, sort_order = v.ord
  FROM (VALUES ('Proposals',      1, true,  true,  false, false, 'Proposals'),
               ('Correspondence', 2, true,  true,  true,  false, NULL),
               ('Site Survey',    3, true,  true,  true,  false, NULL),
               ('Contracts',      4, true,  true,  true,  false, NULL),
               ('Invoices',       5, false, true,  true,  false, 'Invoices'),
               ('Other',          6, true,  true,  true,  true,  NULL))
       AS v(name, ord, opp, con, prj, cus, auto)
 WHERE f.name = v.name AND f.deal_id IS NULL AND f.work_project_id IS NULL
   AND NOT EXISTS (SELECT 1 FROM attachment_folders x WHERE x.auto_source IS NOT NULL);

CREATE TABLE IF NOT EXISTS attachments (
  id               BIGSERIAL PRIMARY KEY,
  deal_id          BIGINT REFERENCES deals(id) ON DELETE CASCADE,
  work_project_id  BIGINT REFERENCES work_projects(id) ON DELETE CASCADE,
  folder_id        BIGINT REFERENCES attachment_folders(id),
  file_name        TEXT NOT NULL,
  mime_type        TEXT,
  size_bytes       BIGINT NOT NULL CHECK (size_bytes >= 0),
  storage_path     TEXT NOT NULL UNIQUE,
  note             TEXT,
  uploaded_by      BIGINT REFERENCES people(id),
  uploaded_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  removed_at       TIMESTAMPTZ,
  removed_by       BIGINT REFERENCES people(id),
  CONSTRAINT attachments_one_home CHECK (num_nonnulls(deal_id, work_project_id) = 1)
);
CREATE INDEX IF NOT EXISTS attachments_deal_idx         ON attachments (deal_id)         WHERE deal_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS attachments_work_project_idx ON attachments (work_project_id) WHERE work_project_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS attachments_folder_idx       ON attachments (folder_id);

ALTER TABLE attachment_folders ENABLE ROW LEVEL SECURITY;
ALTER TABLE attachments        ENABLE ROW LEVEL SECURITY;
GRANT ALL ON attachment_folders, attachments TO service_role;
GRANT USAGE, SELECT ON SEQUENCE attachment_folders_id_seq, attachments_id_seq TO service_role;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['attachment_folders', 'attachments'] LOOP
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

-- The private bucket. 52428800 bytes = 50 MB, enforced by storage on the upload itself.
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('attachments', 'attachments', false, 52428800)
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = EXCLUDED.file_size_limit;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verify
SELECT id, name, parent_id, applies_to_opportunity AS opp, applies_to_contract AS con,
       applies_to_project AS prj, allows_custom, auto_source, sort_order, active
  FROM attachment_folders WHERE deal_id IS NULL AND work_project_id IS NULL ORDER BY sort_order, id;
SELECT public, file_size_limit FROM storage.buckets WHERE id = 'attachments';
