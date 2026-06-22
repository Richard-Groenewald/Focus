-- Seed the admin-editable "generic words to ignore in name matching" setting.
-- These common org words (Estate, Group, Company…) are dropped during the
-- duplicate-organisation name check so typing any "… Estate" no longer matches
-- every estate. Editable in Admin → Settings → Duplicate Detection.
-- Idempotent.
INSERT INTO public.settings (key, value)
SELECT 'org_match_stopwords',
       'estate, estates, campus, organisation, organization, company, group, holdings, trust, the, properties, property, investments, mining, security, services, association, hoa, homeowners, body, corporate'
WHERE NOT EXISTS (SELECT 1 FROM public.settings WHERE key = 'org_match_stopwords');
