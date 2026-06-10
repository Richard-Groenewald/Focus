# Focus CRM — Extensions & Variations (Deal Lineage) — Design Handoff

Status: **design agreed, not yet built.** This brief carries the full intent from the planning chat so a Claude Code session can implement against the real schema. Do NOT assume column names — verify against the live DB first (queries at the bottom).

> **VERIFIED 2026-06-10** (prod + dev, schemas identical). Corrections to this brief:
> - Contracts live at **stage 5 (Secured, category Opportunity-Closed)**, not stage 7. All 73 contracts are at stage 5; stage 7 (In Progress) has zero deals. Backfill + secure-contract handler must key off **stage 5**.
> - There is **no "Qualified" stage**. Stages: 2 Prospect, 3 Proposal, 4 Negotiation, 5 Secured, 6 Lost, 7 In Progress, 8 Complete (no id 1). Extensions/variations need a chosen entry stage — Prospect (2) is the earliest open stage. **Open decision.**
> - `revenue_stream_months` value columns are `opportunity_revenue/_margin`, `secured_revenue/_margin` (the fulfilment→secured rename reached both DBs), `actual_revenue/_margin` + `is_actual_revenue/_margin` booleans.
> - `revenue_streams.stream_type` values in use: `opportunity`, `fulfilment`.
> - Additive schema built and **applied to dev** (idempotent): `sql/add_extensions_variations.sql`. Not yet run on prod. Deviation: masters keep `master_deal_id` NULL (readers use `coalesce(master_deal_id, id)`) — a self-link can't be written in the same insert.
> - **Backfill built and applied to dev 2026-06-10** (idempotent): `sql/backfill_extension_opportunities.sql`. 70 contracts got `contract_end_date` (last day of final fulfilment month — all 2027-02-28); **64 extensions created** (Prospect, 20% flat from new `extension_initial_probability` setting, 2027-03-01 → 2028-02-29, 768 seeded months totalling R189,967,919.40 = parents' final-month run-rates × 12, verified). Not yet run on prod.
> - **Eligibility rule (added 2026-06-10): only RECURRING service types extend.** Flag is `service_sub.is_recurring`, but all 73 contracts have NULL `service_sub_id` — so the rule falls back to the major: eligible if the major has any active recurring sub (Manpower yes, Technology Works no). Applies to backfill AND the future secure-contract handler.
> - **Skipped contracts:** 4151/4154/4156 (Technology Works, also zero month rows), 4172 (TW, zero final-month revenue), plus 4 TW contracts excluded by the recurring rule — note these 4 are *named* monitoring/control-room contracts (Airport City 4254's parent, Kleine Parys, Lake Michelle, Leopard Creek) and may be **misclassified** under Technology Works; if reclassified (or a recurring TW sub is added), re-running the backfill auto-creates their extensions. 4216 (Manpower, "Contract has been cancelled", zero revenue) is the one eligible contract intentionally left without an extension — it is the single row on the exception report.
> - **Lineage UI ported to `index.html` 2026-06-10 (uncommitted):** Opportunities table now groups children (`master_deal_id` set) under a collapsible master row — toggle chevron, indented child rows, green EXTENSION / amber VARIATION tags, prototype colours. Sort/filter act on masters; children travel with theirs; a child whose master is outside the current view renders top-level. Lineage VALUE rollup not in this table (no value column; do it in RPP per the rollup section).
> - **Secure-contract handler v1 in `index.html` 2026-06-10 (uncommitted):** `maybeOfferExtensionProspect()` runs on save when stage transitions INTO Secured (5): sets parent `contract_end_date` if null, checks recurring eligibility + no existing extension child, then a plain `confirm()` offers the extension prospect (Prospect stage, `extension_initial_probability` setting, term + run-rate from the deal's own stream months, bulk-inserted). The agreed full workflow + authorisation role replaces the confirm later.

---

## Concept

A "contract" in Focus is a `deals` row at **stage 7** (In Progress / Fulfilment-Active). Extensions and variations are NOT mutations of that row — they are **new opportunities** that reference the original. Both relate back to the same originating deal and are viewed together as a **lineage** under a **master** (the original deal).

### Two types, different treatment

- **Extension** = a *new* contract term that commences the **month after** the existing term terminates. New `revenue_streams`, phased to start at `original.contract_end_date + 1 month`. **No month overlaps** the parent term. Value is the full new-term value.
- **Variation** = changes the **value of the existing, live** contract (e.g. add/remove posts). Overlaps the live term in time. Models the **DELTA ONLY** (positive = uplift, negative = reduction) as its own `revenue_stream_months` from the effective month. The original term's months are **never restated or overwritten** — this is what guarantees no double-count and preserves audit history.

### Key decisions locked
- Extensions/variations both start as **Qualified** opportunities (NOT Lead — relationship/need already proven). Skip the early lead-qualification gates.
- Extension value seeding = **copy parent's final-month run-rate, phased forward**.
- **No DB trigger.** Creating the forward extension opportunity is an **explicit step in the "secure contract" workflow** (app-side), done with the user present so term + run-rate can be confirmed/adjusted. The invariant is a *soft* expectation enforced by workflow + a check query, not a hard trigger.
- Realistic expectation: **most contracts extend** after the initial term, so extension opportunities belong in the pipeline as real rows from day one (low default probability, climbing as end-date nears).

### Entry stage + probability ramp (decided 2026-06-10 — DESIGN ONLY, not built)

- **Entry stage = Prospect (2).** No new stage; the "specialness" lives in `opportunity_type` (badge, reporting splits, probability rule), keeping stage and deal-type as orthogonal dimensions.
- **Flat at creation:** the secure-handler and backfill assign `extension_initial_probability` (settings row, suggest 20). No ramp math at creation.
- **Ramp = settings-driven schedule:** `extension_probability_ramp` settings row holds JSON breakpoints of months-until-commencement → % (e.g. `{"18":20,"12":30,"9":40,"6":55,"3":70,"1":80}`); `extension_ramp_enabled` is the kill switch. Anchor is the extension deal's own `start_date` (= parent `contract_end_date` + 1 month).
- **Trigger:** computed on pipeline load (no backend jobs exist); persist `deals.probability` only when the band changed. Probability stays a real column so all weighted-pipeline math is untouched.
- **Manual override:** additive `deals.probability_is_auto` boolean (handler sets true on extensions). Ramp only manages deals with the flag set; any hand-edit clears it permanently. While auto + in open stages, ramp value beats stage-default probability on lane moves. Backfilled near-term extensions start flat and self-correct on first ramp pass.

---

## Data model (all additive — matches house style: BEGIN/COMMIT, IF NOT EXISTS guards, verification SELECTs)

On `deals`:
- `opportunity_type` text — `new_business | extension | variation`, default `'new_business'`
- `master_deal_id` bigint, self-FK to `deals(id)` — the **lineage root** (the original deal id; self for a master). Used to GROUP the collapsible block and to roll up value.
- `parent_deal_id` bigint, self-FK to `deals(id)` — the **precise predecessor** (which term this extends / which contract this varies). Null for new business.
- `contract_end_date` date — end of the term this deal represents. Needed to phase extensions and to run the check query.

> Two distinct links on purpose: `master_deal_id` groups the family (avoids deep nesting when extensions chain); `parent_deal_id` records the exact relationship.

On `revenue_streams` (currently bare: `id, deal_id, stream_type, locked, created_at`):
- `parent_stream_id` bigint, self-FK (optional) — links a variation's delta stream to the original stream it modifies.

Money stays in `revenue_stream_months` (per-stream per-month, `month` is **text 'YYYY-MM'**, cols: `opportunity_revenue/_margin`, `fulfilment_revenue/_margin`, `actual_revenue/_margin`). No new value column needed — variation deltas are just `revenue_stream_months` rows on the variation's own stream.

---

## Value rollup (fixes the "revenue in pipeline not in Opportunities" issue)

Aggregate `revenue_stream_months` by **`master_deal_id`** (join `revenue_streams → deals`) instead of by `deal_id`. Then per lineage:
- Original term → contracted months (`fulfilment_revenue`)
- Variation → delta months only (overlap in time, no restatement)
- Extension → new-term months (no time overlap)

Worked example (from prototype, Harmony lineage): `12.60 + 1.34 + 5.00 = 18.94m`.

**Open decision for the collapsed master number:** show full lineage (incl. unwon extension) vs. contracted-only (original + won variations) with extensions as separate weighted pipeline. Recommend contracted-only for the headline so renewals years out don't inflate it.

---

## UI — master/child collapsible rows

Prototype built and approved: `focus_lineage_prototype.html` (single-file, Focus navy #003057, tag colours: extension green #0a6e4f, variation amber #9a5b00, negative delta red #FA0A11). Master row shows lineage total + disclosure toggle; children render indented and collapse. Reductions show as red negative deltas. Port this pattern into the pipeline/opportunities view in `index.html`.

---

## "Secure contract" workflow change

When a deal is secured (moves to stage 7), the handler gains a step that creates the forward **extension** opportunity:
- `opportunity_type='extension'`, stage=Qualified, owner inherited
- `parent_deal_id` = the deal being secured; `master_deal_id` = that deal's master (or itself if it's the original)
- `contract_end_date` = parent end + term
- seed `revenue_stream_months` with `opportunity_revenue` = parent's final-month run-rate, phased from parent end_date + 1 month

When an extension is later itself secured, the same step spawns the *next* forward extension — self-perpetuating chain.

**Backfill:** the 73 existing stage-7 contracts were loaded straight to prod and never ran through this handler, so none have extension opportunities. One-time SQL block to create a forward extension opportunity for every current stage-7 deal lacking one. Same logic as the handler.

**Check query (exception report):** stage-7 deals with zero or >1 open extension children — run anytime to confirm nothing drifted.

---

## FIRST STEPS for the Claude Code session (verify before building)

```sql
-- 1. Real deals columns
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema='public' and table_name='deals'
order by ordinal_position;

-- 2. Stage IDs (map "Qualified" and confirm stage 7 = In Progress)
select id, name, category from stages order by id;
-- if 'stages' is not the table:
-- select table_name from information_schema.tables
-- where table_schema='public' and table_name ~* 'stage';

-- 3. Confirm revenue_streams + revenue_stream_months columns
select table_name, column_name, data_type
from information_schema.columns
where table_schema='public'
  and table_name in ('revenue_streams','revenue_stream_months')
order by table_name, ordinal_position;
```

Then: write additive schema SQL → backfill SQL → secure-contract handler edit → port the lineage UI. Deploy via `node push_to_github.js` (remember: it bakes index.html to base64 HTML_B64 — regenerate the push script or your edits won't deploy).
