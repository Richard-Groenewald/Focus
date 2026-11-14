-- v7.10.41 — OFFICERS OVERRIDE PER POST (Richard, 2026-11-14, ruling on the manpower engine's first
-- open design call: officers per post stay DERIVED from the shift grid; where a real case needs a
-- different number, the post carries an override WITH A REASON, like the workforce adjustment,
-- rather than going back to the old tool's typed box).
--
-- NULL = the derived number (pbOfficersForPost = ceil of what the grid needs). A figure sets the
-- officers the post is priced and quoted at; the reason is required with it and shown on the
-- post's Costing section and in the engine's warnings.
--
-- Additive, re-runnable, SQL-editor safe. Run on BOTH databases, before or after the code: a
-- database without the columns prices every post on the derived number and the Officers box on
-- the Costing section is disabled naming this file.
begin;

alter table quote_posts add column if not exists officers_override        integer check (officers_override >= 1);
alter table quote_posts add column if not exists officers_override_reason text;

comment on column quote_posts.officers_override        is 'Officers the post is priced at, set by hand (NULL = derived from the shift grid).';
comment on column quote_posts.officers_override_reason is 'Why the officers were set by hand; required with officers_override.';

notify pgrst, 'reload schema';
commit;

select column_name, data_type
from information_schema.columns
where table_name = 'quote_posts' and column_name in ('officers_override', 'officers_override_reason')
order by column_name;
