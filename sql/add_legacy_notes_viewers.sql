-- v7.10.16 — Legacy Details and Notes viewers (Richard 2026-10-24: the old Details and Notes is
-- retired but kept readable for a while behind a "Secret" button, for Les only, on leads and deals).
-- settings.legacy_notes_viewers = comma-separated people ids allowed to see that button; edited on
-- Site Admin → Settings → Legacy Details and Notes. Seeds Lesley-Anne (system_users username 'les').
-- Additive, re-runnable, SQL-editor safe. Run on BOTH databases.
INSERT INTO public.settings (key, value)
SELECT 'legacy_notes_viewers', COALESCE((SELECT u.person_id::text FROM public.system_users u WHERE u.username = 'les' LIMIT 1), '')
WHERE NOT EXISTS (SELECT 1 FROM public.settings WHERE key = 'legacy_notes_viewers');
SELECT key, value FROM public.settings WHERE key = 'legacy_notes_viewers';
