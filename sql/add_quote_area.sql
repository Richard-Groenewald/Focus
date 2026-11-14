-- v7.10.40 — THE QUOTE'S AREA (Richard, 2026-11-14: "area must always be chosen. Default or
-- Urban, have on basic info tab").
--
-- Until now a post's PSIRA area came from a per-post override else the quote's site; a sandbox
-- quote (no site) could not be priced until every post was given an area by hand. The quote now
-- carries its own area (quote_quotes.area_id → quote_areas), shown and chosen on the Basic info
-- tab, and a post's area is its own override else the quote's. The default for an existing quote
-- is its site's area where the site has one, else Area 1 (Major Urban); a new quote takes the same
-- default the first time it is opened (openQuote), so the area is always chosen.
--
-- Additive, re-runnable, SQL-editor safe. Run on BOTH databases, before or after the code: a
-- database without the column keeps the old site rule and the Basic info select is disabled
-- naming this file.
begin;

alter table quote_quotes add column if not exists area_id bigint references quote_areas(id);
comment on column quote_quotes.area_id is 'The PSIRA area the quote''s posts are priced in unless a post overrides it (quote_areas). Always set: the site''s area else Area 1 (Major Urban).';

-- Backfill once: the site's area where there is one, else Area 1.
update quote_quotes q
   set area_id = coalesce((select s.area_id from quote_sites s where s.id = q.site_id),
                          (select a.id from quote_areas a where a.code = 'area_1'))
 where q.area_id is null;

create index if not exists idx_quote_quotes_area on quote_quotes (area_id);

notify pgrst, 'reload schema';
commit;

select count(*) filter (where area_id is null) as quotes_without_area, count(*) as quotes
from quote_quotes;
