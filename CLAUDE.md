# Focus CRM — Project Context

This file is read by Claude Code at the start of every session. It is the source of truth for project conventions, gotchas, and architecture. Keep it current.

## Product

Focus CRM (formerly SalesFlow) — internal CRM for **Xone Integrated Security (Pty) Ltd**, a South African integrated security solutions company. Used by sales and management to track opportunities, contracts, leads, and engagements across mining, hospitality, residential estates, and FMCG sectors.

- **Current version:** v7.7.22 (Global activity bar on every action + Perf Phase 2; Dev only; as of 24 June 2026)
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
