-- Probability score (v7.9.94), Richard 2026-10-03: "add the following to the probability chooser in
-- focus under opportunities" - his Sales Probability Calculator (weighted qualifying questions,
-- the weighted average capped at a gate per stage).
--
--   probability_criteria           one row per question: name, question, weight (its share is
--                                  weight / the total of the active weights), order, active.
--   probability_criterion_answers  the answers offered for a question, each with a score 0-100.
--   deal_probability_answers       the answer chosen on a deal: one row per deal and question.
--                                  A deal's score = round(sum(score x weight) / sum(weight)) over the
--                                  active questions, an unanswered one counting 0, held inside the
--                                  stage's minimum and maximum probability.
--
-- The gate per stage is NOT a new column: it is stages.max_probability (one home per rule). This
-- script sets the gates Richard chose - Prospect 20, Proposal 60, Negotiation 80 - on stages still at
-- the old maximum of 100, and lowers a stage's probability on entry to its gate where it was higher
-- (Prospect 40 -> 20). Existing deals are not touched: a deal above its stage's gate is pulled down
-- when its probability is next edited.
--
-- A question or answer that a deal has used cannot be deleted (the foreign keys refuse it); the admin
-- page switches it off instead. Additive and re-runnable. Run on DEV and PROD before or with the
-- code; without it the Score button stays hidden and the probability box works as before.
-- The stage update is attributed to Claude Code acting for Richard.

\set ON_ERROR_STOP on
BEGIN;

SELECT set_config('request.headers', json_build_object(
  'x-actor-id', (SELECT id::text FROM people WHERE first_name = 'Claude' AND last_name = 'Code' ORDER BY id LIMIT 1),
  'x-real-actor-id', '1')::text, true);

-- 1. Tables ------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS probability_criteria (
  id          BIGSERIAL    PRIMARY KEY,
  code        TEXT,
  name        TEXT         NOT NULL,
  question    TEXT,
  weight      NUMERIC(6,2) NOT NULL DEFAULT 0 CHECK (weight >= 0),
  sort_order  INTEGER      NOT NULL DEFAULT 0,
  active      BOOLEAN      NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
  created_by  BIGINT       REFERENCES people(id)
);
CREATE UNIQUE INDEX IF NOT EXISTS probability_criteria_code_key
  ON probability_criteria (code) WHERE code IS NOT NULL;

CREATE TABLE IF NOT EXISTS probability_criterion_answers (
  id            BIGSERIAL   PRIMARY KEY,
  criterion_id  BIGINT      NOT NULL REFERENCES probability_criteria(id) ON DELETE CASCADE,
  code          TEXT,
  label         TEXT        NOT NULL,
  score         INTEGER     NOT NULL CHECK (score >= 0 AND score <= 100),
  sort_order    INTEGER     NOT NULL DEFAULT 0,
  active        BOOLEAN     NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS probability_criterion_answers_code_key
  ON probability_criterion_answers (code) WHERE code IS NOT NULL;
CREATE INDEX IF NOT EXISTS probability_criterion_answers_criterion_idx
  ON probability_criterion_answers (criterion_id);

-- criterion_id and answer_id are plain references (RESTRICT): history on a deal is never deleted
-- from under it. The deal itself takes its answers with it.
CREATE TABLE IF NOT EXISTS deal_probability_answers (
  id            BIGSERIAL   PRIMARY KEY,
  deal_id       BIGINT      NOT NULL REFERENCES deals(id) ON DELETE CASCADE,
  criterion_id  BIGINT      NOT NULL REFERENCES probability_criteria(id),
  answer_id     BIGINT      NOT NULL REFERENCES probability_criterion_answers(id),
  answered_by   BIGINT      REFERENCES people(id),
  answered_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (deal_id, criterion_id)
);
CREATE INDEX IF NOT EXISTS deal_probability_answers_answer_idx
  ON deal_probability_answers (answer_id);
CREATE INDEX IF NOT EXISTS deal_probability_answers_criterion_idx
  ON deal_probability_answers (criterion_id);

-- 2. Seed: the six questions of the calculator, keyed on a stable code so a re-run never
--    resurrects a row an admin renamed, re-weighted or removed -----------------------------------
INSERT INTO probability_criteria (code, name, question, weight, sort_order) VALUES
  ('budget_approved',   'Budget Approved',   'Is the budget already approved?',                                  15, 1),
  ('technical_fit',     'Technical Fit',     'How well does your solution fit their technical requirements?',    15, 2),
  ('champion_quality',  'Champion Quality',  'How strong is your internal champion?',                            20, 3),
  ('decision_timeline', 'Decision Timeline', 'When will they decide?',                                           15, 4),
  ('incumbent_threat',  'Incumbent Threat',  'Are you displacing an incumbent?',                                 15, 5),
  ('problem_urgency',   'Problem Urgency',   'How urgent is their problem?',                                     20, 6)
ON CONFLICT (code) WHERE code IS NOT NULL DO NOTHING;

INSERT INTO probability_criterion_answers (criterion_id, code, label, score, sort_order)
SELECT c.id, v.code, v.label, v.score, v.sort_order
FROM (VALUES
  ('budget_approved',   'budget_no',          'No',                         0, 1),
  ('budget_approved',   'budget_partial',     'Partially',                 50, 2),
  ('budget_approved',   'budget_yes',         'Yes',                      100, 3),
  ('technical_fit',     'fit_poor',           'Poor fit',                   0, 1),
  ('technical_fit',     'fit_adequate',       'Adequate',                  50, 2),
  ('technical_fit',     'fit_excellent',      'Excellent fit',            100, 3),
  ('champion_quality',  'champion_none',      'None / weak',                0, 1),
  ('champion_quality',  'champion_moderate',  'Moderate influence',        50, 2),
  ('champion_quality',  'champion_strong',    'Strong executive sponsor', 100, 3),
  ('decision_timeline', 'timeline_uncertain', 'Uncertain / distant',        0, 1),
  ('decision_timeline', 'timeline_months',    '3 to 6 months',             50, 2),
  ('decision_timeline', 'timeline_weeks',     'Within 4 weeks',           100, 3),
  ('incumbent_threat',  'incumbent_green',    'Greenfield (new)',         100, 1),
  ('incumbent_threat',  'incumbent_upgrade',  'Upgrade existing',          50, 2),
  ('incumbent_threat',  'incumbent_displace', 'Displacing competitor',     25, 3),
  ('problem_urgency',   'urgency_nice',       'Nice to have',               0, 1),
  ('problem_urgency',   'urgency_planned',    'Planned priority',          50, 2),
  ('problem_urgency',   'urgency_critical',   'Critical / exposed',       100, 3)
) AS v(criterion_code, code, label, score, sort_order)
JOIN probability_criteria c ON c.code = v.criterion_code
ON CONFLICT (code) WHERE code IS NOT NULL DO NOTHING;

-- 3. Row level security, grants, audit --------------------------------------------------------
ALTER TABLE probability_criteria          ENABLE ROW LEVEL SECURITY;
ALTER TABLE probability_criterion_answers ENABLE ROW LEVEL SECURITY;
ALTER TABLE deal_probability_answers      ENABLE ROW LEVEL SECURITY;

GRANT ALL ON probability_criteria, probability_criterion_answers, deal_probability_answers TO service_role;
GRANT USAGE, SELECT ON SEQUENCE probability_criteria_id_seq, probability_criterion_answers_id_seq,
  deal_probability_answers_id_seq TO service_role;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['probability_criteria', 'probability_criterion_answers', 'deal_probability_answers'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_ins_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_ins_%1$I AFTER INSERT ON %1$I REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_upd_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_upd_%1$I AFTER UPDATE ON %1$I REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = t::regclass AND tgname = 'audit_del_' || t) THEN
      EXECUTE format('CREATE TRIGGER audit_del_%1$I AFTER DELETE ON %1$I REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION audit_stmt()', t);
    END IF;
  END LOOP;
END $$;

-- 4. The gates: each open stage's maximum probability. Only a stage still at the old maximum of
--    100 is changed, so a re-run never overwrites a value set on the Stages page afterwards -------
UPDATE stages s
SET max_probability = v.gate,
    probability     = LEAST(COALESCE(s.probability, v.gate), v.gate)
FROM (VALUES ('Prospect', 20), ('Proposal', 60), ('Negotiation', 80)) AS v(name, gate),
     stage_categories c
WHERE c.id = s.category_id AND c.name = 'Opportunity-Open'
  AND s.name = v.name AND s.max_probability = 100;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verify
SELECT c.sort_order, c.name, c.weight, count(a.id) AS answers
FROM probability_criteria c LEFT JOIN probability_criterion_answers a ON a.criterion_id = c.id
GROUP BY c.id ORDER BY c.sort_order;
SELECT s.name, s.probability AS on_entry, s.min_probability, s.max_probability
FROM stages s JOIN stage_categories c ON c.id = s.category_id
WHERE c.name = 'Opportunity-Open' ORDER BY s.sort_order;
