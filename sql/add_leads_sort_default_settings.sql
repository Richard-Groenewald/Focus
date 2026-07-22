-- Sort Defaults (v7.8.18) — admin-configurable default sort for the Leads
-- Register (Admin → Settings → Sort Defaults). Run on BOTH Dev and Prod before
-- (or with) the v7.8.18 code release; the Settings page PATCHes these keys, so
-- the rows must exist.
--
--   leads_default_sort_key  '' (default) = server order, created desc — the
--                           classic newest-first. Otherwise a leads-table
--                           column key: target|source|region|branch|qual|
--                           owner|nxt|touch
--   leads_default_sort_dir  'asc' (default) | 'desc' — ignored when key is ''

insert into settings (key, value) values
  ('leads_default_sort_key', ''),
  ('leads_default_sort_dir', 'asc')
on conflict (key) do nothing;

-- Verify:
--   select key, value from settings where key like 'leads_default_sort%';
