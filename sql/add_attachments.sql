-- Files on opportunities (v7.9.82), Richard 2026-09-30: "time to be able to attach files to
-- opportunities" — 50 MB a file, a warning over 10 MB; opportunities first, "functionality will
-- extend to contracts and project too". A contract is the same deals row after securing, so it
-- needs nothing more; work_project_id is here now so projects join without a migration.
--
--   attachment_categories  admin lookup (Admin → Attachment Categories), five seeded
--   attachments            one row per file: exactly one home (deal | work project), metadata,
--                          who/when, soft removal (removed_at / removed_by — the object stays)
--   storage bucket         'attachments', PRIVATE, 50 MB per object. The sb proxy signs a
--                          one-time upload URL and 5-minute download URLs with the service key;
--                          no storage policies are granted to anon / authenticated.
--
-- Additive and re-runnable. Run on DEV first, then PROD, before or with the code (the Files
-- tab says "not set up on this database yet" while the table is absent).
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS attachment_categories (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  active      BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO attachment_categories (name, sort_order)
SELECT v.name, v.sort_order
  FROM (VALUES ('Proposal / Tender', 1), ('Contract / SLA', 2), ('Site survey', 3),
               ('Correspondence', 4), ('Other', 5)) AS v(name, sort_order)
 WHERE NOT EXISTS (SELECT 1 FROM attachment_categories c WHERE lower(c.name) = lower(v.name));

CREATE TABLE IF NOT EXISTS attachments (
  id               BIGSERIAL PRIMARY KEY,
  deal_id          BIGINT REFERENCES deals(id) ON DELETE CASCADE,
  work_project_id  BIGINT REFERENCES work_projects(id) ON DELETE CASCADE,
  category_id      BIGINT REFERENCES attachment_categories(id),
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

ALTER TABLE attachment_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE attachments           ENABLE ROW LEVEL SECURITY;
GRANT ALL ON attachment_categories, attachments TO service_role;
GRANT USAGE, SELECT ON SEQUENCE attachment_categories_id_seq, attachments_id_seq TO service_role;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['attachment_categories', 'attachments'] LOOP
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
SELECT (SELECT count(*) FROM attachment_categories) AS categories,
       (SELECT count(*) FROM attachments)           AS attachments,
       (SELECT public FROM storage.buckets WHERE id = 'attachments') AS bucket_public,
       (SELECT file_size_limit FROM storage.buckets WHERE id = 'attachments') AS bucket_limit;
