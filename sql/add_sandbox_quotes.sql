-- ============================================================================
-- Proposal Sandbox — freestanding quotes not tied to a deal (v7.7.90)
-- ============================================================================
-- Sandbox quotes reuse quote_quotes/quote_posts (full builder reuse) but have
-- no deal binding. Rules:
--   • deal_id becomes nullable; a CHECK ties NULL deal_id to is_sandbox=true
--     (and vice versa), so live quotes are untouched.
--   • sandbox_client_name is a free-text label — NOT an organisations FK.
--   • Cap: max 5 sandbox quotes per owner, enforced by trigger (UI also guards).
-- Run on Dev first, then Prod with the release.
-- ============================================================================

ALTER TABLE quote_quotes ALTER COLUMN deal_id DROP NOT NULL;

ALTER TABLE quote_quotes ADD COLUMN is_sandbox BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE quote_quotes ADD COLUMN sandbox_client_name TEXT;

ALTER TABLE quote_quotes ADD CONSTRAINT chk_quote_sandbox_deal
  CHECK ((is_sandbox AND deal_id IS NULL) OR (NOT is_sandbox AND deal_id IS NOT NULL));

CREATE INDEX idx_quote_quotes_sandbox_owner ON quote_quotes (owner_id) WHERE is_sandbox;

-- Cap: 5 sandbox quotes per owner. BEFORE INSERT only — editing an existing
-- sandbox quote never trips it.
CREATE OR REPLACE FUNCTION check_sandbox_quote_cap()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.is_sandbox THEN
    IF NEW.owner_id IS NULL THEN
      RAISE EXCEPTION 'Sandbox quotes must have an owner.';
    END IF;
    IF (SELECT count(*) FROM quote_quotes
        WHERE is_sandbox AND owner_id = NEW.owner_id) >= 5 THEN
      RAISE EXCEPTION 'Sandbox limit reached (5). Delete an existing sandbox quote first.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sandbox_quote_cap
  BEFORE INSERT ON quote_quotes
  FOR EACH ROW EXECUTE FUNCTION check_sandbox_quote_cap();
