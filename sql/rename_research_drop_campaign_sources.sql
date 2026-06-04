-- Lead source tidy-up:
--   * Rename "Research" → "Research Campaign" (it drives the Research Campaign
--     picker on the lead form).
--   * Drop the redundant "Campaign" source (duplicate of "Sales Campaign").
--     Deleted outright (verified no leads referenced it). If any did, switch the
--     DELETE for `UPDATE ... SET active = false` to keep their source_id valid.

UPDATE public.lead_sources SET name = 'Research Campaign' WHERE name = 'Research';
DELETE FROM public.lead_sources
  WHERE name = 'Campaign'
    AND NOT EXISTS (SELECT 1 FROM public.leads WHERE leads.source_id = lead_sources.id);
