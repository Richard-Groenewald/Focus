-- v7.10.54 — Pre-sales collaborators and the delivery team are two lists (Richard 2026-11-19:
-- "collaborators are used in the pre sales world, referring most often to non xone people helping
-- secure a contract"). deal_collaborators.team says which list a row belongs to: 'presales' (the
-- people who helped secure the deal — history once it is secured) or 'delivery' (the delivery
-- owner's team on a secured deal, who may carry a delegation). Rows that already carry a
-- delegation are delivery rows.
-- Additive, re-runnable, SQL-editor safe.
ALTER TABLE public.deal_collaborators ADD COLUMN IF NOT EXISTS team TEXT NOT NULL DEFAULT 'presales';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'deal_collaborators_team_chk') THEN
    ALTER TABLE public.deal_collaborators ADD CONSTRAINT deal_collaborators_team_chk CHECK (team IN ('presales', 'delivery'));
  END IF;
END $$;
UPDATE public.deal_collaborators SET team = 'delivery' WHERE responsibilities IS NOT NULL AND team = 'presales';
NOTIFY pgrst, 'reload schema';
