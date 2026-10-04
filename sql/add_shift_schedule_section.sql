-- v7.9.92 - Shift schedule section in the proposal.
-- Adds the generated section 'shift_schedule' straight after 'scope_posts' in every template
-- that lacks it (later sections move down one place). Additive and re-runnable; run on both
-- databases before or with the code (without it the Shift Schedule tab still works, the proposal
-- simply has no such section until a template carries it).
BEGIN;

UPDATE proposal_template_sections s
SET display_order = s.display_order + 1
FROM proposal_template_sections sc
WHERE sc.template_id = s.template_id
  AND sc.section_key = 'scope_posts'
  AND s.display_order > sc.display_order
  AND NOT EXISTS (SELECT 1 FROM proposal_template_sections x
                  WHERE x.template_id = s.template_id AND x.section_key = 'shift_schedule');

INSERT INTO proposal_template_sections (template_id, section_key, title, display_order, kind, body, mandatory, page_break_before)
SELECT sc.template_id, 'shift_schedule', 'Shift schedule', sc.display_order + 1, 'generated', NULL, false, true
FROM proposal_template_sections sc
WHERE sc.section_key = 'scope_posts'
ON CONFLICT (template_id, section_key) DO NOTHING;

COMMIT;
