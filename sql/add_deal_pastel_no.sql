-- v7.10.55 — Every contract carries its own Pastel account number (Richard 2026-11-19: "a key
-- requirement of a secured deal is that it has a pastel no" → "every contract must have a number").
-- Until now the number lived only on the organisation (organisations.account_no); a client with
-- several contracts, or a contract billed under another account, had no place to say so.
-- deals.pastel_account_no is defaulted from the client at securing and may be changed under the
-- contract terms. Backfill: every secured deal takes its client's number where it has none.
-- Additive, re-runnable, SQL-editor safe.
ALTER TABLE public.deals ADD COLUMN IF NOT EXISTS pastel_account_no TEXT;
COMMENT ON COLUMN public.deals.pastel_account_no IS 'v7.10.55: the Pastel customer account this contract is invoiced under (defaulted from organisations.account_no at securing)';
UPDATE public.deals d SET pastel_account_no = nullif(trim(o.account_no), '')
  FROM public.organisations o, public.stages s
 WHERE o.id = d.org_id AND s.id = d.stage_id
   AND (lower(s.name) = 'secured' OR s.category_id IN (3, 4))
   AND (d.pastel_account_no IS NULL OR trim(d.pastel_account_no) = '')
   AND nullif(trim(o.account_no), '') IS NOT NULL;
NOTIFY pgrst, 'reload schema';
