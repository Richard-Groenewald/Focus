# Focus CRM — performance review and proposals

*September 2026. Reviewed: `index.html` (v7.9.35, 28,147 lines), `netlify/functions/sb.js`, and every file in `sql/`. No live database access; row counts are stated as assumptions where they matter.*

**Constraint honoured throughout:** nothing below relies on local caching or local storage (no localStorage, sessionStorage, IndexedDB, Cache API or service-worker data caching, and no extension of the existing lookup cache). Every gain comes from fewer or parallel round trips, narrower queries, server-side joins and aggregation, database indexes and triggers, smaller payloads, proxy and topology changes, and cheaper rendering.

---

## 1. Why Focus is slow

Focus does not have one slow query. It has a **fixed cost per data call** and **hundreds of places that pay it one call at a time**.

Every read or write goes browser → Netlify Lambda (`sb.js`) → Supabase PostgREST → Postgres and back. The code's own comments measure that hop at **0.6–1.4 s** (`loadTable`, line ~3617: "each apiGet is a ~1.4s proxied round-trip"). Users are in South Africa, the Lambda runs in a US region by default, and the `sb.js` comment about "cross-Atlantic TLS handshakes" says the database is not next to the Lambda either. So the floor per call is two long-haul legs plus a Lambda dispatch, regardless of how cheap the SQL is.

On top of that floor, the app issues its calls **sequentially**: one `await` after another, `for` loops with an `await` inside, and 150-id chunk loops. The number the user feels is the **sequential depth** of a flow, not the total number of calls. That depth, multiplied by roughly 1.4 s, is the wait:

| Flow (as coded today) | Sequential depth | Total calls | Felt wait at ~1.4 s/hop |
|---|---:|---:|---:|
| Sign in → sidebar visible (auth + user context) | 6–7 | 11–12 | 8–10 s |
| Lookup preload before first page (people/orgs/sites paged 1000 at a time) | 5–7 | 9–14 | 7–10 s |
| Dashboard (sales manager), rendered **twice** per login | 7–10 | ~31 ×2 | 10–14 s ×2 |
| Open a deal | 8–11 | 8–11 | 11–15 s |
| Open a lead | 8–13 | 10–20 | 11–17 s |
| Open a quote (Proposal Builder) | 15 | 15 | 17–22 s |
| Save a deal with N revenue months | 2N+4 | 2N+4 | N=12: ~40 s · N=36: ~110 s |
| Secure a deal (N months) | 2N+19 | 2N+19 | N=12: ~60 s |
| Log one engagement on a lead | 10–14 | 10–14 | 14–18 s |
| Promote a lead (typical package) | 13–36 | 13–36 | 18–50 s, not transactional |
| Leads register open, and **every tab or scope click** | 2 + (leads to sweep) | 5–9 + PATCH per lead | 3 s + 1.4 s per swept lead |
| Engagement History | 8–18 | 9–23 | 11–25 s |
| Reports → Activity statistics | ~20 | ~22 | ~28 s, re-run on every filter click |
| Milestones register | 7 | 6 + M/150 | ~10 s |
| Background heartbeat | 2 per minute | 120 per user-hour | busy bar flashes every minute |

Three multipliers make it worse:

1. **The dashboard renders twice on every sign-in.** `applyUserContextChrome()` ends with `buildNav()` (line 11552), and `enterApp()` calls `buildNav()` again after the lookup preload (line 11594). `buildNav()` always navigates to the first page, so the ~31-request dashboard fan-out runs once with empty settings and lookups, then again for real, competing with the preload for the same Lambda capacity.
2. **Whole tables are downloaded to filter or count in the browser.** One dashboard render fetches `leads` whole four times (lines 12140, 12291, 12393, 12621) and `deals` whole five times (12394, 12645, 12658, 12694, 12769). The opportunities register pulls every deal and every opportunity month row of every deal to sum TCV per client. The leads register pulls `select=*` on leads, organisations and sites on every open and every tab click.
3. **The page itself is 2.2 MB.** Two 1295×1467 px logos are embedded as base64 inside the render-blocking `<style>` and displayed at 159–178 px wide; with the sidebar logo they are 569 KB raw and, because base64 does not compress, **half of the 849 KB gzip transfer**. The 1.5 MB script is unminified (comments alone are 248 KB). With 41 version bumps in 17 days, users re-download and re-parse this about 2.4 times a day.

None of this is the database being slow. Postgres is doing sequential scans on several hot columns (no index on `engagements.deal_id`, `engagements.engagement_date`, the open next-actions predicate, `person_organisation_roles.org_id`, `leads.promoted_deal_id`), and the row-level audit trigger does a full jsonb diff per row, but those cost milliseconds today against a 1.4 s hop. They matter as insurance and once the round trips are gone.

---

## 2. The proposals, ranked

Each item names the mechanism it removes, the effort (S = hours, M = a day or two, L = a week-scale change), and what the user gets. Tier 0 needs no database change. The full evidence for every item, with line numbers, is in [findings-catalogue.md](findings-catalogue.md) (176 findings, referenced by ID below).

### Tier 0 — code-only fixes in `index.html` (do first; most gain per hour)

| # | Change | Effort | Removes | IDs |
|---|---|---|---|---|
| 0.1 | **Render the dashboard once at login.** Give `buildNav(navigate)` a flag; call `buildNav(false)` from `applyUserContextChrome` and keep the single navigation in `enterApp`. Add a monotonically increasing load sequence in `showPage`/`loadTable` so a slow stale render can never overwrite the current page. | S | One complete ~31-request dashboard fan-out per login and per resume | F1 |
| 0.2 | **One embedded query for the user context.** Replace the 5–6 sequential rounds of `buildUserContext` with a single PostgREST embed on `system_users` (roles → role_permissions → permissions, regions, branches, overrides). All FKs exist. | S | 4–5 sequential hops from every sign-in | F2 |
| 0.3 | **Unchunk the lookup preload and page in parallel.** Drop the `CONCURRENCY = 4` loop in `preloadLookups` (Lambda scales per invocation; the throttle buys nothing) and make `apiGetAll` read `Content-Range` from page 1 and fetch the remaining pages in parallel (needs 0.13). | S | 2–6 sequential hops at login; more as people/organisations grow | F3, G8 |
| 0.4 | **Parallelise the openers.** `openOpportunity`: streams+months, collaborators, contacts, engagements, lead history are all keyed by the deal id — one `Promise.all`. `openLeadForm`: description log, contacts, estimates, interactions, cadence, qualification are all keyed by the lead id. `openQuote`: 15 awaits with no `Promise.all`; two stages (quote+posts+lookups, then post children) is depth 2. | S each | Deal 8→2, lead 8→2, quote 15→2 sequential hops | OPP-02, LF-01, PB-01 |
| 0.5 | **Save revenue months as one upsert.** `saveRevenueStream` does a GET-then-PATCH/POST per month. `revenue_stream_months` already has `UNIQUE(stream_id, month)`, so one `POST` of the array with `Prefer: resolution=merge-duplicates` writes every month in one call. Needs 0.12. Also stop re-reading the months in `runSecuredProcess` and `maybeOfferExtensionProspect` (they were just written) and merge the three `deals` PATCHes into one. | S | 2N+4 → ~4 hops per save; 2N+19 → ~8 on secure | OPP-01, OPP-03 |
| 0.6 | **Make list interactions client-only.** The leads status tabs, scope buttons, band toggles and the dashboard's scope switch / drag-reorder / reset / reminder-dismiss all re-run the full network load to filter an array already in memory. Route them to the in-memory re-render only. | S | 3–9 calls per tab click, ~31 per dashboard cosmetic action | LR-01, D10, MIL-2, RPT-2 |
| 0.7 | **Stop the read-after-write habit.** Every PATCH already returns the row (`Prefer: return=representation`). `reloadLeadAfterServerChange` re-GETs the lead and then PATCHes status again after every action; generic-page saves re-download the whole table; `openEngagement` re-fetches the engagement, deal and collaborators the page already holds. Use the returned row, splice it into memory, re-render. | S | 1–3 hops on every lead action, every admin save, every engagement open | PW-02, G4, OPP-05, PB-10, MIL-3 |
| 0.8 | **Fold the engagement save into one insert.** `saveLeadInteraction` writes the new row, then PATCHes it twice (stream fields, contacts), then GETs the lead's last touch and PATCHes the lead, then reloads. Send stream_label and contacts in the POST; let the DB default `stream_id` (see 1.3); drop the last-touch GET+PATCH (a trigger already maintains it); bulk-insert `engagement_people` and milestones. | M | 10–14 → 3–4 hops on the most frequent write in the app | LI-2, PW-03, LI-4, PW-08 |
| 0.9 | **Ownership scope inside the same `Promise.all`.** `_ensureOwnershipScope` (3 whole-table pulls) is awaited after the primary fetch on every Contacts and scoped Clients visit; it does not depend on it. | S | 1 hop per visit (until 2.7 replaces it) | G1 |
| 0.10 | **Embed instead of chaining.** Client contacts (links → people), `loadEligiblePeople` (orgs → affiliations → people), `_liLoadPeople`, the engagement-history parent lookups: PostgREST resource embedding returns the join in one call wherever an FK exists. | S each | 1–2 hops each | G2, G9, LI-5, EH-1 |
| 0.11 | **Heartbeat: one call, less often, only when visible.** Replace the PATCH-then-GET tick with the `heartbeat()` RPC (2.9), poll every 5 minutes, skip when `document.hidden`, rate-limit the refocus trigger, and add a `silent` option to `api()` so background calls do not flash the busy bar. | S | 120 → 12 calls per user-hour; the every-minute "working" flash | POLL-1, CPU-10 |
| 0.12 | **Let callers set `Prefer`.** `api()` hard-codes `return=representation`. Add an optional argument so writes can send `resolution=merge-duplicates` (upserts) or `return=minimal` (fire-and-forget). `sb.js` already forwards the header. | S | Enabler for 0.5, PB-04/05/07, LI-4 | PB-12 |
| 0.13 | **Expose `Content-Range`.** In `sb.js`, forward `Range`/`Range-Unit` upstream and copy `Content-Range` back with `Access-Control-Expose-Headers`. Add `apiCount(table, params)` using `Prefer: count=exact` + `Range: 0-0`. Dashboard KPIs then cost a 100-byte response instead of a table download. | S | Enabler for 0.3 and the dashboard counts | INF-4 |
| 0.14 | **Client timeouts below the Lambda's.** `API_TIMEOUT_MS` 12 s > Netlify's 10 s function timeout, and 3 retries with no concurrency cap triple the load when the proxy is saturated. Set 8 s, 2 attempts, and a small in-flight limiter (≈6). | S | 30 s stalls during cold-start bursts | INF-5 |
| 0.15 | **Move the three logos out of the HTML** as files at 2× display size (`icons/`), referenced by URL. Also the two SVG data URIs. | S | 2.22 MB → ~1.65 MB raw; gzip transfer 849 KB → ~430 KB on every load and every post-deploy reload | PW-1, F5 |
| 0.16 | **Minify at build.** A `build.js` step in `netlify.toml` (esbuild for the script, csso for the CSS) that keeps the single-file dev workflow but publishes a minified `dist/`. Batch releases to one deploy a day so the refresh banner fires once. | M | 154 KB gzip per load; ~2.4 forced reloads per user per day | PW-2 |

### Tier 1 — database: indexes and triggers (one migration; run once on test, then prod)

| # | Change | Effort | Removes | IDs |
|---|---|---|---|---|
| 1.1 | **Add the missing indexes** (ready-to-run file in §4). Hot ones: `engagements (deal_id, engagement_date desc, id desc)`, `engagements (engagement_date, id)`, a partial index on open next actions, `engagements (org_id, engagement_date desc) where org_id is not null`, `person_organisation_roles (org_id, person_id)`, `leads (promoted_deal_id)`, `leads (target_org_id)`, `leads (site_id)`, `deals (org_id)`, a partial expression index that serves the `orgs_link_freetext_leads` trigger, and `audit_log` composites that match the admin viewer's sort. Drop four indexes no query uses. | S | Sequential scans on every deal open, dashboard load, engagement save and history page; O(N×M) cascade deletes | IDX-00…13, OPP-08/09/10, DB-1, LR-12, LF-08, G11 |
| 1.2 | **Guard `refresh_lead_next_action`.** It fires on every engagement write with no column list and does an unconditional `UPDATE leads … updated_at = now()`, which fires the leads audit diff and stage-event trigger even when nothing changed. Add `UPDATE OF lead_id, next_action, next_action_date, next_action_done` and an `IS DISTINCT FROM` guard. | S | 3 lead-row rewrites and 3 audit diffs per engagement log; N rewrites per bulk shift | TRG-A2, TRG-1 |
| 1.3 | **Default `stream_id` in the database.** A `BEFORE INSERT` trigger sets `stream_id := id` when null, so the client's second PATCH after every engagement insert disappears (three call sites). | S | 1 write per engagement, per promotion copy | TRG-A2 |
| 1.4 | **Make the audit trigger statement-level.** `audit_row_change` re-parses the request headers and builds two full jsonb documents per row. A statement-level version with transition tables produces the same `audit_log` rows with one call per statement — which is what makes bulk upserts (0.5, 2.5) cheap. Exclude `updated_at`/`last_seen_at`-only changes. | M | Per-row trigger cost on every write; audit_log/WAL growth | TRG-A1, TRG-A4, OPP-11, PW-11 |
| 1.5 | **Put the lead sweeps back in the database.** `sweepNewToWorking`/`sweepHoldWake` PATCH one lead per round trip on every register, cockpit and dashboard load. The rules are pure SQL over lead columns and settings. One `sweep_leads()` RPC (or a pg_cron job every few minutes) replaces N+M sequential writes with one call. | M | 1.4 s per due lead before the register or dashboard paints | LR-02, TRG-A3, ATT-2 |
| 1.6 | **Raise PostgREST's max rows** from 1000 to 5000 (Supabase → API settings) so ordinary tables arrive in one page. Pair with narrower selects so responses stay well under the 6 MB function limit. | S | 1 hop per extra 1000 rows in `apiGetAll` | G8 |

### Tier 2 — server-side shapes: views and RPCs (the structural fix)

The pattern behind most of the remaining depth is "download tables, join and aggregate in the browser". Each of these replaces a page's fan-out with one narrow call through the existing proxy (`/.netlify/functions/sb/rpc/<fn>` already maps to `/rest/v1/rpc/<fn>`; `Prefer` and the actor headers are forwarded, so audit attribution survives inside functions).

| # | Object | Replaces | Depth before → after | IDs |
|---|---|---|---|---|
| 2.1 | **`deal_financials` view** — per deal and stream type: TCV, margin, weighted value, first/last month, months count, grouped from `revenue_stream_months`. | Every page that embeds all month rows to sum them: opportunities register, dashboard pipeline and sector cards, revenue pipeline, reports. | Opportunities 2–3 → 1; pipeline payload from "every month row" to one row per deal | OPP-1, RPP-1, D7 |
| 2.2 | **Opportunities register as one embedded select** — `deals?select=…,organisations(name,parent_org_id,sector),stages!inner(name,category_id),sites(name),owner:people(...)` with the open-stage and owner filters in the query, plus `deal_financials`. | Whole-table deals + orgs + stages + people + sites + sectors + all months, then client filtering. | 3 → 1 | OPP-1, OPP-3, CPU-7 |
| 2.3 | **`dashboard_summary(person_id, scope)` RPC** returning one jsonb with every widget's dataset (counts by status, open actions with labels, approvals, pipeline totals from 2.1, recent milestones, interactions buckets). Interim: hoist the shared leads/deals fetches out of the widgets and `Promise.all` the chunk loops. | ~31 requests, leads ×4, deals ×5, engagement_milestones whole table. | 7–10 → 1 (interim ~3) | D5, D2, D3, D4, D6, D11 |
| 2.4 | **`lead_bundle(lead_id)` and `deal_bundle(deal_id)` RPCs** returning the row plus everything the form loads (contacts, estimates, description log, engagements with milestones and people, cadence, stage/promotion requests, red flags, strategic decisions; streams + months, collaborators, contacts, engagements, lead history). | The 8–13 sequential loaders. | 8–13 → 1 | LF-02, OPP-02 |
| 2.5 | **`promote_lead(payload jsonb)` RPC** — one transaction that creates org/people/affiliations/site/deal/collaborator/contacts/stream+months/engagement copies/promotion engagement/referrer and updates the lead. `commitPromotion` today is 13–36 sequential writes with no transaction; a mid-chain failure leaves a half-promoted lead. | The whole commit chain plus the accept-request path. | 13–36 → 1, atomic | PW-01, PW-04, PW-05, PW-06 |
| 2.6 | **`engagements_labelled` view** — engagements with lead/deal/org/person/stream labels and milestone status joined in SQL, with server-side category, date and owner filters. | Engagement History (8–18 hops), Attention, Milestones register, Internal Activity, the Activity report, the dashboard interactions widget. | 8–18 → 1–2 | EH-1, RPT-1, MIL-1, ATT-1, IA-1, D9 |
| 2.7 | **`leads_register` view** — leads with owner, source, region, branch, site, client and sector names, group touch and effective last touch computed in SQL. | 9 fetches + `_loadOrgTouches` (whole engagements scan) + ~15 `.find()` scans per row. | 2+N+M → 1; removes the O(rows×lookups) render | LR-06, LR-03, LR-05, CPU-1 |
| 2.8 | **`ownership_scope(person_id)`** function returning the owned-org, owned-person and contact-person id sets. | `_ensureOwnershipScope`'s three whole-table pulls (including the leads `contacts` jsonb column). | 2 → 1 | G1 |
| 2.9 | **`heartbeat(person_id, version)` RPC** — upsert presence and return live broadcasts in one call. | PATCH + POST fallback + GET per tick. | 2–3 → 1 | POLL-1 |
| 2.10 | **`login_context(user_id)` RPC** returned alongside the token by the `login` action in `sb.js`. | The embedded query from 0.2 plus settings and home-org members. | Sign-in → 1 browser round trip for auth and context | F2 |
| 2.11 | **Proposal Builder RPCs**: `pb_open_quote(quote_id)` (one payload for the editor), `pb_save_rate_version(version, plan)` (the ~22-write salary save in one transaction), `pb_set_post_layout(rows)`, `pb_reset_shifts(quote_id, n)`; default shifts via an `AFTER INSERT` trigger on `quote_posts`. | 15 sequential opens; 21-call shifts-per-day change; per-post layout PATCH loops; delete-then-insert allowance toggles. | 15 → 1; ~25 → 1; P → 1 | PB-01, PB-03, PB-04, PB-05, PB-06, PB-07 |
| 2.12 | **`merge_organisation(dup, keep)`** and its preview as one function each. | 10 count queries + 12 sequential writes, non-atomic. | ~15 → 1, atomic | G12 |
| 2.13 | **`sweep_leads()`** — see 1.5. | | | |

### Tier 3 — proxy and topology

| # | Change | Effort | What it does | IDs |
|---|---|---|---|---|
| 3.1 | **Pin the Netlify Functions region to the Supabase project's region** (Netlify UI → Site configuration → Functions → Region; read the Supabase region under Project Settings → General). Not expressible in `netlify.toml`. | S | Removes the second long-haul leg from every one of the 700+ call sites: roughly 100–200 ms per call and cheaper cold TLS handshakes | INF-1 |
| 3.2 | **Compress both legs.** `sb.js` sends no `Accept-Encoding` upstream and returns the raw JSON string with only `Content-Type` + CORS headers, so a 500 KB page of rows travels uncompressed across two continents. Request gzip from PostgREST, pass the gzipped body through (`isBase64Encoded`), decompress only for the `system_users` scrub. Verify first with `curl -H 'Accept-Encoding: gzip' -I` against the function. | S | 5–10× smaller bodies on every list page and preload | INF-3 |
| 3.3 | **A batch route in `sb.js`** (`POST /sb/batch` with an array of GETs, one token check, `Promise.all` over the keep-alive agent). One browser round trip and one Lambda invocation for a page's 8–16 parallel fetches instead of 8–16 cold starts. Rewrite `preloadLookups` and the big `Promise.all` fan-outs to use it. | M | Cold-start storms on first load of the day and after deploys; the reason the client throttles its own parallelism | INF-2 |
| 3.4 | **Structural option: call PostgREST directly from the browser with RLS.** Enable RLS with policies keyed on a JWT claim (Supabase Auth, or have `sb.js` mint a Supabase-signed JWT carrying `person_id` at login), keep `sb.js` only for `/auth` and the credential-scrubbed `system_users` read, and point `api()` at `…supabase.co/rest/v1/`. Removes the Lambda hop, its cold starts and invocation cost entirely; gives HTTP/2 multiplexing and gzip from Supabase's edge; the audit trigger reads the actor from `request.jwt.claims` instead of `request.headers`. This is the change that turns the 1.4 s floor into ~0.2–0.4 s. It is also an auth-model change, so it belongs in the planned rebuild rather than a patch. | L | The per-call floor itself | INF-1 |
| 3.5 | **Split rarely-used code** (Proposal Builder + HR grids 178 KB, admin pages 83 KB, Promote wizard 92 KB, Settings 52 KB, help text 52 KB, mock mode 16 KB ≈ 470 KB raw / 127 KB gzip) into separate scripts loaded on demand by page config. Functions are globals referenced from inline handlers, so plain script injection keeps them working. | L | A third of the script parsed on every load for features most sessions never open | PW-3 |

### Tier 4 — browser CPU and rendering (the "tab gets sluggish" half)

| # | Change | Effort | What it does | IDs |
|---|---|---|---|---|
| 4.1 | **Index the lookups once per render.** `renderLeadRow` does ~15 linear `.find()` scans per row over organisations/sites/people, and the sort comparator and filter pass re-run the column getters. Build `Map`s once, precompute a display record per row, make getters read fields. Same for the opportunities register, the Clients/Organisations "Group" chip (O(M²) today) and All Opportunity Contacts. Superseded by the Tier 2 views, which do the join in SQL. | S–M | Hundreds of ms to seconds of frozen UI per render/sort/filter/band click on 1,000+ row lists | CPU-1, CPU-2, CPU-7, OPP-3, LR-11, G3, D14 |
| 4.2 | **Patch, don't rebuild.** The shared table helper rebuilds every row via `innerHTML` on every sort/filter/band/lineage toggle; band toggles only need `hidden` on `tr[data-band]`. Move the repeated inline cell styles to classes. Window long lists (first 200 rows + "show more"). | M | The ~3 MB HTML string rebuilt per click on a 2,000-row register | CPU-3 |
| 4.3 | **Quote editor: optimistic, targeted re-render.** Every field edit waits for its PATCH and then rebuilds the entire editor, destroying focus and in-flight input in the next cell. Update the model first, re-render only the post, send `return=minimal`. Same for the statutory allowances grid. | M | Lost keystrokes and a 1.4 s lag per cell while building a quote | PB-02, PB-09 |
| 4.4 | **Debounce the typeaheads.** Organisation, person and site matching run the full similarity engine over every row on every keystroke, undebounced; precompute normalised names and metaphone codes once per corpus. | S | Typing stutter proportional to the size of organisations/people | LF-06, LF-07, CPU-5 |
| 4.5 | **Revenue Pipeline paint.** Rebuilds the full grid up to (FY count − 2) times per paint to find the fitting column count, recomputes deal values per cell, repaints on every raw resize event. Measure once, memoise per paint, debounce resize. | M | Hundreds of ms to seconds on open and on every toggle | RPP-2, CPU-4 |
| 4.6 | **Small hot-path fixes:** debounce the Engagement History search (full re-render of 1,000 rows per keystroke); memoise the aging-overrides `JSON.parse` per row; one shared `Intl.DateTimeFormat`; on grace-window expiry update the row instead of reloading the register from the network; `transition: all` → explicit properties on `.btn`. | S | Tens to low hundreds of ms per render | CPU-6, CPU-8, CPU-9, CPU-11, CPU-13 |

---

## 3. Suggested order

**Week 1 (Tier 0 + 1.1, 1.2, 1.3):** items 0.1–0.7, 0.11–0.15 and the index migration. No schema change beyond indexes and two trigger tweaks. Expected result: sign-in to a usable dashboard drops from ~30 s of sequential waiting to roughly 8–10 s; opening a deal, lead or quote drops to 2–3 hops; saving a forecast becomes a few seconds instead of a minute; the page download halves.

**Week 2–3 (Tier 2 core):** `deal_financials`, `engagements_labelled`, `leads_register`, `dashboard_summary`, `lead_bundle`/`deal_bundle`, `promote_lead`, `sweep_leads`, `heartbeat`. Each is independent and can ship one at a time. Expected result: every register and form is one or two round trips; the browser stops joining tables.

**Then (Tier 3 + 4):** region pinning and compression are one-afternoon infra changes that cut every remaining hop; the batch route or, in the rebuild, direct PostgREST with RLS removes the Lambda from the path. The rendering work matters most on the leads and opportunities registers and in the quote editor.

Measure before and after with the app's own instrumentation: `_bugApiBuf` already records method, table, status and milliseconds for the last 100 calls, so the request trace for any flow can be read from a bug report without extra tooling.

---

## 4. Ready-to-run SQL

The proposed migrations are in [proposed-sql/](proposed-sql/):

- `01_add_perf_indexes.sql` — Tier 1.1. Run statement by statement (CONCURRENTLY cannot run in a transaction). Idempotent. Statements that fail with "column does not exist" belong to out-of-repo migrations; skip them on that database.
- `02_engagement_triggers.sql` — Tier 1.2 and 1.3.
- `03_audit_statement_level.sql` — Tier 1.4.
- `04_heartbeat_and_sweeps.sql` — `heartbeat()` and `sweep_leads()` (Tier 2.9, 2.13).
- `05_views.sql` — `deal_financials`, `opportunities_register`, `engagements_labelled`, `org_last_touch`, `ownership_scope`, `user_context` (Tier 2.1, 2.2, 2.6, 2.8, 2.10). `leads_register`, `dashboard_summary`, `lead_bundle`, `deal_bundle` and `promote_lead` are specified in the catalogue (LR-06, D5, LF-02, PW-01) and should be written against the live schema, since several columns they need (`sites`, `deal_contacts`, `engagement_milestones`, `user_presence`) have no DDL in `sql/`.

Before touching triggers, dump what the live database actually has, because the repo is missing several migrations:

```sql
select tgrelid::regclass, tgname, pg_get_triggerdef(oid) from pg_trigger where not tgisinternal order by 1, 2;
select conrelid::regclass, conname, pg_get_constraintdef(oid) from pg_constraint where contype = 'f' order by 1;
select tablename, indexname, indexdef from pg_indexes where schemaname = 'public' order by 1, 2;
```

---

## 5. How this review was done, and what it could not check

- Fourteen reviewers each owned one slice of the code or schema and built a request trace (every round trip, marked parallel or sequential) before listing findings. Three slices (sign-in, dashboard, opportunities) were then re-read by independent adversarial verifiers; one finding was refuted and several were re-graded. The headline claims in the other slices were spot-checked directly against the code during synthesis and are marked as such in the catalogue.
- The container had no route to the live database or the deployed site, so: row counts are assumptions (people ≈ 4k from id ranges; leads and organisations in the low thousands; engagements the largest table); the Netlify function region and Supabase region are inferred from `sb.js` comments and should be confirmed in the two dashboards; compression on function responses should be confirmed with `curl`; and tables whose migrations are not in `sql/` (`sites`, `deal_contacts`, `engagement_milestones`, `lead_stage_requests`, `user_presence`, `broadcasts`, `work_projects`) are treated as unindexed.
- The 1.4 s per-hop figure is the code's own comment, not a fresh measurement. If the real figure is lower, every ratio above still holds; the ordering of the proposals does not depend on it.
