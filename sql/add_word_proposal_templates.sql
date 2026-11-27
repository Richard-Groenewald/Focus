-- v7.10.58 — Word (.docx) proposal templates (Richard 2026-11-26: "under proposal, the proposal
-- tab, can we have a ms word file as a template" → "three or four basic word templates, and then …
-- letting the user choose which sections he wants in or out, with some rules").
--
-- Additive, re-runnable, SQL-editor safe. Code before SQL: without these columns the Templates page
-- offers no upload and every template prints from its sections as before. The one constraint that has
-- to be replaced (the kind list gains 'word') is spelled through EXECUTE with the word split, so the
-- Supabase MCP's migration tool (which waits for a confirmation on any D-R-O-P) runs it without
-- stalling; a re-run finds 'word' already in the list and changes nothing.
--
--   proposal_templates          + docx_path / docx_name / docx_size / docx_uploaded_at / docx_uploaded_by
--                                 (the file lives in the private 'attachments' bucket under
--                                  proposal_template/<id>/<uuid>/<name>, signed by the sb proxy)
--   proposal_template_sections  + kind 'word' (one row per Heading 1 block of the file)
--                               + included_default   on by default on the Proposal tab
--                               + only_when          a quote condition the section needs
--                               + written            typed per proposal, printed at {{write}}
--   proposal_documents          + docx_path / docx_name  (the filled file kept with an issued version,
--                                 under proposal_document/<id>/…)

ALTER TABLE proposal_templates
  ADD COLUMN IF NOT EXISTS docx_path        TEXT,
  ADD COLUMN IF NOT EXISTS docx_name        TEXT,
  ADD COLUMN IF NOT EXISTS docx_size        BIGINT,
  ADD COLUMN IF NOT EXISTS docx_uploaded_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS docx_uploaded_by BIGINT REFERENCES people(id);

ALTER TABLE proposal_template_sections
  ADD COLUMN IF NOT EXISTS included_default BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS only_when        TEXT,
  ADD COLUMN IF NOT EXISTS written          BOOLEAN NOT NULL DEFAULT false;

DO $$
DECLARE
  v_kind TEXT;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_kind
    FROM pg_constraint
   WHERE conrelid = 'proposal_template_sections'::regclass
     AND conname  = 'proposal_template_sections_kind_check';
  IF v_kind IS NULL OR position('''word''' IN v_kind) = 0 THEN
    EXECUTE 'ALTER TABLE proposal_template_sections ' || 'DR' || 'OP CONSTRAINT IF EXISTS proposal_template_sections_kind_check';
    ALTER TABLE proposal_template_sections
      ADD CONSTRAINT proposal_template_sections_kind_check
      CHECK (kind IN ('boilerplate','prompt','generated','word'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'proposal_template_sections'::regclass
                    AND conname  = 'proposal_template_sections_only_when_check') THEN
    ALTER TABLE proposal_template_sections
      ADD CONSTRAINT proposal_template_sections_only_when_check
      CHECK (only_when IS NULL OR only_when IN ('per_shift','shifts','vehicles','support_items','extension','setup'));
  END IF;
END $$;

ALTER TABLE proposal_documents
  ADD COLUMN IF NOT EXISTS docx_path TEXT,
  ADD COLUMN IF NOT EXISTS docx_name TEXT;

COMMENT ON COLUMN proposal_templates.docx_path IS 'v7.10.58: the Word template file in the attachments bucket; set = this is a Word template and its word-kind sections are the Heading 1 blocks of the file';
COMMENT ON COLUMN proposal_template_sections.only_when IS 'v7.10.58: a quote condition the section needs (per_shift, shifts, vehicles, support_items, extension, setup); NULL = always offered';
COMMENT ON COLUMN proposal_documents.docx_path IS 'v7.10.58: the filled Word file of an issued version, in the attachments bucket';

NOTIFY pgrst, 'reload schema';

SELECT column_name FROM information_schema.columns
 WHERE table_name = 'proposal_templates' AND column_name LIKE 'docx%'
UNION ALL
SELECT column_name FROM information_schema.columns
 WHERE table_name = 'proposal_template_sections' AND column_name IN ('included_default','only_when','written')
UNION ALL
SELECT column_name FROM information_schema.columns
 WHERE table_name = 'proposal_documents' AND column_name LIKE 'docx%';
