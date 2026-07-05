-- Capture-always, gate-progression (2026-07-05).
-- Filled-in lead data (qualification dots, red flags, comments…) must persist the
-- moment it exists — even on a brand-new lead where Source/Description haven't been
-- typed yet. Those two columns were NOT NULL, which made the row impossible to
-- create early and silently discarded Qualification-tab work on unsaved leads.
-- Progression is unaffected: the app-side status engine (computeLeadStatus) keeps
-- a lead at 'New' until source, description, site/org, contact and next action are
-- all present. Idempotent; run on BOTH Dev and Prod.

alter table leads alter column source_id   drop not null;
alter table leads alter column description drop not null;
