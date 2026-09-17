# Focus CRM — Project Context

This file is read by Claude Code at the start of every session. It is the source of truth for project conventions, gotchas, and architecture. Keep it current.

## Product

Focus CRM (formerly SalesFlow) — internal CRM for **Xone Integrated Security (Pty) Ltd**, a South African integrated security solutions company. Used by sales and management to track opportunities, contracts, leads, and engagements across mining, hospitality, residential estates, and FMCG sectors.

- **Current version:** v7.9.56 (Support Items and Training: training courses join the Support Items conditions as triggers and targets — a course ticks per post when its trigger holds, a ticked course can trigger items or other courses, and a course a condition ticked may be overridden off with a reason; the Conditional Criteria tile is renamed Support Items and Training; SQL in `sql/training_conditions.sql`. v7.9.55 was Conditional Criteria: a new Proposal Builder admin page with two areas — Incentives and Allowances (the allowance conditions, moved from Human Resources) and Support Items, where a named condition ticks support items of any category when an allowance or incentive is active on a post, a post condition holds, or another support item is ticked; workforce targets tick per post, contract and service targets once on the quote; an item a condition ticked may be overridden off with a reason; SQL in `sql/support_item_conditions.sql`. v7.9.54 was allowance conditions gain the always-on post condition `staffed` ("the post is staffed (always)", first in `PB_POST_CONDITIONS`, `pbPostCondition` returns true for every post) so a rule can apply to every post in a quote; no SQL. v7.9.53 was Workforce Support Items tab on the quote: each workforce item's rule total is summed over the posts that tick it by its basis, and the quote may add to, subtract from or override that total with a recorded reason after a warning; colour-coded status; the difference prices as its own line; SQL in `sql/workforce_support_adjustments.sql`. v7.9.52 was allowance conditions grow `requires` and `implies` rule types with trigger/target members and post-condition triggers (midnight shift, public holiday, Saturday, Sunday, weekend); SQL in `sql/allowance_rules_complex.sql`. v7.9.51 was support item categories: `quote_accessories.category` splits the old Accessories page into Workforce Support Items (things an officer carries or needs, per post), Contract Support Items (physical things a contract needs to be delivered) and Service Support Items (service things a contract needs to be delivered), the last two once per quote on the Contract Support Items tab; one table, one cost history; SQL in `sql/support_item_categories.sql`. v7.9.50 was start-date discipline: the revenue grid shows the current FY plus every FY holding a projection and the start date's FY, months before the start date are greyed, start date must be on or after the order date; an open opportunity whose start date arrives unsecured is suspended (new stage Suspended, probability 0, prior stage and probability kept on `deals.suspended_*`) by a once-per-session owner sweep on the dashboard and on open, with a forced review modal that restores stage and probability on a confirmed workable start date and shifts the stream; SQL in `sql/opportunity_suspension.sql`. v7.9.49 was Revenue Stream Generator: changing the service type warns and, when a stream exists, is allowed only together with clearing it (server-side delete of the months, margin and escalation reset to the new type's defaults); no SQL. v7.9.48 was edit opportunity: the revenue grid shows the current and next two financial years only, a past year only when it holds revenue (greyed tab), and past months are greyed and read-only; `getCurrentFY()` now follows `settings.fy_start_month` like `getFYMonths`; no SQL. v7.9.47 was Revenue Stream Generator is a compact pop-out modal opened from a button on the Proposal Builder tab, with the deal's service type shown and changeable there, margin as a field checked against the rule, and the grid's Margin row always naming the %; no SQL. v7.9.46 was annual escalation scoped to the service type: `quote_annual_escalations` rows carry `service_major_id` / `service_sub_id`, the generator picks sub → major → general for the start year, and the Manpower major is edited as a horizontal band above the Statutory Salary Rates grid; SQL in `sql/escalation_by_service_type.sql`. v7.9.45 was Revenue Stream Generator: the Proposal Builder tab's top block, collapsed by default, builds the opportunity stream before a proposal exists — the General tab's service type picks annuity or project via `service_sub.revenue_type`, escalation defaults from `quote_annual_escalations` by start year, the margin is asked for and checked against `quote_opportunity_margin_rules`, the probability is capped at `settings.rsg_probability_cap` (20), Clear deletes the months; Expected Order Date mirrored on the General tab; escalation now carries forward after the escalation month; SQL in `sql/revenue_stream_generator.sql`. v7.9.44 was accessory cost model: a dated cost row carries acquisition, life, running cost and loss allowance → one monthly unit cost, a basis that fixes the quantity (per officer, per duty position, per post, per contract) and a recovery rule (amortised, once-off to client, absorbed); per-contract items are ticked on the Contract Support Items tab with an equipment summary; the proposal prints once-off recovery as one "Setup and equipment" line; SQL in `sql/proposal_generator_accessory_cost_model.sql`; training deliberately untouched. v7.9.43 was: Accessories and Training Courses become dated items with a cost history: `in_use_date` / `retired_date` on the item, `quote_accessory_costs` / `quote_training_costs` effective-dated cost rows, new admin pages with a cost drawer, post checklists filtered by the quote's start date and showing the current cost; SQL in `sql/proposal_generator_item_costs.sql`. v7.9.42 was Increment 2: Issue numbers and freezes a proposal through the `issue_proposal()` transaction, versions supersede one another, Withdraw, a history panel with the frozen documents, a Proposal engagement on the deal and an offered move to the Proposal stage, Proposal column on the quote list; SQL in `sql/proposal_generator_inc2.sql`. v7.9.41 was Increment 1: the quote editor's Proposal tab renders a quote as the client proposal from an admin-edited template, previews it and prints it via a standalone window; per-post Required Accessories and Training checklists fed from the `quote_accessories` / `quote_training_courses` catalogues with new admin pages; SQL in `sql/proposal_generator_inc1.sql`, design in `docs/proposal-generator/DESIGN.md`. v7.9.40 was proxy compression that survives Netlify: the browser advertises `X-Focus-Gzip: 1`, the proxy hands the gateway's gzip bytes through under `X-Focus-Encoding: gzip`, `api()` inflates with `DecompressionStream`; Netlify itself does not compress function responses. v7.9.39 was the hotfix that switched the v7.9.38 `Content-Encoding` pass-through off. v7.9.38 was performance Tier 2, first objects: `dashboard_summary()` RPC feeds every dashboard widget and the Attention Workbench in one call, `engagements_labelled` view feeds Engagement History in one call; SQL in `sql/perf_tier2_*.sql`. v7.9.37 was Tier 1: `sweep_leads()` / `heartbeat()` RPCs with fallbacks, stream label in the engagement insert; SQL in `sql/perf_tier1_*.sql`. v7.9.36 was Tier 0: single dashboard render at login, embedded user-context read, parallel loaders for deal/lead/quote, one-call revenue-month upsert, client-only tab clicks, logos moved out of the HTML, minified deploy via `build.js`; see `docs/perf-review/`; as of 17 September 2026)

## Performance conventions (v7.9.36)

- **Sequential round trips are the cost that users feel** (~1.4 s per proxied call). Never chain `await api(...)` calls that only depend on an id you already have: put them in one `Promise.all`.
- `api(table, method, body, params, opts)` accepts `opts.prefer` (e.g. `'resolution=merge-duplicates,return=minimal'` for an upsert), `opts.silent` (background traffic, no busy bar) and `opts.headers` (returns `{ rows, headers }`). `apiGetAll` pages in parallel using `Content-Range`; `apiCount` counts server-side.
- A write already returns the row (`Prefer: return=representation`): splice it into memory and re-render, do not re-download the table. `reloadLeadAfterServerChange(row)` takes the PATCHed row.
- Tab, scope and layout clicks must be client-only (`renderLeadsPage({ reuse: true })`, `_dashApplyOrderToDom`).
- Netlify publishes `dist/` built by `node build.js` (esbuild-minified inline script). `index.html` remains the only source file; do not edit `dist/`.
- Tier 1 SQL lives in `sql/perf_tier1_indexes.sql`, `perf_tier1_triggers.sql`, `perf_tier1_audit_statement_level.sql`, `perf_tier1_sweeps_heartbeat.sql` (run in that order, Dev first). The client detects a missing `rpc/sweep_leads` / `rpc/heartbeat` (404) and falls back to the old per-row path, so code and SQL can ship independently.
- **Tier 2 shapes (v7.9.38).** `sql/perf_tier2_dashboard_summary.sql` installs `dashboard_summary(p_from)` → one jsonb bundle; `renderDashboard` keeps it in `window._dashBundle` and every widget reads `B ? B.<key> : await apiGet(...)`, so the per-widget reads remain the fallback when the function is absent (404 / PGRST202). A scope switch re-renders with `renderDashboard({ reuse: true })` — no traffic. `sql/perf_tier2_engagements_labelled.sql` installs the `engagements_labelled` view; `_engHistLoad` reads it when `_engHistViewAvailable()` (absent view → 404 / PGRST205 → old three-round path). In mock mode a view is served only when `_mockStore()` holds a table of that name. Label rules live in the SQL comments — keep them in step with `_engHistCat`, `leadEngLabel` and friends.
- **Proxy compression (v7.9.40).** Netlify does not compress function responses (checked in devtools on Dev: no `content-encoding` on `/sb/` replies), so `netlify/functions/sb.js` asks the Supabase gateway for gzip and, when the request carries `X-Focus-Gzip: 1`, returns the compressed bytes as-is (`isBase64Encoded`, `Content-Type: application/octet-stream`) flagged with the private header `X-Focus-Encoding: gzip`; `_apiBodyText()` in `index.html` inflates them with `DecompressionStream`. Browsers without it, and every non-2xx reply, get plain JSON (inflated in the function). `system_users` always stays plain because its body is scrubbed. `SB_GZIP=0` in the Netlify environment switches it all off. Never use `Content-Encoding` for this — the v7.9.38 attempt could not be verified through Netlify's edge.
- **Proposal Generator (v7.9.41, Increment 1).** `sql/proposal_generator_inc1.sql` installs `proposal_templates`, `proposal_template_sections`, `proposal_documents`, `proposal_document_sections` and the default template. `openQuote` loads templates, the quote's draft document and latest `quote_snapshots` row in its first round and the two per-post checklist tables in the second; an absent `proposal_templates` (404 / PGRST205) sets `_pgMissing` and hides the tab. The renderer (`pgRenderDocument`) never prices: it reads `rate_data.pricing.groups[].posts[]{name,officers,monthly}` from the snapshot and, until the calc engine writes one, falls back to `pbPostSummaryCost` under an INDICATIVE banner. Boilerplate uses `{{token}}` merge fields resolved in `pgFields`; unknown tokens render red and are listed above the preview. A draft `proposal_documents` row is created lazily on the first per-proposal edit; overrides upsert into `proposal_document_sections` with `on_conflict=document_id,section_key`. Issue / numbering / engagement side effects are Increment 2.
- **Proposal Generator (v7.9.42, Increment 2).** `sql/proposal_generator_inc2.sql` installs `person_has_permission()`, `issue_proposal(p_document_id, p_actor_id, p_content, p_html)` and `withdraw_proposal()` (all `SECURITY DEFINER`; the actor arrives as a parameter because the proxy uses the service key) and grants `issue_proposal` to Admin and Sales Manager (the script said Manager, a role that exists on neither database, until 2026-09-17). Issue is one transaction: number `P-<year>-<nnnn>` from `proposal_ref_seq`, frozen `content_json` + `rendered_html`, latest snapshot pinned, earlier issued rows → superseded, quote → `sent`. The client refuses to issue (`pgIssueBlockers`) without a snapshot, on a sandbox quote, with unknown merge fields, or while a `prompt` section still shows its template text; an absent RPC (404 / PGRST202) sets `_pgRpcMissing`. After the RPC the client re-renders with the real number and PATCHes the final HTML, then writes the ledger: a client-facing engagement (activity type matching /proposal/, `next_action_done`, contact linked via `engagement_people`) and a `confirmDialog` offer to move the deal to the stage named Proposal (never backwards). A draft after an issue takes version max+1 and is seeded from the issued version's `content_json.overrides`. Mock mode emulates both RPCs in `pgMockIssue` / `pgMockWithdraw`.
- **Dated catalogue items (v7.9.43).** `sql/proposal_generator_item_costs.sql` adds `in_use_date` / `retired_date` (inclusive; NULL = open) to `quote_accessories` and `quote_training_courses` and the cost tables `quote_accessory_costs` (`unit_cost`, `cost_basis`) and `quote_training_costs` (`cost_per_officer`, `validity_months`), one row per price change, never edited. `PB_ITEM_KINDS` describes both; `pbItemInWindow(item, asAt)` and `pbItemCurrentCost(costs, fk, id, asAt)` are judged at `pbQuoteAsAt()` (contract start date) like the rate cards. `renderPbItemCatalogPage(kind)` replaces the flat grid for these two pages; `code` is generated from the name (`pbSlug`) and never typed. The calc engine, when it lands, should read the same two helpers so the snapshot prices accessories and training off the dated rows.
- **Workforce Support Items tab (v7.9.53).** `quote_workforce_adjustments` (one row per quote and item: `mode` add | subtract | override, `quantity`, `reason`) loads into `pbWorkforceAdj`. `pbWorkforceRollup(includeAll)` builds a row per workforce item that is ticked on a post or adjusted (per-contract-basis items excluded): `auto` = Σ `pbAccQtyForPost` over ticking posts, `final` = `pbWfFinal(auto, adj)`, `level` ok | info (above) | warn (below) | bad (no cost / outside window) with `warnings`. `renderWorkforceTab` draws it with `PB_WF_LEVEL` colours and an inline adjust row; `pbWfAdjustSave` requires a reason and a `confirmDialog` (danger when below the rule), upserts on `quote_id,accessory_id`. `pbAccSummary` adds the delta as a 'Workforce adjustment' line so post prices stay rule-based; `pgPricing` groups it as 'Workforce support items'.
- **Training in conditions (v7.9.56).** `quote_support_item_rule_members.kind` gains `training` (`code` = `quote_training_courses.id` as text) for triggers and targets; `quote_post_training` gains `state` / `override_reason` like the accessory tick tables. `pbSupportEval()` returns a third bucket `training[postId][courseId] = rule name`, adds `training:<id>` to each post's active set (manual ticks plus auto ticks less `p.trainingOff`), and a training target always ticks per post. **Every reader of a post's training goes through `pbPostTrnSet(p)`** (checklist, proposal scope) — never `p.training`. `PB_CHECKLIST_TABLES` now carries `off`, `evalKey` and `pending` per kind so `pbChecklistCols`, `pbToggleChecklist` and the shared `pbChecklistOverrideConfirm(postId, kind, itemId)` / `pbChecklistOverrideCancel` handle both kinds; the admin editor adds a Training Courses group to both pickers via `_supTrainingGroup`. The 'on' POSTs still never send `state`, so the client runs before the SQL; a save with a training member on an old database fails on the kind check and the message names the SQL file.
- **Conditional Criteria (v7.9.55).** Sidebar page `pb_conditional_criteria` → `renderPbConditionalCriteriaPage()` with `_ccActive` (null | allowances | support); the router resets it so the sidebar always lands on the two tiles; `pbBackToCcGrid()`. `renderAllowRules` (unchanged rules) lives here now — the `allowance-rules` HR tile is gone. **Support Items conditions:** `quote_support_item_rules` + `quote_support_item_rule_members` (`role` trigger | target, `kind` adds `support` with `code` = `quote_accessories.id` as text); admin screen `renderSupportRules` / `_supPaint` / `_supSave` mirrors the allowance editor with one rule type (auto-includes). `pbSupportEval()` is one fixpoint over the quote, memoised in `_pbSupportEval` (cleared at the top of the `renderQuoteEditor` datalist wrapper — the wrapper, not the original function, is the render that runs): `posts[postId][accId] = rule name` for workforce targets, `contract[accId]` for contract / service (or legacy per-contract-basis) targets, triggers judged with `pbTriggerActive` over `pbActiveAllowSet(p)` plus `support:<id>` for effective ticks (a contract-level tick holds on every post). **Every reader of ticks goes through `pbPostAccSet(p)` / `pbContractAccMap()`** (summary, workforce rollup, checklists, Contract tab, proposal scope) — never `p.accessories` / `pbContractAcc` directly, which hold only the manual rows. Overrides: `quote_post_accessories` / `quote_contract_accessories` gain `state` ('on' default, 'off') and `override_reason`; loader fills `p.accessoriesOff` `{id: reason}` and `pbContractAccOff` Map; unticking an auto item opens `pbSupportReasonRow` (confirm → DELETE then POST the off row), re-ticking deletes the off row. The 'on' POSTs never send `state`, so the client runs before the SQL (no conditions, no overrides). `pbRuleParts(rule, table)` takes the members table; `pbAllowLabelFor('support', id)` names the item.
- **Allowance conditions (v7.9.52).** `quote_allowance_rules.rule_type` ∈ exclusive | requires | implies; members carry `role` (member | trigger | target) and kind may be `post` (codes in `PB_POST_CONDITIONS`, judged by `pbPostCondition`; v7.9.54 adds `staffed`, always true, so an implies rule on it ticks its targets on every post and a requires rule on it never lets its targets be cleared). `pbImpliedStat(p)` = statutory codes ticked by an implies rule with an active trigger (iterated, so chains work); `pbStatIsAuto(r, night, implied)` replaces the bare night check in the render and in `pbActiveAllowSet(p, implied)`. `pbRuleConflict` returns `{rule, other, message}` for exclusive clashes and missing requires targets; `pbRuleRemovalBlock` refuses clearing a requires target while its trigger is active (an implies target is overridden off with a reason like night). Admin editor `_arPaint` has a type select; implies targets are statutory only.
- **Support item categories (v7.9.51).** `PB_ITEM_KINDS` has `accessory` (workforce), `contract` and `service` over the same `quote_accessories` table, filtered by `category` (`pbItemCategory(item)`, NULL = workforce); `model:'accessory'` picks the cost form, `defaultBasis` preselects the basis. Per-post checklists show workforce items only; `renderContractItemsTab` lists contract and service items (plus any legacy per-contract-basis item). Admin pages `pb_accessories`, `pb_contract_items`, `pb_service_items`.
- **Accessory cost model (v7.9.44).** `quote_accessory_costs` rows: `acquisition_cost`, `life_months`, `monthly_cost`, `loss_pct_per_year`, `cost_basis` (per_officer | per_duty_position | per_post | per_contract), `recovery` (amortised | once_off | absorbed). `pbAccMonthlyUnit(c)` = acquisition/life + running + acquisition×loss%/12; `pbAccQtyForPost(basis, p)` = officers required (pool excluded, Richard 2026-09-11) / peak headcount / 1. Per-contract items live in `quote_contract_accessories` (`pbContractAcc` Map, Contract Support Items tab). `pbAccSummary()` rolls every tick into monthly-by-post, contract monthly and once-off setup; the indicative pricing path adds those to the post prices and prints once-off as one "Setup and equipment" line (a snapshot supplies `pricing.setup_once_off`). Training costs are a separate, later model — do not fold them into this one.
- **Revenue Stream Generator (v7.9.45).** `rsgRefresh()` (on service change, start-date change and panel open) reads `rsgRevenueType(sub)` (`service_sub.revenue_type`, falling back to `is_recurring`), fills a blank escalation from `rsgDefaultEscalation(startDate)` (row for the start year, else the nearest earlier year) and shows `rsgMarginRule(sub)` (service-type rule beats the revenue-type rule; newest effective date wins). `rsgAutoPopulate()` asks for the margin with `promptDialog`, refuses one outside the rule, runs the existing `autoPopulateGrid()`, then caps `opp-probability` at `rsgProbabilityCap()`. `rsgClear()` deletes the stream's `revenue_stream_months` on the server and empties `oppMonths` (a save only upserts months with values, so it cannot clear). Input ids `opp-base-amount`, `opp-order-date`, `opp-start-date`, `opp-num-months`, `opp-escalation`, `opp-margin-pct` are unchanged (v7.9.47: they live inside the static `#rsg-modal` overlay, shown/hidden by `rsgOpen()` / `rsgClose()`, never rebuilt; `#rsg-service-sub` mirrors `opp-service-sub-id` both ways via `rsgServiceChanged`; `#rsg-summary` is the one-line state beside the button; the grid's `.rev-margin-pct` spans are refreshed in `recalcGrid`); `opp-order-date-general` mirrors the order date via `rsgSyncOrderDate`. Admin: HR tile `annual-escalation`, page `pb_margin_rules` (generic editor; `PB_SCHEMAS` columns may carry `default`, and lookups add as null). Project generator is a placeholder.
- **Suspension (v7.9.50).** `dealStartDateStale(deal)` = open stage (category Opportunity-Open, not Suspended) and `start_date <= today`. `suspendDeal` PATCHes stage → Suspended, probability 0, `suspended_from_stage_id` / `suspended_probability` / `suspended_at`, and logs a closed engagement. `sweepStaleStartDeals()` runs once per session from `renderDashboard` for the current user's own deals, then `reviewSuspendedDeals` shows `reviewSuspendedDeal` (modal: new order/start dates, shift-stream tick, Keep suspended / Restore with `confirmDialog`). `restoreSuspendedDeal` reinstates stage and probability, clears the `suspended_*` columns, optionally `shiftRevenueStreamTo(dealId, 'YYYY-MM')` (delete + reinsert the stream's months, values kept), logs a Restored engagement. `oppSuspensionOnOpen()` runs at the end of `openOpportunity`: suspends a stale deal the user may edit and shows `#opp-suspended-banner` with the review button. `saveOpportunity` enforces `checkDatesOrder` and offers the restore when a suspended deal is saved with a future start date. Absent Suspended stage (SQL not run) → all of it is inert.
- **Escalation by service type (v7.9.46).** `rsgEscalationRowsFor(sub)` returns the most specific scope with rows (sub, then major, then the general rows with both NULL); `rsgDefaultEscalation(startDate, sub)` reads that. `srRenderEscalationBand('sr-escalation')` draws the Manpower band on `renderSalaryRateGrid` (major found by name /manpower/), inline PATCH per year and `+ Year` POST; the HR tile edits every scope. Unique index is on (year, COALESCE(major,0), COALESCE(sub,0)).
- **Proving a new server-side shape:** `tests/perf/` has the harness — dump a Dev snapshot, render the old path in mock mode over it and the new path over the real SQL output, and diff the HTML (`equiv_dash.js`, `equiv_eh.js`). Ties in undefined sort order and deliberate truncation are the only acceptable differences.
- The ranked proposals for the remaining tiers (views/RPCs, topology, rendering) are in `docs/perf-review/PERFORMANCE_REVIEW.md`.
- **Tagline:** Lead by Example
- **Font:** Arial
- **Brand colours:**
  - Red: `#FA0A11`
  - Dark blue: `#003057`
  - White: `#FFFFFF`
  - Black: `#000000`
  - Khaki: `#C3B091`

## Deployment

- **Frontend:** Netlify — `storied-griffin-6eab6b.netlify.app`
- **Backend:** Supabase — `kevrfdjqyuhmgziqxuvs.supabase.co`
- **Repo:** GitHub — `Richard-Groenewald/Focus` (previously `Richard-Groenewald/salesflow`)

## Architecture

- **Single HTML file app** (legacy structure — a modular rebuild is planned).
- Earlier SalesFlow build used localStorage; current build uses Supabase.

### Pipeline stages
Lead → Prospect → Secured → Lost

### Regions
Western Cape, Gauteng

### Service types and margins
- **Manpower — On-Site Guarding:** 25% margin, recurring
- **Manpower — Off-Site Control Rooms:** 30% margin, recurring
- **Technology Works — Project:** 25% margin, non-recurring

### Revenue streams are the fundamental data structure
A deal has two phases:
1. **Opportunity** (pre-securing)
2. **Contract** (post-securing) — the opportunity stream is frozen and a contract stream is auto-created.

**Base Amount and Num Months are auto-populate only.** All TCV and financial figures derive *exclusively* from revenue streams. Do not compute financials from any other field.

## Database schema (Supabase, Postgres)

### Critical naming
- The live deals table is **`deals`** — **NOT `opportunities`**. (An older handover doc had this wrong; ignore it.)
- The existing interaction log for deals is **`engagements`**.

### Core tables
- `organisations`
- `people`
- `system_users`
- `user_credentials`
- `deals`
- `opportunity_streams`
- `contract_streams`
- `engagements`
- `interactions`
- `risks`

### Leads Register tables (added Increment 1)
- `lead_sources`
- `research_campaigns`
- `leads`
- `lead_interactions`

### Conventions
- **IDs:** `BIGINT` / `BIGSERIAL` throughout.
- **Timestamps:** `TIMESTAMPTZ` for all audit fields.
- **Ownership / audit:** `owner_id` and `created_by` always reference `people(id)`.
- **Current user resolution:** `currentUser.personId` is sourced from `system_users.person_id → people.id`.

## Critical gotchas

### Supabase keys from Netlify
- `sb_secret_` prefixed keys **fail** when called from Netlify functions.
- **Use the service role JWT** as `SUPABASE_SECRET_KEY` instead.

### Table naming
- Always write `deals`, never `opportunities`, when referencing the deals table.

## Deploy workflow

- Pushes go via a `push_to_github.js` script in the repo.
- When generating a new `push_to_github.js`, always include the exact run command in a copyable code block:

```
node push_to_github.js
```

(Claude Code can also commit and push directly via the GitHub MCP once configured — see `.mcp.json`.)

## Active work — Leads Register

**Increment 1 — shipped:**
- DB tables (`lead_sources`, `research_campaigns`, `leads`, `lead_interactions`)
- Sidebar entry
- Read-only list pages

**Increment 2 — in progress:**
- Lead form with three tabs:
  1. **Overview**
  2. **Qualification** — F / T / A / C dots
  3. **Interactions**
- Research campaign form
- Conditional dropdown shown when `source = Research`

**Beyond Increment 2:** Full rebuild from scratch planned. Modular file structure from day one.

## Coding conventions

- Match existing code style in the single HTML file.
- Brand colours and Arial font in all UI.
- All financial calculations come from revenue streams, never from Base Amount or Num Months directly.
- New tables follow the BIGINT / TIMESTAMPTZ / `people(id)` references convention above.

## What NOT to do

- Do not reference an `opportunities` table — it does not exist in this database.
- Do not use `sb_secret_` keys in any Netlify-deployed code path.
- Do not compute TCV or revenue figures from Base Amount or Num Months.
- Do not commit secrets. The `.env` and any keys stay local; Netlify env vars hold production secrets.
