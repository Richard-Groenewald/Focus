-- Idempotent prod seed: lookup rows + config the structural migrations created
-- columns/tables for, but whose INSERTs never ran on prod (kevrfdjqyuhmgziqxuvs).
-- Source migrations: lead_lifecycle_A_foundations.sql, add_promotion_requests.sql,
--   add_promotion_eligibility_threshold.sql. Settings use PRODUCTION-intended
--   defaults (not the test project's lowered test-shortcut values).
-- Safe to re-run: every statement is WHERE NOT EXISTS / ON CONFLICT DO NOTHING.
BEGIN;

-- 1. qualification_dimensions (F/T/A/C) — drives the qualification dots
INSERT INTO public.qualification_dimensions (key, label, description, sort_order)
SELECT v.key, v.label, v.descr, v.so FROM (VALUES
    ('fit',           'Fit',      'Are they in your ideal client profile? (sector, size, region you serve)',          10),
    ('trigger_score', 'Trigger',  'Is there a reason now? (new site, incident, renewal coming up, change of FM)',     20),
    ('access',        'Access',   'Can you actually get in front of a decision-maker?',                               30),
    ('capacity',      'Capacity', 'Can you serve them if you win? (region coverage, manpower vs tech)',               40)
) AS v(key, label, descr, so)
WHERE NOT EXISTS (SELECT 1 FROM public.qualification_dimensions q WHERE q.key = v.key);

-- 2. decline_reasons — decline picker
INSERT INTO public.decline_reasons (name, sort_order)
SELECT v.name, v.so FROM (VALUES
    ('No budget',                 10),
    ('No current need',           20),
    ('Using a competitor',        30),
    ('Timing not right',          40),
    ('Unresponsive',              50),
    ('Out of our coverage area',  60),
    ('Other',                     90)
) AS v(name, so)
WHERE NOT EXISTS (SELECT 1 FROM public.decline_reasons d WHERE d.name = v.name);

-- 3. promotion_reject_reasons — manager reject picker
INSERT INTO public.promotion_reject_reasons (name, description, sort_order) VALUES
  ('Financials need rework',     'Revenue stream / margin / dates are off.',         1),
  ('Wrong organisation match',   'Linked or created the wrong client organisation.', 2),
  ('Not genuinely qualified',    'Does not yet warrant an opportunity.',             3),
  ('Timing — revisit later',     'Real but not now; park and re-request.',           4),
  ('Insufficient justification', 'Special request motivation is too thin.',          5)
ON CONFLICT DO NOTHING;

-- 4. settings — production-intended values
INSERT INTO public.settings (key, value) VALUES
  ('promotion_min_green',          '4'),
  ('promotion_green_counts_weak',  'false'),
  ('new_lead_waiting_minutes',     '10'),
  ('lead_due_soon_days',           '3')
ON CONFLICT (key) DO NOTHING;

COMMIT;
