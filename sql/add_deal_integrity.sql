-- v7.10.53 — Contract data integrity confirmed PER DEAL (Richard 2026-11-19: "confirm integrity needs
-- to happen on a deal basis"; supersedes the v7.10.52 settings key `contracts_integrity`, which nothing
-- reads any more).
--
-- A secured deal carries its own confirmation: who confirmed it, when, and a note. "Changed since"
-- is judged against deals.updated_at, which until now nothing maintained — so this file also adds
-- the trigger that stamps it on every content change, leaving the integrity columns (and updated_at
-- itself) out of the comparison so a confirmation never marks itself stale.
--
-- Additive, re-runnable, SQL-editor safe. No audit changes (deals already carries statement-level audit).

ALTER TABLE public.deals
  ADD COLUMN IF NOT EXISTS integrity_confirmed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS integrity_confirmed_by BIGINT REFERENCES public.people(id),
  ADD COLUMN IF NOT EXISTS integrity_note TEXT;
COMMENT ON COLUMN public.deals.integrity_confirmed_at IS 'v7.10.53: when the contract data on this deal was checked and confirmed; stale once updated_at is later';

CREATE OR REPLACE FUNCTION public.deals_set_updated_at() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF (to_jsonb(NEW) - 'updated_at' - 'integrity_confirmed_at' - 'integrity_confirmed_by' - 'integrity_note')
     IS DISTINCT FROM
     (to_jsonb(OLD) - 'updated_at' - 'integrity_confirmed_at' - 'integrity_confirmed_by' - 'integrity_note') THEN
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_deals_updated_at' AND tgrelid = 'public.deals'::regclass) THEN
    CREATE TRIGGER trg_deals_updated_at BEFORE UPDATE ON public.deals
      FOR EACH ROW EXECUTE FUNCTION public.deals_set_updated_at();
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
