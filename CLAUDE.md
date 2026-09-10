# Focus CRM — Project Context

This file is read by Claude Code at the start of every session. It is the source of truth for project conventions, gotchas, and architecture. Keep it current.

## Product

Focus CRM (formerly SalesFlow) — internal CRM for **Xone Integrated Security (Pty) Ltd**, a South African integrated security solutions company. Used by sales and management to track opportunities, contracts, leads, and engagements across mining, hospitality, residential estates, and FMCG sectors.

- **Current version:** v7.9.42 (Proposal Generator Increment 2: Issue numbers and freezes a proposal through the `issue_proposal()` transaction, versions supersede one another, Withdraw, a history panel with the frozen documents, a Proposal engagement on the deal and an offered move to the Proposal stage, Proposal column on the quote list; SQL in `sql/proposal_generator_inc2.sql`. v7.9.41 was Increment 1: the quote editor's Proposal tab renders a quote as the client proposal from an admin-edited template, previews it and prints it via a standalone window; per-post Required Accessories and Training checklists fed from the `quote_accessories` / `quote_training_courses` catalogues with new admin pages; SQL in `sql/proposal_generator_inc1.sql`, design in `docs/proposal-generator/DESIGN.md`. v7.9.40 was proxy compression that survives Netlify: the browser advertises `X-Focus-Gzip: 1`, the proxy hands the gateway's gzip bytes through under `X-Focus-Encoding: gzip`, `api()` inflates with `DecompressionStream`; Netlify itself does not compress function responses. v7.9.39 was the hotfix that switched the v7.9.38 `Content-Encoding` pass-through off. v7.9.38 was performance Tier 2, first objects: `dashboard_summary()` RPC feeds every dashboard widget and the Attention Workbench in one call, `engagements_labelled` view feeds Engagement History in one call; SQL in `sql/perf_tier2_*.sql`. v7.9.37 was Tier 1: `sweep_leads()` / `heartbeat()` RPCs with fallbacks, stream label in the engagement insert; SQL in `sql/perf_tier1_*.sql`. v7.9.36 was Tier 0: single dashboard render at login, embedded user-context read, parallel loaders for deal/lead/quote, one-call revenue-month upsert, client-only tab clicks, logos moved out of the HTML, minified deploy via `build.js`; see `docs/perf-review/`; as of 10 September 2026)

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
- **Proposal Generator (v7.9.42, Increment 2).** `sql/proposal_generator_inc2.sql` installs `person_has_permission()`, `issue_proposal(p_document_id, p_actor_id, p_content, p_html)` and `withdraw_proposal()` (all `SECURITY DEFINER`; the actor arrives as a parameter because the proxy uses the service key) and grants `issue_proposal` to Admin and Manager. Issue is one transaction: number `P-<year>-<nnnn>` from `proposal_ref_seq`, frozen `content_json` + `rendered_html`, latest snapshot pinned, earlier issued rows → superseded, quote → `sent`. The client refuses to issue (`pgIssueBlockers`) without a snapshot, on a sandbox quote, with unknown merge fields, or while a `prompt` section still shows its template text; an absent RPC (404 / PGRST202) sets `_pgRpcMissing`. After the RPC the client re-renders with the real number and PATCHes the final HTML, then writes the ledger: a client-facing engagement (activity type matching /proposal/, `next_action_done`, contact linked via `engagement_people`) and a `confirmDialog` offer to move the deal to the stage named Proposal (never backwards). A draft after an issue takes version max+1 and is seeded from the issued version's `content_json.overrides`. Mock mode emulates both RPCs in `pgMockIssue` / `pgMockWithdraw`.
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
