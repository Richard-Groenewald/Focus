-- v7.10.51 — Delivery owner and delegation on a secured deal (Richard 2026-11-19: "when an
-- opportunity becomes a contract, the principle owner should be the operations director owning the
-- delivery responsibility. he/she might delegate some or all responsibilities" → "one per family, no.
-- build it").
--
-- deals.owner_id stays the SALES owner (pipeline, targets, reports and attribution key on it). A
-- secured deal gains a DELIVERY owner, defaulted at securing from the Site Admin setting for the
-- deal's service family (settings.delivery_owner_default_<service_major_id>), and the existing
-- deal_collaborators row carries a delegation: the areas delegated and an optional end date.
--
-- Additive, re-runnable, SQL-editor safe. No audit changes (deals and deal_collaborators already
-- carry the statement-level audit).

ALTER TABLE public.deals
  ADD COLUMN IF NOT EXISTS delivery_owner_id BIGINT REFERENCES public.people(id),
  ADD COLUMN IF NOT EXISTS delivery_handover_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS deals_delivery_owner_idx ON public.deals(delivery_owner_id) WHERE delivery_owner_id IS NOT NULL;
COMMENT ON COLUMN public.deals.delivery_owner_id IS 'v7.10.51: who owns delivery once the deal is secured (the sales owner stays on owner_id)';

ALTER TABLE public.deal_collaborators
  ADD COLUMN IF NOT EXISTS responsibilities TEXT[],
  ADD COLUMN IF NOT EXISTS delegated_until DATE,
  ADD COLUMN IF NOT EXISTS delegated_by BIGINT REFERENCES public.people(id),
  ADD COLUMN IF NOT EXISTS delegated_at TIMESTAMPTZ;
COMMENT ON COLUMN public.deal_collaborators.responsibilities IS 'v7.10.51: areas of a secured deal delegated to this person — any of terms, actuals, billing, plan, engagements, or all; NULL = plain collaborator';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'deal_collaborators_responsibilities_chk') THEN
    ALTER TABLE public.deal_collaborators ADD CONSTRAINT deal_collaborators_responsibilities_chk
      CHECK (responsibilities IS NULL OR responsibilities <@ ARRAY['terms','actuals','billing','plan','engagements','all']::text[]);
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
