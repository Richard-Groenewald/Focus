-- v7.9.93 - Per-shift price basis on a quote.
-- quote_quotes.price_basis picks what the proposal's pricing section prints:
--   monthly   - the monthly table per post (today's output, the default)
--   per_shift - a rate per officer per shift for every post, with the same totals
--   both      - the monthly table followed by the rates behind it
-- Nothing else is stored: a shift rate is always the post's monthly price spread over its shifts.
-- Additive and re-runnable; may run before or after the code (an absent column reads as monthly
-- and the choice is switched off; the Pricing tab still shows both views).
BEGIN;

ALTER TABLE quote_quotes ADD COLUMN IF NOT EXISTS price_basis TEXT NOT NULL DEFAULT 'monthly';

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'quote_quotes_price_basis_check') THEN
    ALTER TABLE quote_quotes ADD CONSTRAINT quote_quotes_price_basis_check
      CHECK (price_basis IN ('monthly', 'per_shift', 'both'));
  END IF;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
