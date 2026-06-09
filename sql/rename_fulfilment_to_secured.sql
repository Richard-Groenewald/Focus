-- Rename revenue_stream_months.fulfilment_* → secured_* to match the app code.
-- The opportunity stream carries the projection (opportunity_revenue); the
-- frozen post-securing snapshot was historically 'fulfilment_*' and is now
-- 'secured_*'. Applied to PROD by hand on 2026-06-09 (live pipeline-load fix);
-- this file records the change and backfills the TEST DB, which still had the
-- old names.
-- Idempotent: each column is only renamed if the old name still exists, so it's
-- a no-op on PROD (already renamed) and does the rename on TEST.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'revenue_stream_months'
               AND column_name = 'fulfilment_revenue') THEN
    ALTER TABLE public.revenue_stream_months RENAME COLUMN fulfilment_revenue TO secured_revenue;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'revenue_stream_months'
               AND column_name = 'fulfilment_margin') THEN
    ALTER TABLE public.revenue_stream_months RENAME COLUMN fulfilment_margin TO secured_margin;
  END IF;
END $$;
