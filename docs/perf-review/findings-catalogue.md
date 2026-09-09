# Focus CRM performance review — findings catalogue

Complete list of the 176 findings produced by the 14 slice reviewers (September 2026), grouped by slice and sorted by impact. Each entry records where the problem is, why it is slow, who feels it, and the proposed fix. The ranked proposal is in [PERFORMANCE_REVIEW.md](PERFORMANCE_REVIEW.md).

**Verification key:** `verified` = an independent adversarial verifier re-read the cited lines and confirmed the claim (boot, dashboard and opportunities slices); `spot-checked` = confirmed directly against the code during synthesis; `reviewer` = reported by the slice reviewer only. No live database access was available, so row counts and the index state of tables whose migrations are not in `sql/` are stated as assumptions inside the entries.

Totals: 43 high, 71 medium, 62 low impact.


## Sign-in to first page

### F1 — Dashboard is rendered (and its ~15-20 GET fan-out executed) twice on every login because enterApp calls buildNav twice

**Impact high · effort S · other · verified (confidence 0.95)**

- **Where:** index.html 11552 (applyUserContextChrome ends with buildNav()), 11579 and 11594 (enterApp calls applyUserContextChrome then buildNav again), 5026 (buildNav → showPage(firstPage)), 3487 (showPage → loadTable(page) unawaited), 3496 (loadTable → renderDashboard)
- **Evidence:** applyUserContextChrome(): `...bar.innerHTML = ...; }\n  buildNav();\n}` (11552). enterApp(): `applyUserContextChrome();` (11579) … `await Promise.all([loadAppSettings(), ensureHomeOrgMembers()…, preloadLookups()]);\n  setEnvLabel();\n  buildNav();` (11587-11594). buildNav(): `if (firstPage) showPage(firstPage);` (5026) and firstPage is always 'dashboard' (4968). showPage(): `// Load data\n  loadTable(page);` (3487, no await, no sequence token). loadTable(): `if (page === 'dashboard') { await renderDashboard(); return; }` (3496). renderDashboard fans out: _dashApprovals 8 api call sites (12279-12373), _dashInteractions 6 (12463-12619), _dashPipeline 2, _dashRemindersHtml → _attentionLeadItems (12191). _dashWidgetsForUser (12017) reads appSettings['dashboard_role_widgets'] (12009) which is empty on the first pass; _dashInteractions line 12575 does `apiGetAll('people','select=id,first_name,last_name')` when allData.people is empty — i.e. concurrently with preloadLookups' own people load.
- **Mechanism:** Duplicate network fan-out + duplicate DOM build: the first render runs before settings/lookups exist (names render as '—', widget set falls back to defaults), then the second render throws all of it away by replacing table-body.innerHTML. There is no request-sequence guard, so a slow first render can even overwrite the correct second one. Doubles Lambda invocations and Supabase load for the most expensive page in the app, on every sign-in and every resume.
- **Who feels it:** Every user, every login/resume: the landing page loads twice, competing with the lookup preload for the same Lambda/DB capacity; visible as a dashboard that paints, flickers to 'Loading…' and paints again.

- **Fix:** Render the nav once but navigate once. Sketch: `function buildNav(navigate = true) { …; nav.innerHTML = html; if (navigate && firstPage) showPage(firstPage); }` and in applyUserContextChrome call `buildNav(false)`; keep the final `buildNav()` in enterApp (11594) as the single navigation. Optionally show a lightweight 'Loading your dashboard…' placeholder in #table-body between 11579 and 11594. Additionally add a monotonically increasing `_loadSeq` in showPage/loadTable and have renderers bail if `seq !== _loadSeq` after each await, so stale renders can never clobber the current page.

- **Verifier note:** Confirmed. index.html:11552 applyUserContextChrome ends with `buildNav();`; enterApp calls applyUserContextChrome() at 11579 and `buildNav();` again at 11594 after the Promise.all tail. buildNav always renders Dashboard first (4968) and ends with `if (firstPage) showPage(firstPage);` (5026); showPage calls `loadTable(page)` unawaited (3382) and loadTable → `await renderDashboard()` (3496). renderDashboard has no guard against an in-flight render and no sequence token, so render #1 runs with appSettings={} (dashboard_role_widgets → defaults, 12009-12012) and, on a fresh browser, even fetches `stages` itself (`if (!allData['stages']) … apiGet('stages',…)`) concurrently with preloadLookups. Fix is storage-free and trivial. Impact high is fair: the largest fan-out in the app runs twice on every sign-in/resume.

### F2 — buildUserContext is 5-6 sequential round trips of tiny lookups that a single PostgREST embedded GET (or one RPC) would return at once

**Impact high · effort S · query shape · verified (confidence 0.9)**

- **Where:** index.html 11060-11121 buildUserContext (rounds at 11063-11069, 11075-11079, 11086, 11093, 11095-11096); sql/schema.sql FKs at 2700-2788 and sql/add_branches.sql 38-46
- **Evidence:** Round 1: `await Promise.all([apiGet('system_users','id=eq.'+userId…), apiGet('user_roles',…), apiGet('system_user_regions',…), apiGet('system_user_branches',…)])`; Round 2: `await Promise.all([apiGet('people','id=eq.'+user.person_id+'&select=*'), apiGet('roles','id=in.(…)'), apiGet('role_permissions','role_id=in.(…)')])`; Round 3: `await apiGet('permissions','id=in.('+permIds…+')&select=name')`; Round 4: `await apiGet('user_permission_overrides','user_id=eq.'+userId…)`; Round 5: `await apiGet('permissions','id=in.('+ovr…)`. Every table involved has the FK PostgREST needs for embedding: user_roles_user_id_fkey/role_id_fkey, role_permissions_role_id_fkey/permission_id_fkey, system_user_regions_system_user_id_fkey, system_user_branches.system_user_id REFERENCES system_users (add_branches.sql:40), user_permission_overrides_user_id_fkey/permission_id_fkey, system_users_person_id_fkey. All tables are tiny (system_users ≈20 rows) so the DB cost is nil — the cost is 5-6 × (Lambda invoke + 2 transatlantic legs).
- **Mechanism:** Sequential proxied round trips (5, or 6 whenever the user has any override row — the code comment says one exists today). At the ~1.4 s the code itself cites per proxied GET this is 7-8 s of pure waiting before the app can even decide which nav items to show.
- **Who feels it:** Every sign-in and every session resume, every user: the blank period between clicking Sign in and the sidebar appearing.

- **Fix:**

```sql
Zero-SQL version — replace rounds 1-5 with ONE embedded query:
`apiGet('system_users', 'id=eq.'+userId+'&select=id,person_id,username,active,must_set_password,person:people(id,first_name,last_name),user_roles(roles(id,name,description,is_system,role_permissions(permissions(name)))),system_user_regions(region_id),system_user_branches(branch_id),user_permission_overrides(granted,permissions(name))')`
then flatten in JS (roles = row.user_roles.map(x=>x.roles); permissions = union of roles[].role_permissions[].permissions.name, apply overrides). The proxy's scrubCredentials only strips top-level keys, and no embedded table carries credential columns, so nothing changes in sb.js. Keep the settings + home_organisation_members GETs in the same Promise.all so total depth after auth becomes 1.
Better still (M): a SQL function `login_context(p_user_id bigint) returns jsonb` that returns user+person+roles+effective permissions+regions+branches+settings+home-org member ids, and have sb.js's 'login' action call it via sbRest and return it alongside the token — then a fresh sign-in is ONE browser round trip for auth+context, and resume calls `/rpc/login_context` once (the proxy already maps /sb/rpc/x → /rest/v1/rpc/x untouched).
```

- **Verifier note:** Confirmed line-by-line at 11063-11096: Round 1 Promise.all of 4 GETs, Round 2 Promise.all of 3, Round 3 `await apiGet('permissions'…)`, Round 4 `await apiGet('user_permission_overrides'…)` (keyed only on userId but issued after round 3), Round 5 conditional `await apiGet('permissions'…)` when any override row exists (comment says one does). Depth 5-6 sequential proxied GETs. All FKs needed for PostgREST embedding exist: schema.sql 2700/2708 (role_permissions), 2748 (system_user_regions), 2756 (system_users.person_id), 2764/2772 (user_permission_overrides), 2780/2788 (user_roles); add_branches.sql:40 inline REFERENCES system_users. scrubCredentials (sb.js:119-129) strips only top-level keys, and the proposed select names columns, so nothing leaks. Fix uses no client caching. Saves 4-5 sequential ~1.4 s hops on every login/resume → high.

### F3 — preloadLookups serialises 9 whole-table loads into 3 chunks and apiGetAll pages sequentially — the people table alone is ~5 back-to-back round trips

**Impact high · effort M · parallelise · verified (confidence 0.85)**

- **Where:** index.html 2170-2185 preloadLookups (CONCURRENCY = 4 loop), 2110-2121 apiGetAll (await inside for-loop), 2141-2151 LOOKUP_CONFIG; netlify/functions/sb.js response headers (only Content-Type + CORS are returned, Content-Range dropped)
- **Evidence:** `const CONCURRENCY = 4; for (let i = 0; i < todo.length; i += CONCURRENCY) { await Promise.all(todo.slice(i, i + CONCURRENCY).map(c => apiGetAll(c.key, c.params)…)) }` — 9 entries → chunks [regions,branches,service_major,service_sub], [lead_sources,stages,people,organisations], [sites] on a fresh browser. apiGetAll: `for (let offset = 0; ; offset += PAGE) { const page = await api(table,'GET',null, …limit=1000&offset=…); … if (page.length < PAGE) return out; }`. sb.js returns `headers: { 'Content-Type': 'application/json', ...CORS }` so PostgREST's Content-Range (which carries the total with Prefer: count=…) never reaches the browser. Volume assumption: person ids are at 4123 as of Aug 2026 (sql/usernames_password_policy.sql: `person_id = 4123`), so people ≈ 4.1k rows → 5 sequential pages; organisations and sites counts unknown (sites has no DDL in the repo).
- **Mechanism:** Sequential round trips: chunking adds 2 extra sequential hops for no benefit (Netlify functions scale per invocation; 'gentle on the proxy' buys nothing), and blind offset paging turns a 4k-row table into 5 dependent hops. Depth of the tail ≈ 1 + 5 + 1 = 7 (fresh browser) or ≈5 (hydrated), ≈7-10 s at the cited 1.4 s/hop, and it gates the real dashboard render (buildNav #2).
- **Who feels it:** Every login and resume, every user — this is the single longest stretch between 'sidebar visible' and 'dashboard has real data'. Grows linearly with people/organisation growth (each extra 1000 rows = one more sequential hop).

- **Fix:** (1) Replace the chunk loop with a single `await Promise.all(todo.map(…))`. (2) In apiGetAll fire offsets 0..K*1000 concurrently (K=4) and stop at the first short page, or forward Content-Range from sb.js (`'Content-Range': res.headers['content-range'] || ''`, plus `Access-Control-Expose-Headers`) and send `Prefer: count=estimated` on page 0 then Promise.all the rest. (3) If raising Supabase Max rows, also raise `PAGE` in apiGetAll (2111) to match, otherwise the client still pages at 1000.

- **Verifier note:** Code confirmed: preloadLookups 2178-2184 `CONCURRENCY = 4` with `await Promise.all(todo.slice(i, i+4)…)` → 9 entries = 3 sequential chunks on a fresh browser; apiGetAll 2110-2121 awaits each page in a for-loop with PAGE=1000 and no total; sb.js:301 returns only `Content-Type` + CORS so Content-Range is dropped (Prefer IS forwarded, sb.js:293, so `count=estimated` would reach PostgREST). Corrections: (a) the '≈4.1k people' figure is inferred from a single person_id=4123 in usernames_password_policy.sql, not a row count — ids can be sparse, so the exact page count is unverified (organisations/sites unknown; sites has no DDL in repo); (b) fix option (3) 'raise Supabase Max rows' does nothing on its own because apiGetAll hard-codes `PAGE = 1000` and stops when `page.length < PAGE` — the constant must be raised in step; (c) the 'speculative concurrent offsets' variant needs no proxy change and is the simplest. Impact stays high: chunking alone adds 2 guaranteed sequential hops, and any >1000-row table adds more, all gating buildNav #2.

### F4 — Whole-table select=* preloads ship dozens of columns that no page reads (organisations ≈45 columns, ~30 of them read 0-4 times in the entire app)

**Impact medium · effort M · payload · verified (confidence 0.8)**

- **Where:** index.html 2141-2151 LOOKUP_CONFIG (`{ key: 'people', params: 'select=*' }`, `{ key: 'organisations', params: 'select=*' }`, `{ key: 'sites', params: 'select=*' }`); sql/add_org_detail_fields.sql 5-44 (adds ~30 text columns); sql/schema.sql people/organisations definitions
- **Evidence:** Column-usage census over index.html (`.col`/`['col']` occurrences): organisations — legal_form 0, registration_no 0, vat_no 0, tax_reference_no 0, bbbee_level 0, bbbee_expiry 0, payment_terms 0, credit_limit 0, postal_line1-4 0, postal_code 0, physical_line2-4 0, physical_code 0, province 0, country 0, switchboard_tel 0, general_email 0, account_no 1, trading_name 2, client_since 2, is_client 2, physical_line1 4 (all inside the org detail form). Read broadly: name 396, region_id 39, legal_name 39, notes 37, active 36, sector_id 17, website 13, parent_org_id 9, home_organisation 8, client_status 7. people: initials 0 (only the People admin grid), title/email/phone used by profile/contact views only; names everywhere. sites: only name (23), organisation_id (13), address (8), active (3) are read. Note also 'notes' (free text) and 'legal_name' are shipped for every org row on every login. Comment at 2130-2131 states the caches are 'fetched with select=* so any caller gets a superset of what it needs' — so callers must be audited before narrowing.
- **Mechanism:** Over-fetch bytes on every login (and on every cache invalidation after a write to these tables — api() line ~2093 `_lkInvalidate(table)` nulls the cache and the next page reloads the whole table). Payload scales as rows × ~45 columns for organisations; the JSON must also be transferred edge→Lambda→browser and JSON.parse'd on the client.
- **Who feels it:** Every login/resume; larger on mobile/PWA connections. Secondary: bigger JSON.parse and larger allData arrays that the pages then linearly `.find()` over.

- **Fix:** Narrow the preload selects to the columns the app actually reads, e.g. LOOKUP_CONFIG: people → `select=id,first_name,last_name,title,email,phone`; organisations → `select=id,name,legal_name,trading_name,active,home_organisation,is_client,client_status,sector_id,region_id,parent_org_id,website,notes`; sites → `select=id,name,organisation_id,address,active`. Have the org detail form (the only reader of the ~30 detail columns) fetch its own row with select=* on open. Longer-term, expose Postgres views `people_lookup (id, first_name, last_name, full_name)` and `organisations_lookup (…)` and point LOOKUP_CONFIG at them so the column list is enforced server-side (`CREATE VIEW people_lookup AS SELECT id, first_name, last_name, title, email, phone FROM people;`).

- **Verifier note:** Column census spot-checked: `.legal_form|['legal_form']` 0, registration_no 0, vat_no 0, bbbee_level 0, postal_line1 0, switchboard_tel 0, general_email 0, physical_line1 3, trading_name 2, is_client 2, client_since 1, people.initials 0; sites reads only name(25)/organisation_id(9)/address(8)/active(5). The detail columns are read only generically through ORG_DETAIL_FIELDS keys (2536-2560), and the Organisations/Clients register pages fetch their own rows with `apiGetAll(cfg.table,'select=*…')` (loadTable ~3560) before opening the form, so narrowing LOOKUP_CONFIG does not starve the form. Caveat for implementation: the ~30 `allData['organisations'].find(...)` call sites and code like 17034 that pushes a freshly fetched full row into the cache should be re-checked, but none read the detail columns. Fix uses server-side views/select lists, no client caching. Medium impact is fair (payload only; real size unknown).

### F5 — 2.2 MB single-document bundle: 480 KB of render-blocking base64 logos (1295×1467 px PNGs shown at ≤200 px) plus 1.5 MB of unminified JS parsed on every load

**Impact medium · effort M · payload · verified (confidence 0.85)**

- **Where:** index.html 25 (--focus-wordmark, 325,088 base64 chars ≈ 238 KB), 26 (--focus-logo-white, 156,624 chars ≈ 114 KB), 682 (63 KB PNG <img>), 214/634 (SVG data URIs ≈ 7 KB); 635 (login logo, 178×200 box) and 695 (sidebar logo, 159×90 box); script 1494-28145 = 1,523,764 bytes; netlify.toml build command (sed + version.txt only, no minification)
- **Evidence:** `wc -c index.html` = 2,218,069; gzip = 850,068. CSS region 16-625 = 543,360 bytes, of which lines 25-26 are two `url("data:image/png;base64,…")` custom properties; both PNG headers decode to 1295×1467 px. Line 635: `<div class="brand-wordmark" … style="height:200px;width:178px…">` (login), line 695: `…background-image:var(--focus-logo-white);background-size:159px auto…` (sidebar). JS: 3,184 comment lines, 1,680 blank lines, no minifier in netlify.toml (`command = "sed -i … index.html && grep … > version.txt"`). Netlify serves HTML with max-age=0, must-revalidate, so even a 304 re-parses the whole document.
- **Mechanism:** Payload + client CPU on the critical path to first paint: the <style> block must be fully parsed before the login screen paints, and the 1.5 MB script must be downloaded, parsed and compiled before the Sign in button is wired (init() runs at the end of the script). Base64 inflates the images by 33 % and defeats progressive decoding.
- **Who feels it:** Every page load for every user, before they can even type a password; worst on the Android/iOS PWA installs the app actively promotes (install guide at ~10900) where 1.5 MB of JS compile is 2-4 s.

- **Fix:** (1) Export the two logos at 2× display size (≈360 px wide, ~15-25 KB each as PNG or a few KB as SVG) into /icons/ and reference them as `--focus-wordmark: url(/icons/wordmark.png)` / `url(/icons/logo-white.png)`; same for the 63 KB image at line 682. Removes ~480 KB from the render-blocking style block. (2) Minify at build time without changing the source: in netlify.toml run a small Node step that extracts the <script> body, runs esbuild/terser (`npx esbuild --minify --target=es2020`) and writes the minified page to the publish dir (keeping /version.txt logic). Expect ~40-50 % fewer bytes to parse and ~350 KB less over the wire. (Not proposing any caching/splitting — pure byte reduction.)

- **Verifier note:** All numbers verified: `wc -c` = 2,218,069, gzip 850,068; lines 25/26 are 325,138 and 156,676 chars of base64 PNG, both decode to 1295×1467 px; line 682 is 87 KB (not 63 KB, slightly understated); login box 178×200 (635) and sidebar `background-size:159px` (695); script region 1494-28147 = 1,523,780 bytes; CSS 16-625 = 543,360 bytes; netlify.toml build command is sed + version.txt only. Fix is pure byte reduction, no caching. Effort re-graded to M because the minify step needs a Node build script wired into netlify.toml (and must run after the existing sed/version.txt stamping); the image export alone is S. Impact medium (per page load, not per proxied call).

### F6 — Every data call crosses the Atlantic twice: Netlify Lambda (default us-east-2) sits between South African users and a Supabase project on another continent

**Impact medium · effort S · proxy infra · verified (confidence 0.6)**

- **Where:** netlify/functions/sb.js 8-11 (sbAgent comment: 'every proxied query opened a fresh cross-Atlantic TLS handshake (~the bulk of the per-call latency)'), 219-259 (handler proxies every request); netlify.toml (no functions region/config); index.html ~3617 loadTable comment ('a ~1.4s proxied round-trip')
- **Evidence:** sb.js: `const sbAgent = new https.Agent({ keepAlive: true, keepAliveMsecs: 30000, maxSockets: 64 });` with the comment quoted above — i.e. the function and the database are on different continents. netlify.toml has no `[functions]` region setting, so the function runs in Netlify's default AWS region (us-east-2). The client-side comment measures ~1.4 s per proxied GET. Parallel bursts (4 at buildUserContext R1, 6-9 at preloadLookups, ~15-20 per dashboard render) fan out across multiple Lambda instances, each with its own cold start and its own empty keep-alive pool, so the first call on every new instance pays a full TLS handshake again. The Supabase project region is not recorded anywhere in the repo.
- **Mechanism:** Network topology: browser(ZA) → Netlify edge → Lambda(US) → Supabase(EU/ZA?) and back = 2 intercontinental crossings + Lambda invoke overhead per call, multiplied by the 13-14 sequential hops in the login path. Also Lambda cold-start amplification on parallel bursts.
- **Who feels it:** Every proxied call in the app (every page, every save), for every user — this is the multiplier that turns 'a dozen small queries' into 15-20 s logins.

- **Fix:** Set the Netlify Functions region to the Supabase project's AWS region (S). Treat direct-to-Supabase reads as a separate L security project: it needs RLS policies on every table (all currently GRANT ALL TO anon) plus a Supabase-signed JWT, before any anon key can ship to browsers.

- **Verifier note:** sb.js:7-11 comment ('fresh cross-Atlantic TLS handshake') and the ~1.4 s/round-trip comments (index.html 3546, 7052, 19685, 22769) support that Lambda and Supabase sit on different continents; netlify.toml has no functions region, and verifyToken (sb.js:76-88) is local HMAC so there is no extra DB call per request. But the Supabase region is not in the repo, so the size of the win from fix (1) is unverifiable — re-graded to medium (per-hop latency, not removal of hops; nil if the regions already match). Fix (2) is under-scoped: every table is `GRANT ALL … TO anon` (e.g. add_branches.sql:48) and the app relies on the service key; letting browsers hold the anon key requires enabling RLS on every table, not just column REVOKEs — that is an L security rework, not M. Keep (1) as the actionable S item.

### F7 — Presence/broadcast poll is 2-3 proxied calls per tick (PATCH-then-POST upsert + GET) and its first tick fires 8 s after load, inside the login burst

**Impact low · effort S · polling · verified (confidence 0.9)**

- **Where:** index.html 1601-1641 broadcastTick, 1640-1642 (setInterval 60 s, setTimeout 8 s, visibilitychange)
- **Evidence:** `const r = await api('user_presence','PATCH', beat, 'person_id=eq.'+…+'&select=person_id'); if (!r || !r.length) await api('user_presence','POST', …);` then `await apiGet('broadcasts','ended_at=is.null&expires_at=gt.…&select=*&order=created_at.desc')`. Scheduled by `setInterval(broadcastTick, BCAST_POLL_MS); setTimeout(broadcastTick, 8000); document.addEventListener('visibilitychange', …broadcastTick())`. broadcasts has no index on (ended_at, expires_at) (index_inventory.txt) but is tiny.
- **Mechanism:** Polling: 2-3 Lambda invocations + Supabase writes per minute per open tab (≈3-4k invocations/day per user), and a burst that competes with the login/dashboard fan-out at t+8 s. The PATCH→POST pair is a sequential pair where one upsert would do.
- **Who feels it:** Low per tick, but it is a permanent background tax on the same Lambda/DB path every page uses, and each tab-focus adds another 2-3 calls just as the user starts interacting.

- **Fix:** (1) One request instead of three: a SQL function `heartbeat(p_person_id bigint, p_version text) returns setof broadcasts` that does `INSERT INTO user_presence … ON CONFLICT (person_id) DO UPDATE SET last_seen_at=now(), app_version=…` and returns live broadcasts; call via `api('rpc/heartbeat','POST',{p_person_id, p_version})`. If you'd rather avoid SQL: POST user_presence with `Prefer: resolution=merge-duplicates` (PostgREST upsert; needs a unique constraint on person_id) and run it in Promise.all with the broadcasts GET. (2) Start the first tick from the end of enterApp instead of a fixed 8 s timer, and consider 120-300 s for the interval (presence 'active' window is already 3 min — BCAST_ACTIVE_MIN). (3) Add `CREATE INDEX broadcasts_live_idx ON broadcasts (expires_at) WHERE ended_at IS NULL;` only if the table ever grows beyond a few hundred rows.

- **Verifier note:** Confirmed at 1606-1641: PATCH user_presence, conditional POST when 0 rows, then GET broadcasts; `setInterval(broadcastTick, 60000)`, `setTimeout(broadcastTick, 8000)`, and visibilitychange. index_inventory.txt (28 lines) has no broadcasts/user_presence index, and there is no user_presence DDL anywhere in sql/, so the unique constraint required by the merge-duplicates fallback is unverified (the finding correctly flags it). Trace correction: broadcastTick returns immediately when currentUser is unset (1602), so the 8 s tick only lands inside the login burst if sign-in completed within 8 s of load; before login it is a no-op, not 2-3 calls. Impact low is right.

### F8 — A dedicated 'env' Lambda call on every page load just to label the login card, when the 'login' response could carry the same value

**Impact low · effort S · query shape · verified (confidence 0.9)**

- **Where:** index.html 28133 init() → 1652-1658 loadEnvironment(); netlify/functions/sb.js handleAuth 'env' branch (`sbRest(key,'GET','/settings?key=eq.environment&select=value')`); loadAppSettings 27209-27214 re-reads settings (select=*) after login anyway
- **Evidence:** `async function loadEnvironment() { try { const r = await authCall({ action: 'env' }); if (r && r.environment) appSettings['environment'] = r.environment; } … }` is called unawaited from init() on every load (and on resume runs concurrently with enterApp's 4-call burst). After login, `loadAppSettings()` fetches the whole settings table including the same row.
- **Mechanism:** One redundant Lambda invocation + Supabase GET per page load (and per resume), duplicated by loadAppSettings ~2 s later.
- **Who feels it:** Every load; small on its own, but on resume it is one more concurrent invocation in the cold-start burst.

- **Fix:** Return `environment` from the 'login' and 'set' replies in sb.js (`sbRest` the settings row inside the same invocation, or better, include it in the login_context RPC from F2) and call setEnvLabel() from doLogin; on resume, take it from loadAppSettings (already fetched). Keep the pre-login 'env' call only if the label must show before sign-in — in that case bake the environment label into the build (netlify.toml already substitutes __BUILD_BRANCH__; add an ENVIRONMENT placeholder) so no call is needed at all.

- **Verifier note:** Confirmed: init() (28133) calls loadEnvironment() unawaited; loadEnvironment (1652-1658) → authCall({action:'env'}) → sb.js:152-157 one sbRest GET on settings; loadAppSettings (27208-27211) re-reads `settings?select=*` after login. One redundant invocation per load/resume. Note the code comment at 1644-1647 says the environment label is deliberately DB-driven ('NOT from the code or hostname'), so the 'bake into the build' variant contradicts a stated design decision — the 'return it from login / take it from loadAppSettings on resume' variant is the one to use. Impact low, effort S.


## Dashboard

### D1 — Reminder banner is a serial 2-round-trip gate in front of the whole dashboard (nothing paints until it finishes)

**Impact high · effort S · parallelise · verified (confidence 0.95)**

- **Where:** index.html:12229-12252 renderDashboard (`const remindersHtml = await _dashRemindersHtml();` at 12231, body.innerHTML with the widget shell only at 12241); _attentionLeadItems 12139-12152 (leads fetch 12140 -> sweepHoldWake 12142 -> _loadOrgTouches 12147, each awaited in turn)
- **Evidence:** 12231 `const remindersHtml = await _dashRemindersHtml();` precedes the shell paint at 12241-12252 and the widget Promise.all at 12266. Inside, 12140 `const leads = await apiGet('leads', 'select=id,owner_id,...,sites(name)')`, then 12142 `await sweepHoldWake(leads)` (23492-23511: `for (const l of due) { ... await api('leads','PATCH',...) }`), then 12147 `await _loadOrgTouches()` (14286-14299: `apiGet('engagements','org_id=not.is.null&select=org_id,engagement_date,work_mode')`).
- **Mechanism:** Two whole-table fetches (leads, engagements) plus 0..N PATCHes run strictly in series, and the widget grid is not even inserted into the DOM until they return. Every widget's own waterfall starts only after this phase.
- **Who feels it:** Every user on every login (dashboard is the landing page), plus every scope switch / drag / reset / dismiss / engagement-save re-render. The page is blank for >= 2 round trips (~2.8 s) before 'Loading…' cards appear, and the total critical path is lengthened by exactly that much.

- **Fix:** 1) Paint the shell first: move lines 12241-12252 above the reminders await and add `<div id="dash-reminders"></div>` in place of `${remindersHtml}`; then run the banner as one more entry in the Promise.all: `_dashRemindersHtml().then(h => { const r = document.getElementById('dash-reminders'); if (r) r.innerHTML = h; })`. 2) Inside _attentionLeadItems run the leads fetch and _loadOrgTouches concurrently: `const [leads] = await Promise.all([apiGet('leads', ...), _loadOrgTouches()]); await sweepHoldWake(leads);`. 3) Make sweepHoldWake fire its PATCHes with `await Promise.all(due.map(...))` instead of for..await (they are independent rows). Net: 2 sequential RTs off the critical path, first paint immediate.

- **Verifier note:** Confirmed. index.html:12231 `const remindersHtml = await _dashRemindersHtml();` runs before `body.innerHTML = ...` at 12241 (grid shell + Loading cards) and before the widget Promise.all at 12266. _attentionLeadItems (12139-12147) awaits apiGet('leads', 25 cols) -> sweepHoldWake (23492-23511: for..await PATCH per due Hold lead) -> _loadOrgTouches (14286-14299: whole engagements scan) strictly in series. Fix is pure reordering/parallelising, no caching. One correction: _loadOrgTouches is memoised in allData['_org_touches'] for the session (14287), so re-renders (scope switch/drag/dismiss) pay 1 blocking RT (leads), not 2; first landing pays 2 (+PATCHes). Still >=2 sequential proxied RTs in front of any paint on every login -> high stands.

### D11 — Approvals widget chains 5-8 dependent round trips although the SM block and the Executive block are independent and the leads table is only needed as a label join

**Impact high · effort S · query shape · verified (confidence 0.85)**

- **Where:** index.html:12291 (leads whole-table), 12301-12304 (promos/stage requests), 12318 (pending milestones), 12320-12329 (_milLookups + chunk loops), 12341-12346 (red_flags lookup then lead_red_flags) — each `await` after the previous
- **Evidence:** 12291 `const leads = await apiGet('leads', ...)` is used only via `leadById[+r.lead_id]` for labels (12308, 12315, 12334, 12350). 12343-12344 `if (!rfLookup) { rfLookup = await apiGet('red_flags', 'select=id,name'); allData['red_flags'] = rfLookup; }` then 12346 `const flags = await apiGet('lead_red_flags', ...)` — both independent of the SM block above but executed after it. Admin satisfies both isSM (12281) and isExecutive (11339-11341: `currentUser.isAdmin || ...`), so Admin pays the full chain.
- **Mechanism:** Extra sequential round trips: depth 5 (no pending milestones) or 8 (with) where 1-2 would do; plus a whole-table leads payload for a handful of labels.
- **Who feels it:** Admin, Sales Manager and Executive landings (approvals is first in their widget lists, 11981-11983); it is typically the longest widget chain and therefore sets the dashboard's total time.

- **Fix:** Run the four sources concurrently with parents embedded, no leads table fetch: `const [promos, stageReqs, pend, flags] = await Promise.all([ apiGet('promotion_requests', 'status=eq.pending&select=lead_id,request_type,requested_by,requested_at,leads(id,target_org_name,description,site_id,site_name,sites(name))'), apiGet('lead_stage_requests', 'status=eq.pending&request_type=eq.dead&select=lead_id,requested_by,requested_at,leads(id,target_org_name,description,site_id,site_name,sites(name))'), isSM ? apiGet('engagement_milestones', 'status=eq.pending&select=id,milestone_type_id,proposed_by,proposed_at,engagements(lead_id,deal_id,leads(id,target_org_name,description,site_id,site_name,sites(name)),deals(id,name))&order=proposed_at.asc&limit=100') : [], exec ? apiGet('lead_red_flags', 'review_status=eq.pending&cleared=eq.false&select=lead_id,red_flags(name),leads!inner(id,status,target_org_name,description,site_id,site_name,sites(name))&leads.status=not.in.(Dead,Promoted)') : [] ]);` plus `_milLookups()` in the same Promise.all. Depth 1 (2 if the milestone-type names must be resolved after). Requires FKs promotion_requests.lead_id/lead_stage_requests.lead_id/lead_red_flags.lead_id -> leads (lead_red_flags_lead_id_fkey exists, schema.sql:2484; the other two are assumed from their migrations).

- **Verifier note:** Confirmed chain: leads 12291 -> Promise.all(promos, stageReqs) 12301-12304 -> pend 12316 -> _milLookups 12318 -> eng chunk 12323 -> deal chunk 12328 -> red_flags 12343 -> lead_red_flags 12346, each awaited after the previous; isExecutive() includes isAdmin (11339-11341), so Admin runs both blocks: depth 5 with no pending milestones, 8 with. FK check for embeds: promotion_requests.lead_id -> leads exists (add_promotion_requests.sql:31), lead_red_flags.lead_id and red_flag_id exist (schema.sql:2484, 2492); lead_stage_requests has NO DDL anywhere in sql/ so its FK is unverified. Re-graded to high: Approvals is the deepest chain for SM/Admin and therefore sets the dashboard's total; the fix removes >=2 (typically 4-7) sequential RTs from that critical path.

### D3 — Sequential `for..await` id=in.(150) chunk loops instead of PostgREST resource embedding — 4 widgets pay ceil(n/150) extra serial round trips each

**Impact high · effort S · query shape · verified (confidence 0.9)**

- **Where:** index.html:12323-12329 (_dashApprovals: engagements then deals chunks), 12511-12514 and 12520-12524 (_dashInteractions: leads, deals, deals chunks), 12820-12822 (_dashMilestones: engagements chunk), 24980-24982 (_dashMilestonePulse: engagements chunks)
- **Evidence:** 12324-12325 `for (let i = 0; i < engIds.length; i += 150) (await apiGet('engagements', `id=in.(${engIds.slice(i, i + 150).join(',')})&select=id,lead_id,deal_id`)).forEach(...)`; 12520-12524 `for (let i = 0; i < dealIds.length; i += 150) { ... (await apiGet('deals', `id=in.(${chunk.join(',')})&select=id,stage_id,service_sub_id`)) ... }`; 24980-24982 same pattern. Each iteration awaits before the next starts. The FKs needed for embedding exist: engagements.deal_id -> deals (schema.sql:2412), engagements.lead_id -> leads (unify_engagements.sql:31-33); engagement_milestones.engagement_id -> engagements is assumed (its DDL, sql/add_engagement_milestones.sql, is referenced by the code but absent from the repo).
- **Mechanism:** Extra sequential round trips: for n distinct ids the loop costs ceil(n/150) serial proxied calls (~1.4 s each), and then a further fetch for the parents of those rows. The JOIN is being done in the browser one page at a time when PostgREST can do it server-side in the original query.
- **Who feels it:** Milestone Pulse and Approvals scale with the total number of milestones ever recorded (Pulse: every milestone, all-time); Interactions scales with distinct deals engaged in the period (own scope: also leads). With ~300 distinct deals in the window the Interactions card alone adds 2 serial RTs (~2.8 s); with 1,000 milestones Pulse adds 7 (~10 s). Felt on every dashboard load and every Wk/Mo or Mine/All toggle (_dashReloadInteractions 12448).

- **Fix:** Replace each chunk loop + parent fetch with one embedded select on the driving table. Examples: Milestones/Pulse/Approvals: `apiGet('engagement_milestones', 'status=eq.approved&select=id,milestone_type_id,decided_at,engagements(id,lead_id,deal_id,engagement_date,leads(id,owner_id,branch_id,region_id,target_org_name,description),deals(id,name,owner_id,branch_id,region_id))&order=decided_at.desc.nullslast&limit=80')`. Interactions: `apiGetAll('engagements', 'engagement_date=gte.' + fromIso + '&select=id,lead_id,deal_id,engagement_date,engagement_type,created_by,deals(stage_id,service_sub_id,owner_id),leads(owner_id)')` — the own-scope test becomes `e.created_by===me || e.leads?.owner_id===me || e.deals?.owner_id===me` with no lookups at all, and catOf reads `e.deals.stage_id`. Where a loop must stay, at minimum `await Promise.all(chunks.map(c => apiGet(...)))` collapses depth to 1.

- **Verifier note:** Confirmed loops: 12323-12329 (engagements then deals, for..await), 12511-12514 and 12520-12524 (leads, deals, deals — three sequential passes for own scope), 12820-12822, 24980-24982. FKs for the proposed embeds exist: engagements.deal_id (schema.sql:2412), engagements.lead_id (unify_engagements.sql:31-32), leads.site_id (already embedded today); engagement_milestones.engagement_id FK is assumed (no DDL in repo). Correction: Approvals (limit=100) and Recent Milestones (limit=80) can never exceed one chunk, so the loop there costs the same as a single parent fetch — the extra serial RTs come only from Pulse (all-time, D4) and Interactions (depth 4 in own scope: engs -> lead chunks -> deal chunks -> deal chunks again; the reviewer's Interactions trace says depth 2, it is 4 for a Sales User). High stands on the strength of those two widgets.

### D4 — Milestone Pulse downloads every engagement_milestones row ever (select=*, all statuses, paged) plus all their parents to produce three counters

**Impact high · effort M · db view or rpc · verified (confidence 0.9)**

- **Where:** index.html:24974 `rows = await apiGetAll('engagement_milestones', 'select=*');` then 24978-24988 parent fetches; counting loop 24997-25012 only uses status, engagement_date/decided_at month (this month / last month) and pending
- **Evidence:** 24974 `rows = await apiGetAll('engagement_milestones', 'select=*');` (no status or date filter; apiGetAll pages 1000 at a time in series). 25001-25011: `if (m.status === 'pending') { pending++; continue; } if (m.status !== 'approved') continue; const month = ...slice(0,7); if (month === thisM) {...} else if (month === lastM) cntLast++;` — everything older than last month and every declined row is fetched then discarded. 24985-24988 puts ALL distinct lead/deal ids into one unchunked `id=in.(...)` URL.
- **Mechanism:** Whole-table pull (grows forever) + ceil(M/150) serial engagement chunks + 2 parent fetches to compute 3 integers and a top-4 group breakdown. Also an unbounded URL (`leads?id=in.(<every lead id with a milestone>)`) that will eventually exceed proxy/PostgREST URL limits.
- **Who feels it:** Sales User and Sales Manager dashboards (milestone_pulse is in both default widget lists, 11980-11981). Cost rises linearly with milestone history: today ~4 serial RTs, later 4 + pages + chunks.

- **Fix:** Interim (no schema change): two filtered embedded reads in parallel — `pending`: `engagement_milestones?status=eq.pending&select=id,engagements!inner(lead_id,deal_id,leads(owner_id,branch_id,region_id),deals(owner_id,branch_id,region_id))`; `recent approved`: same select with `status=eq.approved&engagements.engagement_date=gte.<first day of last month>` using `engagements!inner(...)` so the date filter applies to the parent. Endgame: a view that returns the counts already grouped so scope filtering is a small client-side sum: `create view v_milestone_month_counts as select date_trunc('month', coalesce(e.engagement_date, m.decided_at::date)) as month, m.status, mt.group_id, coalesce(l.owner_id, d.owner_id) owner_id, coalesce(l.branch_id, d.branch_id) branch_id, coalesce(l.region_id, d.region_id) region_id, count(*) n from engagement_milestones m join engagements e on e.id = m.engagement_id left join leads l on l.id = e.lead_id left join deals d on d.id = e.deal_id left join milestone_types mt on mt.id = m.milestone_type_id group by 1,2,3,4,5,6;` then `apiGet('v_milestone_month_counts', 'or=(status.eq.pending,month.gte.<last month>)')` — one round trip, tens of rows.

- **Verifier note:** Confirmed: 24974 `apiGetAll('engagement_milestones','select=*')` with no status/date filter, 24980-24982 sequential 150-id engagement chunks, 24985-24988 unchunked `id=in.(all lead ids)` / `id=in.(all deal ids)` URLs; the counting loop 24997-25012 uses only status and month. Depth 4 (milLookups -> milestones pages -> eng chunks -> leads/deals) collapses to 1 with either fix. Interim embedded query needs the assumed engagement_milestones.engagement_id FK; `engagements!inner(...)&engagements.engagement_date=gte.X` is valid PostgREST. View SQL is sound (engagement_date is `date`, schema.sql:437). Widget in both Sales User and Sales Manager defaults (11980-11981). High stands; note today's milestone table is probably small (feature is recent), the cost is mostly the serial depth.

### D5 — One dashboard RPC would replace the ~31-request / 7-10-deep waterfall with a single proxied GET

**Impact high · effort L · db view or rpc · verified (confidence 0.85)**

- **Where:** index.html:12266-12272 renderDashboard Promise.all over 10-13 loaders; every loader does its own fetch+join+aggregate in the browser (12279-12864, 24968-25041)
- **Evidence:** All widget outputs are aggregates or short top-N lists over the same handful of tables (leads, deals, engagements, engagement_milestones, revenue_streams/months, promotion_requests, lead_stage_requests, lead_red_flags, research_campaigns, bug_reports) filtered by a scope rule that is pure SQL (12070-12075 _dashInScope: owner_id = me, or region_id/branch_id in the user's lists, or all). The proxy already forwards any path under /rest/v1 unchanged (netlify/functions/sb.js: `const path = event.path.replace('/.netlify/functions/sb', '/rest/v1')`), so `apiGet('rpc/dashboard_snapshot', 'p_person=..&p_scope=..')` works today with no proxy change; a GET (not POST) keeps the proxy's GET retry and passes the read-only write guard at api() 2038-2043.
- **Mechanism:** Round-trip count and depth: every widget pays at least one proxied hop (~1.4 s) and several pay 3-8 in series; the DB work behind each hop is milliseconds. Collapsing to one STABLE SQL function keeps the joins/aggregations in Postgres and returns one small JSON document.
- **Who feels it:** Every user, every landing and every re-render: ~10-14 s -> ~1.5-2 s. Also removes the O(rows) JSON parsing and the client-side joins for all widgets.

- **Fix:** `create or replace function dashboard_snapshot(p_person bigint, p_scope text, p_regions bigint[] default '{}', p_branches bigint[] default '{}', p_from date default (current_date - 84)) returns jsonb language sql stable as $$ with sl as (select * from leads l where p_scope='all' or l.owner_id=p_person or (p_scope='team' and (l.region_id = any(p_regions) or l.branch_id = any(p_branches)))), sd as (select * from deals d where p_scope='all' or d.owner_id=p_person or (p_scope='team' and (d.region_id = any(p_regions) or d.branch_id = any(p_branches)))), open_stage as (select id from stages where name in ('Prospect','Proposal','Negotiation')), tot as (select s.deal_id, sum(m.opportunity_revenue) filter (where s.stream_type='opportunity') opp, sum(m.secured_revenue) filter (where s.stream_type='fulfilment') sec from revenue_streams s join revenue_stream_months m on m.stream_id=s.id where s.deal_id in (select id from sd) group by s.deal_id) select jsonb_build_object( 'lead_status', (select coalesce(jsonb_object_agg(status,n),'{}') from (select status, count(*) n from sl group by status) x), 'lead_overdue', (select count(*) from sl where next_action_date < current_date and status in ('New','Working','Nurture','Qualified')), 'opps_by_stage', (select coalesce(jsonb_object_agg(stage_id,n),'{}') from (select stage_id, count(*) n from sd where stage_id in (select id from open_stage) group by stage_id) x), 'pipeline', (select jsonb_build_object('n',count(*),'total',coalesce(sum(t.opp),0),'weighted',coalesce(sum(t.opp*coalesce(d.probability,0)/100.0),0)) from sd d left join tot t on t.deal_id=d.id where d.stage_id in (select id from open_stage)), 'actions', (select coalesce(jsonb_agg(a order by a.next_action_date),'[]') from (select distinct on (coalesce(e.stream_id::text,'e'||e.id)) e.id, e.next_action, e.next_action_date, e.lead_id, e.deal_id, coalesce(l.target_org_name, l.description, d.name) label from engagements e left join sl l on l.id=e.lead_id left join sd d on d.id=e.deal_id where e.next_action_done=false and e.next_action_date is not null and (l.id is not null or d.id is not null) order by coalesce(e.stream_id::text,'e'||e.id), e.engagement_date desc, e.id desc) a), 'interactions', (select coalesce(jsonb_agg(i),'[]') from (select date_trunc('week', e.engagement_date)::date wk, case when e.lead_id is not null then 'Outreach' when d.stage_id in (5,7,8) then case when ss.is_recurring=false then 'Project' else 'Contract' end else 'Sales' end cat, e.created_by, count(*) n from engagements e left join deals d on d.id=e.deal_id left join service_sub ss on ss.id=d.service_sub_id left join leads l on l.id=e.lead_id where e.engagement_date >= p_from and (p_scope<>'own' or e.created_by=p_person or l.owner_id=p_person or d.owner_id=p_person) group by 1,2,3) i), 'campaigns', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'status',status,'owner_id',owner_id,'created_by',created_by)),'[]') from research_campaigns where status='Active'), 'bugs', (select jsonb_build_object('open',count(*) filter (where status in ('New','Acknowledged')),'blocking',count(*) filter (where status in ('New','Acknowledged') and severity='Blocking'),'week',count(*) filter (where created_at >= now()-interval '7 days')) from bug_reports) ) $$;` Add sub-objects for approvals (pending promotion_requests / lead_stage_requests / lead_red_flags joined to leads) and milestones (D4's grouped query) the same way. Client: `const snap = await apiGet('rpc/dashboard_snapshot', `p_person=${me}&p_scope=${scope}&p_regions={${regions}}&p_branches={${branches}}&p_from=${fromIso}`)` and have each loader render from `snap.<key>`. Keep the 1.4 s single hop; drop the other ~30.

- **Verifier note:** Feasible: sb.js:253 rewrites any path to /rest/v1, so `apiGet('rpc/dashboard_snapshot', ...)` reaches PostgREST's GET /rpc endpoint; api() only blocks non-GET for read-only users (2038-2043); PostgREST accepts `p_regions={1,2}` text for bigint[]. Depth claim is fair: SM path is pre-phase 2 + approvals 6 = ~8 sequential hops. Caveats for the SQL as written: (a) `interactions` groups away engagement_type, so the `interactions_count_promotion=false` setting (12502) cannot be applied client-side — keep engagement_type or add a p_count_promo flag; (b) it only buckets by ISO week; the Mo toggle needs a p_period; (c) `secured_revenue` is absent from sql/schema.sql (which has fulfilment_revenue) but exists on live per the code comment at 12676 and reimport_contracts_march2026.sql — verify before deploying. Effort L, impact high stand.

### D10 — Cosmetic actions (drag-reorder, reset layout, scope switch, reminder dismiss, engagement save) re-run the entire ~31-request waterfall with no in-flight cancellation

**Impact medium · effort S · dom render · verified (confidence 0.9)**

- **Where:** index.html:12054 dashSetScope, 12110 dashDrop, 12114 dashResetLayout, 12215 dismissWokeReminder, 26206/26319/26327/26340 (engagement modal save paths) — all call renderDashboard(); renderDashboard 12219 has no render token/abort
- **Evidence:** 12101-12111 dashDrop: computes the new order, `localStorage.setItem(...)` then `renderDashboard();` — a pure DOM reorder triggers every widget's fetches again. 12266 `await Promise.all(widgets.map(async w => { ... el.innerHTML = await loaders[w]() ...}))` writes into `dash-<w>` by id, so two overlapping renders (e.g. two quick scope clicks) race and the slower one overwrites.
- **Mechanism:** Redundant network work (full waterfall, ~31 proxied calls, 7-10 deep) for actions that need none, and duplicated concurrent waterfalls when the user clicks again before the first finishes.
- **Who feels it:** Anyone who rearranges cards, toggles Mine/Team/All, dismisses a reminder, or logs an engagement from the dashboard — each waits the full ~10 s again; overlapping clicks double the proxy load.

- **Fix:** dashDrop/dashResetLayout: reorder DOM nodes instead of re-rendering: `const grid = document.getElementById('dash-' + order[0]).parentElement; order.forEach(w => grid.appendChild(document.getElementById('dash-' + w)));`. dashSetScope: reload only scope-aware widgets (actions, leads, opportunities, pipeline, sector_value, campaigns, milestones, milestone_pulse, interactions) into their existing cards; leave bugs/approvals/company alone. Add a render token: `const token = ++_dashRenderSeq;` at the top of renderDashboard and `if (token !== _dashRenderSeq) return;` before each `el.innerHTML = ...` so a superseded render stops writing. With D5 in place a re-render is one call anyway, but the DOM-move for drag/drop is still free.

- **Verifier note:** Confirmed: dashSetScope 12051-12054, dashDrop 12101-12111 (localStorage write then renderDashboard()), dashResetLayout 12112-12114, dismissWokeReminder 12215, engagement-save paths 26206/26319/26327/26340 all call renderDashboard(); renderDashboard has no render token, and the Promise.all writes by element id so overlapping renders race. DOM-reorder fix and render token are feasible with no storage. Medium stands.

### D15 — Reminder-banner leads fetch pulls 25 columns for every lead of every status when only New/Working/Hold and woke leads can produce a reminder

**Impact medium · effort S · payload · verified (confidence 0.85)**

- **Where:** index.html:12140-12141 _attentionLeadItems select string; consumers: 12154 (`if (l.status === 'Dead' || l.status === 'Promoted') continue;`), 12157 woke_at, 12161 New, 12167 Working; sweepHoldWake 23494-23496 (status === 'Hold')
- **Evidence:** 12140 `apiGet('leads', 'select=id,owner_id,branch_id,region_id,status,wake_date,woke_at,created_at,last_touch_date,promoted_at,dead_reason,working_at,fit,access,capacity,trigger_score,service_major_id,qualification_demoted,target_org_name,target_org_id,description,site_id,site_name,next_action_date,sites(name)')` with no filter. The loop only emits for `l.woke_at`, `status === 'New'` or `status === 'Working'`; sweepHoldWake only touches `status === 'Hold'`. Everything Qualified/Nurture/Promoted/Dead is fetched (including `description` text) and skipped.
- **Mechanism:** Over-fetch bytes on the critical path (D1): the Dead/Promoted/Qualified population grows monotonically over the life of the CRM while the reminder-eligible set stays roughly constant, so this payload grows without bound while the useful part does not. Also `apiGet` truncates at 1000 rows, so the banner silently stops seeing leads beyond the first 1000 by id.
- **Who feels it:** Every user on every landing (the banner runs for all roles). At a few thousand leads this is several hundred KB buffered through the Lambda and parsed before anything paints.

- **Fix:** Filter server-side with the exact eligibility rule: `apiGet('leads', 'or=(woke_at.not.is.null,status.in.(New,Working,Hold))&select=...same columns...')` — semantically identical output (Dead/Promoted are skipped anyway; Qualified/Nurture never emit; Hold rows are needed only by sweepHoldWake). idx_leads_status (schema.sql:2251) serves the status part. If D2's shared narrow leads fetch is adopted, keep this filtered wide fetch only for the due-Hold rows sweepHoldWake must recompute.

- **Verifier note:** Confirmed: 12140-12141 selects 25 columns incl. description with no filter, via apiGet (1000-row cap, 2123). Loop emits only for woke_at (12157), New (12161), Working (12167); sweepHoldWake only reads status==='Hold' (23494). The proposed `or=(woke_at.not.is.null,status.in.(New,Working,Hold))` yields identical output (Dead/Promoted with woke_at are skipped by 12154 anyway). The qualification columns (fit/access/capacity/trigger_score/service_major_id/qualification_demoted) are needed only for computeLeadStatus on due Hold rows, so the wide select can be confined to those. idx_leads_status exists (schema.sql:2251). Medium: payload on the pre-paint critical path for every user; fixes the silent truncation too.

### D2 — `leads` is fetched whole 4 times and `deals` 3 times per dashboard render by independent widgets

**Impact medium · effort M · query shape · verified (confidence 0.95)**

- **Where:** leads: index.html:12140 (_attentionLeadItems), 12291 (_dashApprovals), 12398 (_attentionActionRows), 12621 (_dashLeads). deals: 12399 (_attentionActionRows), 12644 (_dashOpps), 12657 (_dashPipeline) — plus 12695 (_dashSectorValue) and 12769 (_dashContracts) for those roles
- **Evidence:** 12644 `await apiGet('deals', 'select=id,stage_id,probability,owner_id,branch_id,region_id')` and 12657 the identical string in _dashPipeline; 12291 `apiGet('leads', 'select=id,owner_id,target_org_name,description,status,site_id,site_name,sites(name)')`, 12398 `apiGet('leads', 'select=id,owner_id,branch_id,region_id,target_org_name,description,site_id,site_name,sites(name)')`, 12621 `apiGet('leads', 'select=id,status,owner_id,branch_id,region_id,next_action_date')`. Each loader is self-contained and called from the Promise.all at 12266 with no shared data.
- **Mechanism:** Redundant proxied round trips and redundant whole-table payloads (the leads fetch at 12140 alone is 25 columns incl. `description` text for every lead). Seven of the ~31 requests per render return the same two tables. The DB does the same sequential scans 4x/3x, and the browser JSON-parses the same rows 4x/3x.
- **Who feels it:** Every dashboard render for every role (Sales User, Sales Manager, Admin, Executive all have >=2 of these widgets). Wasted concurrency slots on the proxy and ~1-2 MB of duplicated JSON per landing at a few thousand leads/deals (assumption: leads ~1-3k, deals ~2-5k given deal ids past 4400 on Dev per the comment at 11721).

- **Fix:** Build a per-render context object in renderDashboard (not a cache — created for one render, passed to loaders, discarded): `const ctx = { leads: apiGet('leads', 'select=id,owner_id,branch_id,region_id,status,next_action_date,target_org_name,description,site_id,site_name,target_org_id,wake_date,woke_at,last_touch_date,created_at,sites(name)'), deals: apiGet('deals', 'select=id,name,stage_id,probability,owner_id,branch_id,region_id,org_id') };` and change each loader signature to `_dashLeads(ctx)` etc., using `await ctx.leads`. sweepHoldWake only needs the full qualification columns for the (rare) due-Hold rows: fetch those on demand with `apiGet('leads', 'id=in.(' + due.map(l=>l.id) + ')&select=*')` before computeLeadStatus. Result: leads 4->1, deals 3->1 round trips and payloads per render.

- **Verifier note:** Confirmed. leads whole-table at 12140, 12291 (isSM/exec only), 12398, 12621; deals whole-table at 12399, 12644, 12657 (identical select string), plus 12695 (Executive) and 12769 (Operations). Loaders are self-contained; no shared data. Fix (per-render ctx object passed into loaders, discarded after) is not a cache and respects the constraint. Impact re-graded to medium: these duplicates run in PARALLEL inside the Promise.all (only 12398/12399 are sequential after acts), so the wall-clock saving is concurrency/parse overhead and payload, not sequential round trips; the wide 25-column leads pull that dominates bytes is D15's, the others are 5-9 narrow columns.

### D6 — Outstanding Actions: three independent whole-table fetches awaited in series, and the open-actions filter has no supporting index

**Impact medium · effort S · parallelise · verified (confidence 0.95)**

- **Where:** index.html:12376-12399 _attentionActionRows (engagements 12379, leads 12398, deals 12399); predicate `next_action_done=eq.false&next_action_date=not.is.null` at 12379 — only index on engagements is idx_engagements_lead(lead_id) (unify_engagements.sql:48)
- **Evidence:** 12379 `acts = await apiGet('engagements', 'next_action_done=eq.false&next_action_date=not.is.null&select=...')` ... 12398 `const leads = await apiGet('leads', ...)`; 12399 `const deals = await apiGet('deals', ...)` — the leads/deals calls do not depend on `acts` but wait for it. Index inventory shows no index on engagements(next_action_done, next_action_date).
- **Mechanism:** Sequential depth 3 where 1 suffices; plus a sequential scan of engagements on every load (the filter selects a small fraction of rows — every closed action is skipped).
- **Who feels it:** Sales User / Sales Manager landing (actions is first in both default lists) and the Attention Workbench page (_attentionActionRows is shared, 12374). ~2.8 s of avoidable critical path per render.

- **Fix:** Client: `const [acts, leads, deals] = await Promise.all([apiGet('engagements', ...), apiGet('leads', ...), apiGet('deals', ...)])` (or take leads/deals from the shared ctx of D2, or embed the parents: `engagements?next_action_done=eq.false&next_action_date=not.is.null&select=id,lead_id,deal_id,next_action,next_action_date,engagement_type,stream_id,engagement_date,leads(id,owner_id,branch_id,region_id,target_org_name,description,site_id,site_name,sites(name)),deals(id,owner_id,branch_id,region_id,name)` — one round trip, no whole-table leads/deals). DB: `create index engagements_open_action_idx on engagements (next_action_date) where next_action_done = false and next_action_date is not null;` (partial; tiny, exactly the rows this query and the Attention page read).

- **Verifier note:** Confirmed: 12379 acts, then 12398 leads, then 12399 deals, each awaited in turn with no data dependency. No index on engagements(next_action_done,next_action_date): only idx_engagements_lead exists (unify_engagements.sql:48). Embedded-parent fix uses existing FKs (engagements.lead_id/deal_id, leads.site_id). Medium is right: 2 sequential RTs saved but the Actions card is not the dashboard's critical path (Approvals/Pulse/Interactions are deeper); it does shorten the Attention Workbench page which shares _attentionActionRows.

### D7 — Pipeline and Value-by-Sector cards fetch every revenue_stream_months row of every open/secured deal to add them up in JS; the join columns are unindexed

**Impact medium · effort S · db view or rpc · verified (confidence 0.85)**

- **Where:** index.html:12664 _dashPipeline (`revenue_streams?deal_id=in.(...)&stream_type=eq.opportunity&select=deal_id,revenue_stream_months(opportunity_revenue)`), 12707-12708 _dashSectorValue (both stream types, two money columns); schema.sql:1079-1091 revenue_stream_months, 1117-1124 revenue_streams; sql index inventory has only revenue_streams(parent_stream_id)
- **Evidence:** 12665-12666 `for (const s of streams) { const did = +s.deal_id; for (const m of (s.revenue_stream_months || [])) dealTotal[did] = (dealTotal[did] || 0) + (+m.opportunity_revenue || 0); }` — the only use of the nested rows is a SUM per deal. The comment at 12662 notes the nested rows escape the 1000-row cap, i.e. the month volume already exceeds it. fk_columns.txt shows revenue_stream_months.stream_id is an FK with no index; revenue_streams.deal_id has neither FK-index nor explicit index.
- **Mechanism:** Over-fetch: one nested row per stream-month (typically 12-60 per deal) when one number per deal is needed — for 300 open deals with 36-month streams that is ~10k nested objects serialised by PostgREST, buffered in the Lambda (`d += c` in sb.js), transferred and parsed. DB side: PostgREST resolves the embed with a join on revenue_stream_months.stream_id — without an index that is a hash join over the whole months table on every render (ms-level today, grows with history).
- **Who feels it:** Every Sales User / Sales Manager landing (pipeline) and every Executive landing (sector_value); also the Revenue Pipeline page uses the same tables. Assumption: months table in the tens of thousands of rows (it already 'bit the 1000-row cap' per the apiGetAll comment at 2153).

- **Fix:** View `v_deal_stream_totals` as proposed + `create index revenue_stream_months_stream_idx on revenue_stream_months (stream_id);` only — drop the revenue_streams_deal_idx (already covered by revenue_streams_deal_id_stream_type_key).

- **Verifier note:** Over-fetch confirmed: 12664-12666 and 12707-12713 only SUM the nested revenue_stream_months rows per deal. Index claim is HALF wrong: revenue_streams has `UNIQUE (deal_id, stream_type)` (schema.sql:2033), which is a btree index on (deal_id, stream_type) — the proposed revenue_streams_deal_idx is redundant and the reviewer's inventory missed it because it only lists CREATE INDEX statements. revenue_stream_months.stream_id is FK-only with no index (schema.sql:2692) — that part holds. Also note the unique constraint means at most one stream per (deal, type), so stream count is bounded; months are the volume. View fix is feasible (uses secured_revenue — see D5 caveat). Medium (payload only; RT count unchanged).

### D8 — _loadOrgTouches scans the whole engagements table (no date bound, no index) on every dashboard render to get one MAX(date) per organisation

**Impact medium · effort S · db view or rpc · verified (confidence 0.9)**

- **Where:** index.html:14286-14299 _loadOrgTouches, called at 12147 from _attentionLeadItems (dashboard banner) and 14749 (leads page, force=true)
- **Evidence:** 14290 `const rows = await apiGet('engagements', 'org_id=not.is.null&select=org_id,engagement_date,work_mode');` then 14291-14295 reduces to `map['o'+org_id] = max(engagement_date)` skipping work_mode==='internal'. Cached in allData['_org_touches'] only for the session, so every login and every leads-page visit (force) repeats it. Uses apiGet -> silently capped at 1000 rows (so the aging rule also degrades once engagements exceed 1000 with org_id).
- **Mechanism:** Whole-table read (three columns of every engagement with an org) transferred and reduced in JS, with a sequential scan on the DB (engagements has no index on org_id or engagement_date). It sits on the pre-widget critical path (D1).
- **Who feels it:** Every landing (all roles: the banner runs before widgets regardless of role) and every Leads page load. Payload grows with total engagement history; today likely tens-hundreds of KB and one ~1.4 s hop on the critical path.

- **Fix:** `create view v_org_last_touch as select org_id, max(engagement_date) as last_touch from engagements where org_id is not null and work_mode is distinct from 'internal' group by org_id;` and in _loadOrgTouches: `const rows = await apiGet('v_org_last_touch', 'select=org_id,last_touch'); rows.forEach(r => { map['o'+r.org_id] = r.last_touch; });` — rows = number of touched organisations, not engagements, and no 1000-row truncation. Supporting index: `create index engagements_org_date_idx on engagements (org_id, engagement_date desc) where org_id is not null;`.

- **Verifier note:** Confirmed: 14290 whole-table `engagements?org_id=not.is.null&select=org_id,engagement_date,work_mode` via apiGet (single page, capped at PostgREST's 1000 — apiGetAll at 2122 is the paging variant), reduced to max-per-org in JS; no index on org_id/engagement_date. Title overstates frequency: memoised in allData['_org_touches'] (14287), so it runs once per session from the dashboard plus every Leads page load (14749 `_loadOrgTouches(true)`), not every dashboard render. It sits on the pre-paint critical path at first landing (D1). The view removes payload and the silent 1000-row truncation (a correctness bug for the aging rule) but not the RT itself unless D1's parallelisation is applied. Medium stands (leads page repeats it; payload grows with history).

### D12 — _milLookups has no in-flight memo, so three widgets fire the same milestone_groups + milestone_types pair concurrently on every first render

**Impact low · effort S · query shape · verified (confidence 0.95)**

- **Where:** index.html:23987-23998 _milLookups; concurrent callers 12320 (_dashApprovals), 12812 (_dashMilestones), 24971 (_dashMilestonePulse) all launched by the Promise.all at 12266
- **Evidence:** 23988 `if (!force && allData['milestone_groups'] && allData['milestone_types']) return true;` — the guard only sees allData after the first call resolves; all three callers start before that, so each issues `Promise.all([apiGet('milestone_groups', ...), apiGet('milestone_types', ...)])` (23990-23993).
- **Mechanism:** 4 redundant proxied requests per dashboard render (6 instead of 2), competing for proxy concurrency with the widgets' primary fetches.
- **Who feels it:** Every Sales User / Sales Manager landing (milestones + milestone_pulse), Admin/SM with pending milestones (approvals). Small per-render, but on the critical path of the three slowest cards.

- **Fix:** Share the in-flight promise (this is request de-duplication within one session, not a cache extension): `let _milLookupsInflight = null; async function _milLookups(force) { if (!force && allData['milestone_groups'] && allData['milestone_types']) return true; if (!force && _milLookupsInflight) return _milLookupsInflight; _milLookupsInflight = (async () => { try { ... existing body ... } finally { _milLookupsInflight = null; } })(); return _milLookupsInflight; }`. Alternatively call `await _milLookups()` once in renderDashboard before the Promise.all (costs nothing extra: it is already needed).

- **Verifier note:** Guard at 23988 only sees allData after the first pair resolves; _dashMilestones (12812) and _dashMilestonePulse (24971) both call it as their first statement from the Promise.all, so those two duplicate (4 requests instead of 2). Correction: _dashApprovals calls it only at 12318 after three prior awaits, by which time the first pair has almost always landed, so it is normally deduped — 2 redundant requests per render, not 4. In-flight promise sharing is de-duplication, not a cache. Low stands.

### D13 — Dashboard predicates run without supporting indexes on engagements, engagement_milestones, revenue_streams/months and deals

**Impact low · effort S · db index · verified (confidence 0.65)**

- **Where:** Predicates: index.html:12379 (engagements next_action_done/next_action_date), 12500 (engagements engagement_date gte), 14290 (engagements org_id not null), 12318/12815 (engagement_milestones status + order proposed_at/decided_at), 12324/12820/24981 (engagement_milestones -> engagements by id: PK ok), 12664/12707 (revenue_streams deal_id in, nested revenue_stream_months by stream_id). Index inventory (index_inventory.txt): engagements has only lead_id; revenue_streams only parent_stream_id; deals only master/parent/opportunity_type; engagement_milestones DDL absent from repo (assume none)
- **Evidence:** sql/schema.sql:434-450 engagements columns; unify_engagements.sql:48 is the only engagements index. fk_columns.txt lists engagements.deal_id, revenue_stream_months.stream_id, deals.owner_id/stage_id/org_id/region_id as FKs — Postgres does not auto-index FK columns. predicates.txt: engagements next_action_done=eq x5, engagement_date=gte x2, org_id=in x2, deal_id=eq/in x2; engagement_milestones status=eq x2, engagement_id=in x2; revenue_streams deal_id=eq x5/in x2; revenue_stream_months stream_id=eq/in x4.
- **Mechanism:** Sequential scans / hash joins over whole tables for filtered reads that touch a small fraction of rows. At today's assumed volumes (engagements 5-20k, months 20-60k) this is milliseconds per query, i.e. minor next to the 1.4 s proxy hop — but it compounds with the 6 engagement reads per render and grows linearly with history, and it becomes the dominant cost once the round trips are collapsed into views/RPC (D4, D5, D7, D8).
- **Who feels it:** All dashboard renders, Attention Workbench, Engagement History, Revenue Pipeline. Low today; medium in a year.

- **Fix:** Same DDL minus `revenue_streams_deal_idx` (covered by revenue_streams_deal_id_stream_type_key); defer deals_stage_idx/deals_owner_idx until a filtered query (RPC/view) actually uses them.

- **Verifier note:** Mostly right but with errors: (1) revenue_streams already has a usable index via UNIQUE (deal_id, stream_type) (schema.sql:2033) — drop revenue_streams_deal_idx; (2) deals_stage_idx / deals_owner_idx serve none of the dashboard queries as written — every dashboard deals read is an unfiltered whole-table select (12399, 12644, 12657, 12695, 12769) or a PK id=in.() list; they only matter if the RPC/view fixes land; (3) engagements indexes (open-action partial, engagement_date, org_id/date, deal_id) and revenue_stream_months(stream_id), engagement_milestones(status/engagement_id) are genuinely missing (unify_engagements.sql:48 is the only engagements index). Low stands; confidence appropriately low.

### D14 — Reminder banner does O(leads x (sites + organisations)) linear `.find` scans per render

**Impact low · effort S · client cpu · verified (confidence 0.8)**

- **Where:** index.html:12153-12175 _attentionLeadItems loop calling leadEngLabel (14692 -> leadSiteLabel 14157-14163: `allData['sites'].find`) and leadEffectiveTouch (14320-14326: `allData['sites'].find` + _groupTouchFor 14302-14316: `O.find` per ancestor hop) for every non-Dead/Promoted lead
- **Evidence:** 12155 `const label = leadEngLabel(l) || ('Lead #' + l.id);` is computed before the status branches, for every lead in the loop; 14160 `(allData['sites'] || []).find(x => +x.id === +l.site_id)`; 14323 `(allData['sites'] || []).find(s => +s.id === +l.site_id)`; 14307 `let cur = O.find(o => +o.id === +orgId)` and 14314 `O.find(x => +x.id === +cur.parent_org_id)` per hop.
- **Mechanism:** Client CPU: with ~2k live leads, ~1k sites and ~2k organisations this is ~2k x (1k + 1k + 2k) ≈ 8M comparisons on the main thread per render (~30-80 ms), repeated on every re-render, and the same helpers run on the Leads page.
- **Who feels it:** All users, every dashboard render; a small but measurable main-thread stall right before first paint (worse on the Leads page where the same helpers run per row). Low.

- **Fix:** Build id maps once per call and pass them down: in _attentionLeadItems `const siteById = new Map((allData['sites']||[]).map(s => [+s.id, s])); const orgById = new Map(_orgsForAging.map(o => [+o.id, o]));` and give leadSiteLabel / leadEffectiveTouch / _groupTouchFor an optional `{siteById, orgById}` argument used in place of `.find`. Also only compute `label` after the status checks decide the lead is flagged.

- **Verifier note:** Mechanism overstated. 12156 leadEngLabel: the fetch embeds sites(name), so `l.sites.name` short-circuits leadSiteLabel for every lead that has a site, and leadSiteLabel returns before its .find when site_id is null (14157-14160) — the sites scan is essentially never executed. leadEffectiveTouch runs only for New/Working leads (12162, 12172), and its sites.find only when target_org_id is null; the real cost is _groupTouchFor's `O.find` per ancestor hop (14307, 14314) — O((New+Working leads) x orgs x chain depth), not O(all leads x (sites+orgs)). Still a linear scan per lead worth replacing with a Map, and computing label after the status checks is free. Low is correct.


## Opportunities register, Revenue Pipeline, Deal Admin

### OPP-1 — Opportunities register pulls the whole deals table and every opportunity month row for every deal, then filters by owner/stage on the client

**Impact high · effort M · db view or rpc · verified (confidence 0.85)**

- **Where:** index.html:11758-11810 renderOpportunitiesPage; 11713-11734 filterDealsByView; 11658-11664 toggles; 9371-9372 saveOpportunity tail
- **Evidence:** 11768: apiGetAll('deals', 'select=*&order=created_at.desc') — no owner_id/stage predicate. 11784: deals = await filterDealsByView(deals, oppsOwnerView) — 'own' is deals.filter(d => +d.owner_id === +pid) (11734). 11789-11795: openStageIds computed client-side from stages/stage_categories and applied with deals.filter. 11803-11804: apiGetAll('revenue_streams','stream_type=eq.opportunity&select=deal_id,revenue_stream_months(opportunity_revenue)') — every opportunity stream of every deal with every month row, then summed in JS (11805-11808). deals carries notes, ext_notes, lost_notes, lost_reason, lost_to text columns (schema.sql:323-346) that the register never displays. Deal ids reach #4430 on Dev (comment at 11721), so 'thousands of deals' is a plausible volume; contracts run 12-60 months.
- **Mechanism:** Over-fetch bytes + extra sequential round trips: two full-table transfers (deals, then streams+months) through the Netlify proxy where the default view typically needs a few dozen rows; the second apiGetAll pages sequentially (+1 rtt per 1000 opportunity streams). The status/scope filters and the TCV aggregation are all computable in Postgres.
- **Who feels it:** Every user, every time they open Opportunities, every click on Open/All statuses or Show Own/All/Collab/Team, and after every deal Save (saveOpportunity → renderOpportunitiesPage). 2-3 sequential proxied round trips (~3-4 s by the code's own 1.4 s/rtt estimate) plus a payload that grows with the whole company's pipeline rather than the user's.

- **Fix:**

```sql
Create a register view that does the joins and the TCV sum server-side, then filter it in the query string so one round trip returns exactly the rows shown.

SQL:
create or replace view deal_register_v as
select d.id, d.name, d.org_id, o.name as org_name, s.name as sector_name,
       d.stage_id, st.name as stage_name, sc.name as stage_category,
       d.probability, d.order_date, d.owner_id, d.region_id, d.branch_id,
       d.opportunity_type, d.master_deal_id, d.created_at,
       coalesce(f.tcv,0)::numeric(14,2) as opp_tcv
from deals d
left join organisations o     on o.id  = d.org_id
left join industry_sectors s  on s.id  = o.sector_id
left join stages st           on st.id = d.stage_id
left join stage_categories sc on sc.id = st.category_id
left join lateral (select sum(m.opportunity_revenue) tcv
                   from revenue_streams rs join revenue_stream_months m on m.stream_id = rs.id
                   where rs.deal_id = d.id and rs.stream_type = 'opportunity') f on true;
(add d.site_id / sites.name only if deals.site_id exists in the live DB — it is read at 11827 but not present in any sql/ migration).

Client (renderOpportunitiesPage):
  own+open : apiGetAll('deal_register_v', `owner_id=eq.${pid}&stage_category=eq.Opportunity-Open&order=created_at.desc`)
  all statuses: drop the stage_category predicate
  team     : `or=(owner_id.eq.${pid},branch_id.in.(${branches}),region_id.in.(${regions}))`
  collab   : fetch deal_collaborators?person_id=eq.P&select=deal_id IN PARALLEL with the own query, then one more `id=in.(...)` query — or expose an RPC `opportunities_register(p_person bigint, p_scope text, p_open_only bool) returns setof deal_register_v` and call /rpc/opportunities_register (one round trip for every scope).
The column getters (11830-11836) then become property reads (d.org_name, d.stage_name, d.sector_name) and dealTcv[d.id] becomes d.opp_tcv, removing the second round trip entirely. The toggles at 11658-11664 and the post-Save refresh at 9371 become one small filtered call each.
```

- **Verifier note:** Confirmed. 11768 apiGetAll('deals','select=*&order=created_at.desc') has no owner/stage predicate; 11784 filterDealsByView applies owner scope client-side ('own' = deals.filter on owner_id, 11734); 11789-11795 derives openStageIds from stage_categories/stages client-side; 11803-11804 apiGetAll('revenue_streams','stream_type=eq.opportunity&select=deal_id,revenue_stream_months(opportunity_revenue)') pulls every opportunity stream of every deal with all months and sums in JS (11805-11808). deals carries lost_to/lost_reason/lost_notes/notes/ext_notes text (schema.sql:323-346) that the register never renders. Re-run on every scope/status toggle (11658-11664) and after Save (9371-9372, renderOpportunitiesPage). Fix is a plain Postgres view + query-string filters through the existing proxy (sb.js:253 forwards any /rest/v1 path); no client-storage caching involved. deals.site_id is indeed absent from every sql/ migration but written by the form (9320) and read at 24804, so the live DB has it — the view can include it. Minor corrections: the ~1.4 s/rtt comment lives at 3546/7052/22769, not 3616; and 'all' is gated by can('view_all_opportunities') (11714), so the view query must keep that fallback. Impact high is justified: 2 sequential proxied round trips (3 for collab) plus whole-pipeline payload on a page opened and re-rendered constantly.

### RPP-1 — Revenue Pipeline downloads every revenue_stream_months row (10 columns) for every deal of every owner, then applies the owner scope client-side

**Impact high · effort M · db view or rpc · verified (confidence 0.8)**

- **Where:** index.html:13561-13596 loadData; 13661 filterDealsByView after load
- **Evidence:** 13563: apiGetAll('deals','select=*') and 13574: apiGetAll('revenue_streams','select=id,deal_id,stream_type,revenue_stream_months(stream_id,month,opportunity_revenue,opportunity_margin,secured_revenue,secured_margin,actual_revenue,is_actual_revenue,actual_margin,is_actual_margin)') — no deal_id/owner predicate, both stream types. 13580-13596: months flattened then merged per (deal, month) with pick(). Only at 13661 is DEALS = await filterDealsByView(DEALS, oppsOwnerView) applied — after the full download. The 1000-row cap was already hit by this table once ('bit the pipeline's month fetch once already', 2229), i.e. months exceed 1000 rows. The proxy buffers the whole response as a string (sb.js `d += c`) and Netlify synchronous functions cap responses at 6 MB.
- **Mechanism:** Over-fetch bytes: the largest table in the schema is transferred in full on every pipeline open and every scope toggle; with N_deals in the low thousands and 12-60 months each this is tens of thousands of JSON rows (several MB) through a buffering proxy, plus client CPU to flatten and merge. Sequential paging inside apiGetAll adds one round trip per 1000 top-level streams.
- **Who feels it:** Every Revenue Pipeline open and every Show Own/All/Collab/Team click on it; for a sales user on 'own' scope, >90% of the downloaded months belong to other people's deals. Volume assumption: thousands of deals × 12-60 months — stated, not measured.

- **Fix:** As proposed, plus: (a) before adding revenue_streams_deal_id_fkey run `delete from revenue_streams where deal_id not in (select id from deals)` (or verify zero orphans) or the ALTER fails; (b) drop secured_revenue/secured_margin from the view/select — the pipeline never reads them (fulRev/fulMar at 13590-13591 are dead).

- **Verifier note:** Confirmed. 13563 apiGetAll('deals','select=*') and 13574 apiGetAll('revenue_streams','select=id,deal_id,stream_type,revenue_stream_months(...10 cols...)') with no deal/owner predicate and both stream types; 13580-13596 flattens and merges per (deal,month); scope is applied only at 13661 after the full download. schema.sql:2029-2041 shows revenue_streams has only UNIQUE(deal_id,stream_type) + PK, no FK to deals (grep across sql/ finds none), so embedding streams under deals genuinely needs the proposed FK; adding it is feasible (clean orphan streams first or the ALTER fails). The view-based deal_month_v is feasible through the proxy. Evidence citation is off: the 1000-row-cap history is in the apiGetIn comment at 13196-13199 and the loadData comment at 13569-13573, not line 2229. Additional support: secured_revenue/secured_margin are merged into fulRev/fulMar (13590-13591) but never read by layers() (13212-13222), so the view can drop them. Caveat on impact: 'all'-scope managers still receive the whole table after the fix, but for sales users on 'own' the payload shrinks to their deals — large-payload criterion met, high stands.

### DA-2 — adminDeleteDeal issues 13 strictly sequential round trips (plus a full page reload) for one delete

**Impact medium · effort S · query shape · verified (confidence 0.85)**

- **Where:** index.html:13770-13805 adminDeleteDeal
- **Evidence:** 13774 GET deals children check; 13784 GET revenue_streams ids; 13787 DELETE revenue_stream_months; 13789 DELETE revenue_streams; 13790 DELETE engagements; 13791 DELETE deal_contacts; 13792 DELETE deal_collaborators; 13794-13796 DELETE secured_snapshots / interactions / risks in a for-await loop (interactions and risks have no CREATE TABLE in sql/ — each still costs a round trip that returns an error which is swallowed); 13798 PATCH leads; 13800 DELETE deals; 13802 await renderDealAdminPage() (2 more). Yet schema.sql already declares ON DELETE CASCADE from deals for deal_collaborators (2308), engagements (2412), opportunity_contacts/deal_contacts (2612) and for revenue_stream_months→revenue_streams (2692); leads.promoted_deal_id is ON DELETE SET NULL (2532). Only revenue_streams.deal_id (no FK at all, schema.sql:2033) and secured_snapshots.deal_id (references deals(id) without cascade, add_secured_snapshots.sql:17) block a single cascading delete.
- **Mechanism:** Extra sequential round trips: 13 × ~1.4 s proxied latency in series (~18 s) for work Postgres would do in one statement via existing cascade rules.
- **Who feels it:** Deal administrators, each time a deal is deleted (rare, but the wait is long enough to look hung; the UI shows no progress between steps).

- **Fix:** As proposed; additionally verify `select count(*) from revenue_streams rs where not exists (select 1 from deals d where d.id=rs.deal_id)` is 0 before adding the FK, and note secured_snapshots' own header says it is an audit trail — decide explicitly whether cascade-deleting it is acceptable (today's code already deletes it).

- **Verifier note:** Confirmed. Sequence at 13774-13802: GET children, (confirm), GET stream ids, DELETE months, DELETE streams, DELETE engagements, DELETE deal_contacts, DELETE deal_collaborators, DELETE secured_snapshots/interactions/risks in a for-await loop (13794-13796, errors swallowed), PATCH leads, DELETE deals, then renderDealAdminPage (2 parallel) — 13 sequential levels, 14 calls. Cascades exist: deal_collaborators (schema.sql:2308), engagements (2412), opportunity_contacts→deals (2612; the table is deal_contacts in the live DB per the audit list and the app, constraints survive a rename), months→streams (2692), leads.promoted_deal_id SET NULL (2532). revenue_streams.deal_id has no FK (2029-2041) and secured_snapshots.deal_id references deals without cascade (add_secured_snapshots.sql:17) — exactly the two blockers named. No CREATE TABLE for interactions/risks in sql/ (grep confirms). Fix SQL is feasible (clean orphan streams first). Impact medium is reasonable: the action loses ~10 sequential hops but is rare and admin-only; audit trigger (add_audit_log.sql:72-89) fires per cascaded row regardless.

### OPP-2 — TCV stream fetch is awaited sequentially after the deals fetch although it does not depend on the deals result

**Impact medium · effort S · parallelise · verified (confidence 0.95)**

- **Where:** index.html:11801-11810 (inside renderOpportunitiesPage, after the await at 11784)
- **Evidence:** 11767-11775 awaits Promise.all([deals, ...lookups]); 11784 awaits filterDealsByView; only then 11803: const strms = await apiGetAll('revenue_streams', 'stream_type=eq.opportunity&select=deal_id,revenue_stream_months(opportunity_revenue)'). The query string contains nothing derived from deals — the only dependency is the `if (deals.length)` guard at 11802.
- **Mechanism:** Extra sequential round trip: depth 2 where depth 1 is possible; the proxy round trip (~1.4 s per the comment at 3616) is paid twice in series instead of once in parallel.
- **Who feels it:** Every Opportunities load, toggle and post-Save refresh waits one full extra proxied round trip before anything renders. Interim quick win until OPP-1 (view) lands.

- **Fix:**

```sql
Move the streams call into the first Promise.all and drop the deals.length guard:
  let [deals, orgs, stages, people, stageCats, sites, sectors, strms] = await Promise.all([
    apiGetAll('deals', 'select=id,name,org_id,stage_id,probability,order_date,owner_id,region_id,branch_id,site_id,opportunity_type,master_deal_id,created_at&order=created_at.desc'),
    ..., 
    apiGetAll('revenue_streams','stream_type=eq.opportunity&select=deal_id,revenue_stream_months(opportunity_revenue)').catch(() => []),
  ]);
Sequential depth drops from 2 to 1 (collab: 3 to 2 — the deal_collaborators fetch at 11727 can likewise be issued in the same Promise.all since pid is known up front). Narrowing select=* to the listed columns also removes notes/ext_notes/lost_* from the payload.
```

- **Verifier note:** Confirmed. 11767-11775 awaits Promise.all([deals,...lookups]); 11784 awaits filterDealsByView; only then 11803 awaits the revenue_streams call, whose query string is constant (only `if (deals.length)` at 11802 references deals). Moving it into the first Promise.all is a pure parallelisation, no caching. Also correct that for 'collab' the deal_collaborators fetch at 11727 is a third sequential hop that could be issued alongside (pid is known before the deals call). Narrowing select=* is a valid add-on (columns actually read: id,name,org_id,stage_id,probability,order_date,owner_id,region_id,branch_id,site_id,opportunity_type,master_deal_id,created_at). Medium is right: saves exactly one sequential ~1.4 s hop per load/toggle/save (two for collab).

### RPP-2 — Pipeline paint() rebuilds and force-lays-out the entire grid up to (FYs − 2) extra times per interaction and recomputes filter/sort/value sums 4+ times

**Impact medium · effort M · dom render · verified (confidence 0.75)**

- **Where:** index.html:13525-13552 paint; 13541-13546 buildAndMeasure loop; 13365-13455 buildAndMeasure; 13509-13517 renderTotStrip; 13250-13266 visibleDeals; 13234-13240 COLS 'value' getter
- **Evidence:** 13541-13544: for (let n=visN; n<=total; n++){ buildAndMeasure(n, true, false); if (document.getElementById('rpp-grid').getBoundingClientRect().width <= avail) visN = n; else break; } — each buildAndMeasure sets rpp-thead and rpp-tbody innerHTML for ALL rows (13450-13452) and the getBoundingClientRect forces a synchronous layout of the whole table; then 13546 builds once more to commit. visibleDeals() (filter + sort of all deals) is called in paint (13533), in every buildAndMeasure (13387), in updateNote (13502) and in renderTotStrip (13511). dealValue(d) = sum over every FY × 12 months (13224-13228) is called per row in dealRowHtml (13411), again per FY via fyValue (13421), and is the comparator for the 'value' column (13236) so sorting by Value costs O(n log n × FYs × 12). renderTotStrip (13511-13513) re-walks all deals × all FYs × 12 months. paint() runs on every sort click, filter checkbox, basis/metric/variance toggle, FY tab, lineage toggle and window resize (13555-13560, 13668).
- **Mechanism:** DOM rebuild + forced synchronous layout repeated in a loop; O(deals × FYs × 12) CPU work repeated 4-5 times per paint; comparator with O(FYs×12) cost.
- **Who feels it:** Every click inside the Revenue Pipeline after load feels sluggish in proportion to (visible deals × number of FYs spanned × table width); with 'all' scope on a wide monitor the loop can build the table 6-8 times per click. Client CPU only — becomes the dominant cost once RPP-1 removes the network wait.

- **Fix:** (a) Compute visN arithmetically instead of by trial rendering: FY-total columns are fixed at width:96px (13378, 13382) and the pinned/detail widths can be measured once from a single build — visN = clamp(floor((avail − pinnedW − detailW) / 96), MIN_FY, total); build once. (b) Call visibleDeals() once at the top of paint() and pass the list into buildAndMeasure/updateNote/renderTotStrip. (c) Precompute per-deal totals when data loads or basis/metric changes: d.fyTot[fyKey] and d.total, so dealRowHtml, the master-row reducers (13425-13435), the Value comparator and renderTotStrip read numbers instead of re-summing months. (d) Debounce the resize listener (13668).

- **Verifier note:** Confirmed. paint() 13539-13546: visN starts at min(3,total) and the loop `for (n=visN; n<=total; n++){ buildAndMeasure(n,true,false); getBoundingClientRect... }` rebuilds rpp-thead/rpp-tbody innerHTML for all rows (13450-13452) and forces layout once per candidate, then 13546 builds once more — up to (FYs-2) trial builds + 1 commit. visibleDeals() (full filter+sort) is called in paint's banner branch (13533, only when filters active), in buildAndMeasure (13387), updateNote (13502) and renderTotStrip (13511). dealValue (13228) sums every FY x 12 months via layers(); it is called per row (13411), fyValue again per FY per row (13421), per member in master-row reducers (13425-13435), and is the 'value' column comparator (13236). renderTotStrip re-walks all deals x FYs x 12. Resize listener at 13668 is undebounced. Fix (a) is feasible: only closed-FY columns are fixed 96px, so measure once at MIN_FY and add 96 per extra column; (b)-(d) are straightforward. Client-CPU only; medium is fair but only materialises with hundreds+ deals and many FYs — at small volumes it is sub-100 ms.

### DA-1 — Deal Admin makes a separate, unpaged revenue_streams call for the locked flag and pulls deals with select=*

**Impact low · effort S · query shape · verified (confidence 0.8)**

- **Where:** index.html:13705-13711 renderDealAdminPage Promise.all; 13716-13717 lockedByDeal
- **Evidence:** 13706: apiGetAll('deals', 'select=*&order=created_at.desc') and 13710: apiGet('revenue_streams', 'stream_type=eq.opportunity&select=deal_id,locked') — plain apiGet, so the response is capped at 1000 rows (the same trap apiGetAll was written for, 2226-2231); the page only reads id, name, org_id, stage_id, probability. securedOf (13717) needs one boolean per deal.
- **Mechanism:** Extra round trip in the parallel batch + over-fetch bytes (notes/ext_notes/lost_* text columns) + silent truncation once opportunity streams exceed 1000 (deals beyond the cap render as 'Open').
- **Who feels it:** Deal administrators on every Deal Administration load and after every admin edit/delete (13802, 9371). Low frequency but the page is also the landing point after adminDeleteDeal.

- **Fix:**

```sql
One embedded, paged call with a narrow select (PostgREST embeds revenue_stream_months→revenue_streams today; embedding revenue_streams under deals needs the FK proposed in RPP-1):
  apiGetAll('deals', 'select=id,name,org_id,stage_id,probability,revenue_streams(locked)&revenue_streams.stream_type=eq.opportunity&order=created_at.desc')
  const securedOf = d => !!(d.revenue_streams?.[0]?.locked) || [5,7,8].includes(+d.stage_id);
Until the FK exists, at minimum change 13710 to apiGetAll(...) so the locked flags are not truncated, and narrow the deals select.
```

- **Verifier note:** Confirmed. 13706 apiGetAll('deals','select=*&order=created_at.desc'); 13710 plain apiGet('revenue_streams','stream_type=eq.opportunity&select=deal_id,locked') — apiGet has no paging, so the 1000-row db-max-rows cap silently truncates locked flags once opportunity streams exceed 1000, and securedOf (13717) then reports 'Open' for the tail. The page reads only id,name,org_id,stage_id,probability. Embedding revenue_streams(locked) under deals needs the missing FK (schema.sql:2029-2041, none in any migration), as the finding says; interim apiGetAll swap is correct. Low/S is right (admin-only page, parallel batch, only bytes and a correctness cap).

### DB-1 — No indexes on the columns the server-side filters in OPP-1/RPP-1 would use: deals(owner_id), deals(stage_id), deal_collaborators(person_id)

**Impact low · effort S · db index · verified (confidence 0.9)**

- **Where:** sql/schema.sql:1745-1761 (deals/deal_collaborators constraints), sql/add_extensions_variations.sql:67-69 (only master_deal_id, parent_deal_id, opportunity_type indexed); scratchpad index_inventory.txt
- **Evidence:** index_inventory.txt lists 28 indexes; for deals only deals_master_deal_idx, deals_parent_deal_idx, deals_opportunity_type_idx exist. deals.owner_id, deals.stage_id, deals.org_id, deals.region_id, deals.branch_id and deal_collaborators.person_id are FK columns with no index (Postgres does not auto-index FK columns). predicates.txt shows the client already issues deals?org_id=eq / org_id=in / parent_deal_id=eq and deal_collaborators?person_id=eq (11727). By contrast the two joins the embedding relies on ARE indexed via UNIQUE constraints whose leading column matches: revenue_streams (deal_id, stream_type) at schema.sql:2033 and revenue_stream_months (stream_id, month) at 2025 — so the months-under-streams embed and the lateral TCV sum in deal_register_v are index-backed.
- **Mechanism:** DB sequential scan on deals / deal_collaborators for every owner_id / stage_id / person_id predicate. Today the app pulls whole tables so this costs nothing; it becomes the query plan for every register load once OPP-1/RPP-1 move the filter server-side.
- **Who feels it:** Nobody today; after OPP-1/RPP-1 every Opportunities/Pipeline load for every user. Honest sizing: at a few thousand deals a seq scan is single-digit ms, so this is an enabler that keeps the new filtered queries cheap as the tables grow, not a fix for the current slowness.

- **Fix:**

```sql
create index if not exists deals_owner_stage_idx on deals (owner_id, stage_id);
create index if not exists deals_stage_idx on deals (stage_id);
create index if not exists deals_org_idx on deals (org_id);
create index if not exists deals_region_branch_idx on deals (region_id, branch_id);
create index if not exists deal_collaborators_person_idx on deal_collaborators (person_id);
(all small, single-statement, safe to run online with `create index concurrently` on prod).
```

- **Verifier note:** Confirmed against index_inventory.txt: for deals only deals_master_deal_idx, deals_parent_deal_idx, deals_opportunity_type_idx (add_extensions_variations.sql:67-69); no index on owner_id, stage_id, org_id, region_id, branch_id. deal_collaborators has UNIQUE(deal_id, person_id) (schema.sql:1745) — leading column deal_id, so person_id=eq lookups (11727) are not index-backed. revenue_streams UNIQUE(deal_id,stream_type) (2033) and revenue_stream_months UNIQUE(stream_id,month) (2025) do back the embed/lateral join. Correctly graded low: enabler for OPP-1/RPP-1, single-digit ms today.

### OC-1 — All Opportunity Contacts pulls the whole deals and leads tables (leads with an embedded sites join) just to label contact rows

**Impact low · effort S · query shape · verified (confidence 0.65)**

- **Where:** index.html:27822-27829 Promise.all; 27841-27856 getters; deal_contacts.lead_id column origin not in sql/ (not unify_engagements.sql:22)
- **Evidence:** 27826: apiGet('deals', 'select=id,name,org_id') and 27827: apiGet('leads', 'select=id,description,target_org_id,target_org_name,site_id,site_name,sites(name)') — every row of both tables, unpaged (1000-row cap applies), used only via deals.find / leads.find per contact (27846-27853). people/orgs come from allData; dmu_roles is fetched once per session. This file already uses PostgREST embedding successfully (sites(name) here; revenue_stream_months elsewhere), and deal_contacts has FKs to deals (schema.sql:2612) and people (2628).
- **Mechanism:** Over-fetch bytes (two unrelated whole tables, one with a server-side join) + O(contacts × (deals + leads + people + orgs)) client scans.
- **Who feels it:** Anyone opening the Opportunity Contacts page (admin/sales support); payload scales with total deals + leads rather than with contacts.

- **Fix:**

```sql
One embedded call sized to the contacts themselves:
  apiGetAll('deal_contacts', 'select=id,note,deal_id,lead_id,person_id,dmu_role_id,people(first_name,last_name),dmu_roles(name),deals(name,organisations(name)),leads(id,description,target_org_id,target_org_name,site_id,site_name,sites(name),target_org:organisations!target_org_id(name))&order=id.asc')
Requires FKs deal_contacts.lead_id→leads(id) and deal_contacts.dmu_role_id→dmu_roles(id) to exist (lead_id was added by unify_engagements.sql:22 without a REFERENCES clause — add `alter table deal_contacts add constraint deal_contacts_lead_id_fkey foreign key (lead_id) references leads(id) on delete cascade;`). Getters become property reads; the deals and leads round trips disappear.
```

- **Verifier note:** Confirmed. 27826 apiGet('deals','select=id,name,org_id') and 27827 apiGet('leads','select=...sites(name)') pull whole tables, unpaged (1000 cap), used only via deals.find/leads.find per contact (27846-27853). FKs for the proposed embed: deal_contacts.person_id→people (schema.sql:2628), dmu_role_id→dmu_roles (2620 — already exists, so the finding's 'requires FK' for dmu_role_id is satisfied), deal_id→deals (2612), deals.org_id→organisations (2332), leads.target_org_id presumably. Evidence error: unify_engagements.sql:22 adds lead_id to ENGAGEMENTS, not deal_contacts; no migration in sql/ adds deal_contacts.lead_id at all, so whether an FK exists is unknown — the fix must still check/add deal_contacts_lead_id_fkey. Also 27823 apiGet('deal_contacts','select=*') is itself unpaged. Low/S correct (parallel, admin page, bytes only).

### OPP-3 — Client-side joins use Array.find inside sort comparators, filter getters, row renderers and band builders — O(n × m) per render, O(n log n × m) per sort

**Impact low · effort S · client cpu · verified (confidence 0.7)**

- **Where:** index.html:11830-11836 columns getters, 11827 siteNameOf, 11849-11860 dealRow, 11917-11933 dealBandRow, 11935-11953 groupRenderer → 14236-14242 dealBandOf → 14213-14223 _ultimateParentOrg, 14259-14268 _groupChipHtml → 14248-14253 _familyOrgIds; same pattern at 13728-13740 (Deal Admin), 13607-13623 (RPP DEALS mapping), 27841-27876 (contacts); generic engine 2311-2330
- **Evidence:** 11831: get: d => (orgs.find(o => +o.id === +d.org_id)?.name) — invoked by _renderTable's comparator twice per comparison (2323: const va = col.get(a), vb = col.get(b)), by the filter for every row and column (2311-2316), and by _openFilterPopup for every row (2394). 11832: _orgSectorName does organisations.find then industry_sectors.find (11749-11753). 11940: dealBandOf(d, orgs) per deal → _ultimateParentOrg does an orgs.find per parent hop. 11928: _groupChipHtml(k) per band → _familyOrgIds iterates ALL organisations and calls _ultimateParentOrg for each (14250) — O(orgs × hops × find) per band row. 13610-13618: RPP builds every DEALS entry with orgs.find, people.find, smaj.find, ssub.find, stages.find, regions.find, branches.find.
- **Mechanism:** O(n×m) client CPU: linear scans over organisations (largest lookup) repeated per deal per column per render; the sort path multiplies by log n. Cost is invisible at tens of deals and hundreds of orgs; it becomes the visible stall at thousands of each, and grows sharply once parent_org_id is populated (the code says today it is mostly null — 14205-14208).
- **Who feels it:** Every render/sort/filter of the Opportunities, Deal Admin, Pipeline and Contacts tables. Assumption: organisations/people in the low thousands (they are already paged for the 1000-row cap at 2194-2196).

- **Fix:** Either receive the labels pre-joined from the DB (OPP-1's deal_register_v makes every getter a property read: d.org_name, d.stage_name, d.sector_name) or, as a pure client change, build Map indexes once per render and use them everywhere:
  const orgById = new Map(orgs.map(o => [+o.id, o])), stageById = new Map(stages.map(s => [+s.id, s])), siteById = ..., sectorById = ...;
  get: d => orgById.get(+d.org_id)?.name || ''
For bands: compute ultimate-parent once per organisation into a Map<orgId, topOrg> (one pass over orgs, memoised hops) and derive family sizes with one groupBy over that map, so dealBandOf/_groupChipHtml are O(1) lookups. Same Map treatment for personName/serviceLabel in RPP (13185-13190) and for the five find() calls per row in renderAllOppContacts.

- **Verifier note:** Mechanism confirmed: 11831/11835 getters do orgs.find/stages.find per call; _renderTable calls col.get twice per comparison (2323) and per row per column in the filter (2311-2316); _openFilterPopup walks all rows (2394); _orgSectorName (11749-11753) does two finds; dealBandOf → _ultimateParentOrg finds per hop (14213-14242); _groupChipHtml → _familyOrgIds iterates ALL organisations per band (14248-14253); RPP DEALS mapping does 7 finds per deal (13607-13618); contacts do up to 5 finds per row (27841-27876). Fix (Map indexes / precomputed ultimate-parent map) is pure client, no storage. Impact re-graded to low: no measurement, and at the plausible scale (low thousands of deals/orgs) the sort path is at most a few hundred ms, dwarfed by the ~1.4 s network hops; OPP-1's view removes the getters on the Opportunities page anyway, leaving Deal Admin/RPP/Contacts where n is smaller or the mapping runs once per load.


## Opening, editing and saving a deal

### OPP-01 — saveRevenueStream writes the forecast one month at a time: 2 sequential round trips per month, on every Save

**Impact high · effort S · query shape · spot-checked (confidence 0.95)**

- **Where:** /home/user/Focus/index.html:9378-9412 (saveRevenueStream), called from saveOpportunity at 9359; api() Prefer header at 2051
- **Evidence:** 9395: `const monthEntries = Object.entries(oppMonths).filter(([m, v]) => v.revenue); for (const [month, vals] of monthEntries) { const existing = await apiGet('revenue_stream_months', `stream_id=eq.${streamId}&month=eq.${month}&select=id`); ... if (existing.length) { await api('revenue_stream_months', 'PATCH', monthPayload, 'id=eq.' + existing[0].id); } else { await api('revenue_stream_months', 'POST', monthPayload, ''); } }`. Preceded by 9386 `await apiGet('revenue_streams', ...)` (+ POST at 9391 if absent). No comparison against the months loaded at 5162, so unchanged months are re-PATCHed. The table already has `UNIQUE (stream_id, month)` (sql/schema.sql:2025) and revenue_streams has `UNIQUE (deal_id, stream_type)` (schema.sql:2033) — exactly what PostgREST `on_conflict` upserts need. The proxy forwards the Prefer header verbatim (netlify/functions/sb.js: `'Prefer': event.headers['prefer'] || ''`), so no infra change is needed. maybeOfferExtensionProspect already proves the bulk path works: 9594 `await api('revenue_stream_months', 'POST', seedMonths, '')` inserts an array in one call.
- **Mechanism:** 1 + 2N strictly sequential proxied round trips (existence probe + write per month), each a separate PostgREST transaction that fires the row-level audit trigger (add_audit_log.sql:76) and writes a new heap tuple even when the value is identical. At the codebase's ~1.4 s/round trip: 12 months ≈ 35 s, 36 months ≈ 100 s, 60 months ≈ 3 min — before collaborators/contacts/register re-render.
- **Who feels it:** Every user clicking Save on any deal with a populated forecast — including saves that only changed the stage, margin or a lookup — waits tens of seconds to minutes with the busy cursor spinning; the longer the contract term, the worse. This is the single largest cost on the opportunity page and almost certainly the 'slowing down' Richard feels when saving.

- **Fix:**

```sql
Replace the loop with ONE bulk upsert (2 round trips total, or 1 with an RPC), and skip it when nothing changed.

(a) api(): accept extra Prefer directives, e.g. `async function api(table, method='GET', body=null, params='', extraPrefer='')` and build `'Prefer': [method==='POST'||method==='PATCH' ? 'return=representation' : '', extraPrefer].filter(Boolean).join(',')`.

(b) saveRevenueStream:
```js
if (oppRevLocked) return;
const pct = +document.getElementById('opp-margin-pct').value || 25;
const rows = Object.entries(oppMonths).filter(([,v]) => v.revenue)
  .map(([month, v]) => ({ month, opportunity_revenue: +v.revenue, opportunity_margin: Math.round(v.revenue * pct) / 100 }));
if (JSON.stringify(rows) === JSON.stringify(_oppMonthsAsOpened)) return;   // capture _oppMonthsAsOpened at 5162
// get-or-create the stream in one call on UNIQUE (deal_id, stream_type); omit `locked` so it is never overwritten
const [stream] = await api('revenue_streams', 'POST', { deal_id: dealId, stream_type: 'opportunity' },
  'on_conflict=deal_id,stream_type&select=id', 'resolution=merge-duplicates');
await api('revenue_stream_months', 'POST', rows.map(r => ({ ...r, stream_id: stream.id })),
  'on_conflict=stream_id,month', 'resolution=merge-duplicates,return=minimal');
```
For an existing deal this can run in `Promise.all` with the deals PATCH at 9346 (it only needs deal.id).

(c) Best: one RPC so the whole forecast is a single transaction/round trip and no-op rows are not even touched (so the audit trigger does not fire for them):
```sql
create or replace function save_opportunity_forecast(p_deal_id bigint, p_months jsonb) returns bigint
language plpgsql as $$
declare v_stream bigint;
begin
  insert into revenue_streams(deal_id, stream_type, locked) values (p_deal_id, 'opportunity', false)
  on conflict (deal_id, stream_type) do update set deal_id = excluded.deal_id returning id into v_stream;
  insert into revenue_stream_months(stream_id, month, opportunity_revenue, opportunity_margin)
  select v_stream, m->>'month', (m->>'revenue')::numeric, (m->>'margin')::numeric from jsonb_array_elements(p_months) m
  on conflict (stream_id, month) do update
    set opportunity_revenue = excluded.opportunity_revenue, opportunity_margin = excluded.opportunity_margin
    where revenue_stream_months.opportunity_revenue is distinct from excluded.opportunity_revenue
       or revenue_stream_months.opportunity_margin  is distinct from excluded.opportunity_margin;
  return v_stream;
end $$;
```
Client: `api('rpc/save_opportunity_forecast', 'POST', { p_deal_id: dealId, p_months: rows })` — the proxy path rewrite already maps `/sb/rpc/...` to `/rest/v1/rpc/...`. (Deleting months the user cleared to 0 — today they are silently kept — can be added as a `delete ... where month not in (...)` if that behaviour is wanted.)
```

### OPP-02 — Opening a deal is 8-11 sequential round trips that are all keyed by the deal id

**Impact high · effort M · parallelise · spot-checked (confidence 0.9)**

- **Where:** /home/user/Focus/index.html:5148-5208 (openOpportunity) -> 5153, 5160, 5162, 5566, 10453, 10027-10038, 9184, 9085, 9093; also revertOpp 5358 which re-runs the whole chain
- **Evidence:** 5153 `const deals = await apiGet('deals', 'id=eq.' + id + '&select=*');` → 5160 `const streams = await apiGet('revenue_streams', 'deal_id=eq.' + id + ...)` → 5162 `const months = await apiGet('revenue_stream_months', 'stream_id=eq.' + streams[0].id ...)` → 5176 `await initOppForm()` (5566 `await apiGet('service_sub', 'active=eq.true...')` on first open) → 5181 `await displayOwner()` → 5182 `await loadCollaborators(id)` (10453 GET deal_collaborators) → 5183 `await loadOppContacts(id)` (10027 GET deal_contacts → 10031 dmu_roles first time → 10038 GET person_organisation_roles) → 5184 `await loadEngagements(id)` (9184 GET engagements → 9085 GET leads?promoted_deal_id → 9093 GET engagements?lead_id). Every await depends only on `id` (or `oppData.org_id`), never on the previous response, except the months fetch (needs stream id) and the lead-engagement fetch (needs lead id) — both removable via PostgREST resource embedding. The FK paths for embedding exist: revenue_streams.deal_id, revenue_stream_months.stream_id (schema.sql:2692), deal_collaborators.deal_id (2308), deal_contacts (opportunity_contacts_deal_id_fkey 2612), engagements.deal_id (2412), leads.promoted_deal_id (2532), engagements.lead_id (unify_engagements.sql).
- **Mechanism:** Sequential chain of ~8 proxied GETs (≈11 s) — plus 2-3 more on the first deal opened in a session (service_sub, dmu_roles) and 1 more for promoted deals — where a single embedded GET or a 2-level Promise.all would do. Revert (5358) pays the whole chain again after its PATCH.
- **Who feels it:** Every click on a deal in the register, Deal Admin 'Edit', dashboard links and 'Open the opportunity' buttons (callers at 11853, 13747, 14500, 15158, 16878, 17647, 18199, 25388): 11-15 s of spinner before the form and tabs are usable. Revert doubles it.

- **Fix:**

```sql
Fetch everything in one embedded GET (depth 1), or at minimum one Promise.all (depth 2):
```js
const [dealRows, collabs, contacts, engs, leadRows] = await Promise.all([
  apiGet('deals', `id=eq.${id}&select=*,revenue_streams(id,locked,revenue_stream_months(month,opportunity_revenue,opportunity_margin))&revenue_streams.stream_type=eq.opportunity`),
  apiGet('deal_collaborators', `deal_id=eq.${id}&select=*`),
  apiGet('deal_contacts', `deal_id=eq.${id}&select=*`),
  apiGet('engagements', `deal_id=eq.${id}&select=*&order=engagement_date.desc,created_at.desc`),
  apiGet('leads', `promoted_deal_id=eq.${id}&select=id,target_org_name,site_id,site_name,description,promoted_at,sites(name),engagements(*)&engagements.order=engagement_date.desc,id.desc`),
]);
oppData = dealRows[0]; const stream = (oppData.revenue_streams || [])[0];
(stream?.revenue_stream_months || []).forEach(m => oppMonths[m.month] = { revenue: m.opportunity_revenue, margin: m.opportunity_margin });
// second (last) level — needs org_id / person ids from level 1
await Promise.all([
  ensurePeopleInCache([...collabs, ...contacts].map(r => r.person_id)),
  apiGet('person_organisation_roles', `org_id=eq.${oppData.org_id}&end_date=is.null&select=person_id,job_title`).then(a => oppOrgAffiliations = a),
]);
```
Then change loadCollaborators/loadOppContacts/loadEngagements to accept pre-fetched rows (they currently fetch internally). Keep the engs array and affiliations in page-scoped variables (e.g. `oppEngagements`, `oppOrgAffiliations`) for reuse by OPP-04/05/06. The whole embedded set can even collapse to ONE call by embedding `deal_collaborators(*),deal_contacts(*),engagements(*)` in the deals select and `organisations(id,name,legal_name,person_organisation_roles(person_id,job_title))&organisations.person_organisation_roles.end_date=is.null`. Also fold the first-open lookups into the same Promise.all: dmu_roles (10031) and service_sub (5566 — the warmed allData['service_sub'] already holds these rows with the `active` column, so filter client-side instead of a second fetch under a different key). Net: 11-15 s → ~1.5-3 s.
```

### OPP-03 — Securing a deal issues 2N+19 sequential round trips, PATCHes the deal row three times and re-reads the months it just wrote twice

**Impact high · effort M · parallelise · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:9281-9376 (saveOpportunity), 9424-9471 (runSecuredProcess), 9516-9599 (maybeOfferExtensionProspect)
- **Evidence:** After the main PATCH at 9346 and the 2N month loop (OPP-01): 9441 `await api('deals', 'PATCH', { probability: 100 }, ...)`; 9446-9449 `GET revenue_streams` + `GET revenue_stream_months?stream_id=in.(...)` to build `pipeline`; 9457 POST secured_snapshots; 9466 PATCH revenue_streams locked; then 9530 GET deals (extension check); 9533-9534 the SAME two GETs again (`const streams = await apiGet('revenue_streams', ...); const monthRows = await apiGet('revenue_stream_months', ...)`); 9549 `await api('deals', 'PATCH', { contract_end_date: iso(endDate) }, ...)`; only then 9556 confirmDialog; then 9558/9580/9594 three sequential POSTs. The client already knows at 9329 (`+stageId === 5 && +prevStageId !== 5`) that it is securing, and already holds the months in `oppMonths`.
- **Mechanism:** ≈13 + 2N sequential round trips before the user even sees the 'Create extension prospect?' dialog, then 3 more, then the register re-render. Three separate UPDATEs on the same deals row (each an audit_log row and a heap tuple), two redundant re-reads of revenue_stream_months, and no parallelism between independent writes (org PATCH, snapshot POST, stream lock, extension check).
- **Who feels it:** Every deal secured (the most consequential action in the CRM): 1-2 minutes of blocking spinner for a 12-36 month contract; the confirm dialog appears only after ~1 min, so users think the save hung. Also risk of partial state if they navigate away mid-chain.

- **Fix:**

```sql
Client-side folding (effort M): (1) when securing, put `probability: 100` and `contract_end_date` (computable from oppMonths' last month) into the single PATCH payload at 9346; (2) build `pipeline` from `oppMonths` in memory instead of 9446-9449 and 9533-9534; (3) run the independent securing writes together:
```js
await Promise.all([
  secOrg?.client_status === 'Prospect' ? api('organisations','PATCH', orgPatch, 'id=eq.'+secOrg.id) : null,
  api('secured_snapshots','POST', { deal_id: deal.id, pipeline, secured_by: currentUser?.personId || null }, ''),
  api('revenue_streams','PATCH', { locked: true }, `deal_id=eq.${deal.id}&stream_type=eq.opportunity`),
  apiGet('deals', `parent_deal_id=eq.${deal.id}&opportunity_type=eq.extension&select=id`),
]);
```
With OPP-01 the pre-dialog path becomes PATCH deals ∥ month upsert → 1 parallel batch → dialog: depth 2 instead of 2N+13. (4) Extension creation: `POST deals` → `POST revenue_streams` → `POST months` can be one RPC `create_extension_prospect(p_parent_deal_id, p_start, p_term, p_run_rate, ...)` (depth 1 instead of 3).

Server-side alternative (effort L, cleanest): `secure_deal(p_deal_id bigint)` RPC that in ONE transaction sets probability/contract_end_date, flips the org to Active, inserts the secured_snapshots row via `jsonb_agg` over revenue_stream_months (no months shipped twice), locks the stream and returns `{term_months, run_rate, has_extension}` for the confirm dialog.
```

### OPP-04 — 'Log engagement' modal re-fetches the deal, collaborators, org affiliations and the full engagement list the page already holds (4 sequential round trips)

**Impact medium · effort M · query shape · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:8992-9003 (openDealEngagementModal) -> 25741-25834 (_liLoadPeople deal branch), 25969-25978 (_liInitStreamSection), 25041-25053 (_liRenderMilestones)
- **Evidence:** 8999-9002 `await loadLiLookups(); await _liLoadPeople(); await _liInitStreamSection();` — three sequential awaits. Inside: 25812-25815 `Promise.all([apiGet('deals', `id=eq.${parent.id}&select=org_id`), apiGet('deal_collaborators', ...)])` → 25820 `await apiGet('person_organisation_roles', `org_id=eq.${deal.org_id}&select=person_id`)` → 25977 `await apiGet('engagements', `${filter}&select=id,stream_id,...&limit=1000`)`. Concurrently 25051 `parent.dealRow = (await apiGet('deals', `id=eq.${parent.id}&select=id,stage_id,service_sub_id`))[0]` — always fetched because 8994 assigns a fresh `_engParent` object each open. Yet `oppData.org_id`, `oppData.stage_id/service_sub_id`, `oppCollaborators` (10435), the org affiliations (10038) and the engagements array (9184) were all loaded when the deal was opened; 25825 even already reads `oppCollaborators` for unsaved rows.
- **Mechanism:** 4 sequential proxied GETs (≈5-6 s; 7-9 calls on the first open in a session) to open a modal, all re-fetching data resident in page memory for the open deal.
- **Who feels it:** Every engagement logged from the deal page — the most frequent write action for sales users — starts with a 5-6 s wait before the form is usable.

- **Fix:** Reuse the open deal's page state (these are per-open-deal variables refreshed on every open/save, not a lookup cache): in _liLoadPeople / _liInitStreamSection / _liRenderMilestones, when `parent.kind === 'deal' && oppData && +oppData.id === +parent.id`: `parent.dealRow = oppData`; `ids = oppCollaborators.map(c => +c.personId)`; `links = oppOrgAffiliations` (store the 10038 result on open); `rows = oppEngagements` (store the 9184 result on open, and pass the narrower fields). That makes the modal open with 0 round trips on a warm session (1 on the first open for activity_types/next_actions). For the dashboard/standalone path where the deal is not open, keep the fetches but run them in one Promise.all (deals+collabs ∥ engagements, then por) → depth 2 instead of 4.

### OPP-05 — Clicking an engagement row re-fetches the engagement, the deal (twice), collaborators and affiliations — 6 sequential round trips for data already rendered

**Impact medium · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:25514-25546 (openEngagement), called from the row onclick at 9136; plus 25051 and 25787-25820
- **Evidence:** 25516 `eng = (await apiGet('engagements', `id=eq.${engId}&select=*`))[0]` — the full row is already in the `engs` array rendered by _engStreamTableHtml (9184/9102); 25524 `const d = (await apiGet('deals', `id=eq.${eng.deal_id}&select=id,name`))[0]` — equals oppData.name; then loadLiLookups → _liRenderMilestones (25051 GET deals again, 25060 GET engagement_milestones) → _liLoadPeople: 25787 GET engagement_people → 25812 Promise.all(GET deals org_id, GET deal_collaborators) → 25820 GET person_organisation_roles.
- **Mechanism:** 6 sequential proxied GETs (≈8 s), of which only engagement_people and engagement_milestones carry information not already on the page.
- **Who feels it:** Every time a user opens an engagement from the deal's Engagement tab to read or edit it: ~8 s wait. Users typically open several per deal review.

- **Fix:** 1) Pass the row: change the row onclick at 9136 to `openEngagement(${e.id})` with `openEngagement` first checking `oppEngagements.find(x => +x.id === +engId)` (page-scoped array from OPP-02) before fetching; set parent from `oppData` when `+eng.deal_id === +oppData.id`. 2) Apply OPP-04's reuse in _liLoadPeople/_liRenderMilestones. 3) Fetch the two genuinely-needed tables in parallel: `Promise.all([apiGet('engagement_people', ...), apiGet('engagement_milestones', ...)])`. Result: depth 1 (~1.4 s). For the standalone case (dashboard), replace 25516+25524 with one embedded GET: `engagements?id=eq.E&select=*,deals(id,name),leads(id,target_org_name,description,site_id,site_name,sites(name))`.

### OPP-06 — Saving an engagement is 6-8 sequential writes/reads plus a 2-3 call list reload; the new-stream self-PATCH and per-person POSTs are avoidable

**Impact medium · effort M · query shape · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/index.html:26134-26330 (saveLeadInteraction deal branch): 26185, 26243, 26262-26276, 26282 (-> 25095-25118), 26298-26300, 26319 (-> loadEngagements 9178-9192)
- **Evidence:** 26273 `await api('engagements', 'PATCH', { stream_id: engId, stream_label: ... }, 'id=eq.' + engId)` — a second write to the row just inserted, only to set stream_id = its own id. 26300 `for (const p of (window._liPeople || [])) { ... await api('engagement_people', 'POST', { engagement_id: engId, person_id: +p.person_id }, '') }` — one POST per person, sequential, inside a try that swallows the duplicate error that `UNIQUE (engagement_id, person_id)` (schema.sql:1785) would raise. 25095-25118 loops one POST/PATCH/DELETE per milestone checkbox. Then 26319 `await loadEngagements(par.id)` → GET engagements → GET leads → [GET engagements] rebuilds the whole tab. The engagement row returned by the POST (`select=*`, 26247) is discarded for rendering.
- **Mechanism:** Sequential chain of ~7 proxied round trips (duplicate-shield GET, POST, 1-2 stream PATCHes, M milestone writes, P people POSTs, 2-3 reload GETs) ≈ 10-14 s, with each write firing the engagements audit trigger (add_audit_log.sql:75) — the self-PATCH produces a second audit_log row for the same insert.
- **Who feels it:** Every engagement logged or edited from the deal page: 10-14 s from clicking Save until the list shows the new row. Combined with OPP-04, logging one engagement costs ~20 s of waiting.

- **Fix:**

```sql
1) Default stream_id server-side so the self-PATCH disappears (send `stream_label` in the POST body when mode === 'new'):
```sql
create or replace function engagements_default_stream() returns trigger language plpgsql as $$
begin if new.stream_id is null and new.lead_id is null then new.stream_id := new.id; end if; return new; end $$;
create trigger engagements_default_stream before insert on engagements for each row execute function engagements_default_stream();
```
(BEFORE INSERT sees the sequence-assigned id; scope the condition to match how streams are used today.)
2) engagement_people as one array POST: `api('engagement_people', 'POST', people.map(p => ({ engagement_id: engId, person_id: +p.person_id })), 'on_conflict=engagement_id,person_id', 'resolution=ignore-duplicates,return=minimal')` (needs the extraPrefer param from OPP-01).
3) Run the independent post-insert writes together: `await Promise.all([supersedePatch, peoplePost, _liSyncMilestones(engId)])` (and batch milestone writes into one array POST/one DELETE with `id=in.(...)`).
4) Refresh without a reload chain: splice `res[0]` into `oppEngagements` (mark the superseded row done locally — the client knows exactly which row it patched) and re-run `_engStreamTableHtml`; or at least make loadEngagements fetch its 2-3 GETs in one Promise.all (deal engagements ∥ leads with embedded engagements). Net depth: ~7 → 3 (shield GET → POST → parallel batch).
```

### OPP-07 — getCollaboratorPool opens the Add-Collaborator modal with up to 7 sequential round trips, three of them re-fetching people already in allData

**Impact medium · effort S · parallelise · reviewer (confidence 0.9)**

- **Where:** /home/user/Focus/index.html:10500-10547 (getCollaboratorPool), called from openAddCollaboratorModal 10549
- **Evidence:** 10504 `await apiGet('person_organisation_roles', `org_id=eq.${orgId}&select=person_id`)` → 10507 `await apiGet('people', `id=in.(...)`)` → 10514 `allData['roles'] || await apiGet('roles', ...)` → 10518 `await apiGet('home_organisation_members', `role_id=in.(...)&select=person_id`)` → 10521 `await apiGet('people', `id=in.(...)`)` → 10527 `await apiGet('parties', ...)` → 10529 `await apiGet('people', `id=in.(...)`)`. The three branches (client affiliates, home-org members, parties) are independent, and allData['people'] is warmed with `select=*` at login (LOOKUP_CONFIG 2127), so the three `people?id=in` fetches only need `ensurePeopleInCache` for stragglers.
- **Mechanism:** 7 sequential proxied GETs (≈10 s) where 3 independent GETs in parallel plus at most one people fetch would do.
- **Who feels it:** Anyone adding a collaborator to a deal waits ~10 s for the picker to appear. Less frequent than logging engagements, but it is a blocking spinner on a small modal.

- **Fix:**

```sql
```js
const [affs, members, parties] = await Promise.all([
  orgId ? apiGet('person_organisation_roles', `org_id=eq.${orgId}&select=person_id`) : [],
  eligibleRoleIds.length ? apiGet('home_organisation_members', `role_id=in.(${eligibleRoleIds.join(',')})&select=person_id`) : [],
  apiGet('parties', 'party_type=eq.person&status=eq.active&select=ref_id'),
]);
const ids = [...new Set([...affs.map(a => +a.person_id), ...members.map(m => +m.person_id), ...parties.map(p => +p.ref_id).filter(Boolean)])];
await ensurePeopleInCache(ids);   // 0-1 round trip
const pool = allData['people'].filter(p => ids.includes(+p.id) && !existingIds.has(+p.id));
```
(`allData['roles']` is normally cached; if not, fetch it in the same Promise.all and filter members client-side.) When the deal page is open, `affs` is already `oppOrgAffiliations` from OPP-02, saving one more call. Depth 7 → 1-2.
```

### OPP-08 — No index on engagements(deal_id) or engagements(org_id): every deal-engagement query is a sequential scan of the whole engagements table

**Impact medium · effort S · db index · spot-checked (confidence 0.65)**

- **Where:** /home/user/Focus/sql/unify_engagements.sql:48 (only idx_engagements_lead exists); queried at index.html:9184, 25977, 26185 (deal_id=eq), 14471 (deal_id=in), 14473 (org_id=in)
- **Evidence:** index_inventory.txt lists `CREATE INDEX IF NOT EXISTS idx_engagements_lead ON public.engagements (lead_id)` and nothing on deal_id or org_id; schema.sql:2412 shows the FK `engagements_deal_id_fkey` and Postgres does not auto-index FK columns. predicates.txt: engagements is filtered by `deal_id=eq` (1), `deal_id=in` (1), `org_id=in` (2), `org_id=not` (1), and ordered by `engagement_date.desc` (7 variants). engagements is the unified log for leads, deals, organisations and work projects (unify_engagements.sql), so it is the fastest-growing business table.
- **Mechanism:** Each `deal_id=eq.X` / `org_id=in.(...)` predicate forces a full heap scan + sort of engagements (text notes make rows wide). ASSUMPTION on volume: at thousands of rows this is ~5-20 ms per query (minor next to the 1.4 s round trip); at tens of thousands it becomes tens of ms per call and is hit 3× per engagement logged (open page, open modal, duplicate shield) and once per deal opened. Cost grows linearly with total engagement history.
- **Who feels it:** Small today per call, but it is on the critical path of every deal open and every engagement log/save, and it degrades steadily as history accumulates — consistent with 'slowing down over time'.

- **Fix:**

```sql
```sql
create index if not exists engagements_deal_id_date_idx on engagements (deal_id, engagement_date desc) where deal_id is not null;
create index if not exists engagements_org_id_idx on engagements (org_id) where org_id is not null;
```
The composite serves both the filter and the `order=engagement_date.desc` used at 9184/25977 without a sort. Partial indexes keep them small (most rows are lead engagements). Run `explain analyze select * from engagements where deal_id = <id> order by engagement_date desc` before/after to confirm.
```

### OPP-09 — No index on leads(promoted_deal_id): every deal open sequential-scans the leads table for the 'before promotion' history

**Impact low · effort S · db index · reviewer (confidence 0.65)**

- **Where:** /home/user/Focus/index.html:9085 (_dealLeadHistoryHtml, called from loadEngagements 9186 on every open and after every engagement save); FK at sql/schema.sql:2532
- **Evidence:** 9085 `apiGet('leads', `promoted_deal_id=eq.${dealId}&select=id,target_org_name,site_id,site_name,description,promoted_at,sites(name)`)`. index_inventory.txt has idx_leads_owner_id, idx_leads_status, idx_leads_source_id, idx_leads_research_campaign, idx_leads_next_action_date — nothing on promoted_deal_id. predicates.txt: `promoted_deal_id=eq` used twice.
- **Mechanism:** Full scan of leads (a wide table with jsonb `contacts` and long descriptions) for a lookup that matches at most one row; runs once per deal open and once per engagement save on the deal page. ASSUMPTION: leads holds thousands of rows → a few ms each today, growing with the register.
- **Who feels it:** Adds a few ms of DB time to every deal open and engagement save; low today, but it is a pure win and the query is on the hot path.

- **Fix:**

```sql
```sql
create index if not exists leads_promoted_deal_id_idx on leads (promoted_deal_id) where promoted_deal_id is not null;
```
(Partial: only promoted leads carry a value, so the index stays tiny.)
```

### OPP-10 — person_organisation_roles is filtered by org_id (17 call sites, 4 in this slice) but its only index leads with person_id

**Impact low · effort S · db index · reviewer (confidence 0.6)**

- **Where:** sql/schema.sql:1969 (UNIQUE (person_id, org_id)); queried by org_id at index.html:10038 (loadOppContacts, every deal open), 10102 (openAddOppContactModal), 10504 (getCollaboratorPool), 25820 (_liLoadPeople, every engagement modal)
- **Evidence:** `ADD CONSTRAINT person_organisation_roles_person_id_org_id_key UNIQUE (person_id, org_id)` gives a btree on (person_id, org_id) — usable for `person_id=eq` but not as an index range scan for `org_id=eq.O` (org_id is the second column). No other index exists (index_inventory.txt, grep of sql/). predicates.txt: `17 org_id=eq`, `8 end_date=is` on this table.
- **Mechanism:** Sequential scan of person_organisation_roles for every org-scoped affiliation lookup. ASSUMPTION on volume: one row per person per org (thousands) → ~1-5 ms per query today; grows with the contact base. Hit on every deal open and every engagement modal.
- **Who feels it:** Minor per call, but affiliations are looked up 2-3 times per deal opened and once per engagement logged; a cheap, permanent win.

- **Fix:**

```sql
```sql
create index if not exists por_org_open_idx on person_organisation_roles (org_id, person_id) where end_date is null;
create index if not exists por_org_idx on person_organisation_roles (org_id);   -- for the call sites that do not filter on end_date (10504, 25820)
```
Or add `&end_date=is.null` to 10504/25820 (they arguably should exclude ended affiliations) and keep only the partial index.
```

### OPP-11 — Row-level audit trigger on revenue_stream_months multiplies the per-month write cost and audit_log growth on every forecast save

**Impact low · effort S · db trigger · reviewer (confidence 0.6)**

- **Where:** /home/user/Focus/sql/add_audit_log.sql:31-56 (audit_row_change) and :75-77 (attached to 'revenue_streams','revenue_stream_months' among 17 tables); driven by index.html:9407/9409
- **Evidence:** The trigger runs FOR EACH ROW: on UPDATE it builds `to_jsonb(new)` and `to_jsonb(old)`, joins `jsonb_each` of both (11 columns) and inserts an audit_log row unless nothing changed (line 44 early return); on INSERT it inserts a full `row_data` jsonb snapshot per month row. With the current per-month loop each of the N writes is its own PostgREST transaction, so a first-time 36-month forecast produces 36 audit_log inserts across 36 transactions, and every later Save re-runs 36 UPDATE diffs (and writes 36 new heap tuples + unique-index entries even when values are identical, because Postgres does not skip identical UPDATEs).
- **Mechanism:** Trigger + audit insert amplification (N trigger executions and up to N audit_log rows per save), compounded by N separate transactions. Secondary to the round-trip cost in OPP-01, but it is also the largest audit_log producer on this page (deals itself yields 1 row per save).
- **Who feels it:** Adds DB work to each of the 2N round trips in flow 3/4 and inflates audit_log (which the admin audit UI then has to page through). Users feel it only as part of the long Save.

- **Fix:**

```sql
1) After OPP-01, the N trigger firings happen inside one statement/transaction — the per-statement overhead disappears and the RPC's `where ... is distinct from excluded...` clause means unchanged months are not written at all, so the trigger does not fire for them. 2) Optional policy choice: drop revenue_stream_months from the audited table list in add_audit_log.sql (the forecast is already frozen per deal in secured_snapshots at securing, and revenue_streams stays audited), or replace it with a per-statement summary:
```sql
drop trigger if exists audit_revenue_stream_months on revenue_stream_months;
```
Keep it if per-month history is genuinely used by the audit UI — then (1) alone is the fix.
```

### OPP-12 — Collaborators, contacts, engagement people and owner-sync are written one row per request on the Save critical path

**Impact low · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:10771-10790 (saveCollaborators), 10420-10432 (saveOppContacts), 5470-5488 (syncDealOwnerCollaborator), 26298-26300 (engagement_people)
- **Evidence:** 10787 `for (const c of oppCollaborators) { if (!c.isNew) continue; await api('deal_collaborators', 'POST', {...}, ''); }`; 10423 same pattern for deal_contacts, catching `23505` duplicates by string match; 5473-5486 `PATCH deal_collaborators ... person_id=neq.` → `GET deal_collaborators ...&select=id` → `PATCH` or `POST` (3 sequential); all three tables have the UNIQUE constraints upserts need: deal_collaborators (deal_id, person_id) schema.sql:1745, deal_contacts (deal_id, person_id) 1897, engagement_people (engagement_id, person_id) 1785.
- **Mechanism:** K sequential round trips for K new rows (each also an audit_log insert), plus 3 sequential calls for owner sync, all awaited before the page closes and the register re-renders.
- **Who feels it:** Usually 0-2 extra round trips per Save (1.4-3 s) — noticeable on new deals (owner + collaborators + contacts) and on manager owner-reassignments (+3 round trips).

- **Fix:** One array POST per table with the existing unique key: `api('deal_collaborators','POST', rows, 'on_conflict=deal_id,person_id', 'resolution=ignore-duplicates,return=minimal')` (same for deal_contacts / engagement_people), run in `Promise.all` alongside saveRevenueStream. Owner sync as two parallel calls: `Promise.all([ api('deal_collaborators','PATCH',{is_owner:false},`deal_id=eq.${dealId}&person_id=neq.${newOwnerId}`), api('deal_collaborators','POST',{deal_id:dealId, person_id:newOwnerId, role:'Owner', is_owner:true}, 'on_conflict=deal_id,person_id', 'resolution=merge-duplicates') ])` — 3 sequential → 1 parallel batch; or fold both into a `set_deal_owner(deal_id, person_id)` RPC.


## Leads register and campaign pages

### LR-01 — Every status-tab / scope click re-runs the whole leads network load (5 GETs + touches + sweeps) to filter an array already in memory

**Impact high · effort S · query shape · spot-checked (confidence 0.9)**

- **Where:** index.html:14789 (tab onclick → renderLeadsPage()), 11659 (setOwnerView → renderLeadsPage), 23615 (countdown expiry → renderLeadsPage), 17653 (closeLeadPage → renderLeadsPage); the filter itself is client-side at 14757 and 14821
- **Evidence:** 14789: onclick="leadsViewTab='${t.key}'; renderLeadsPage();" — renderLeadsPage (14701) declares `let [leads, sources, regions, ...] = await Promise.all([...apiGetAll('leads'...), apiGet('organisations','select=*'), apiGet('sites','select=*') ...])` (14727-14743), then `await _loadOrgTouches(true)` (14749), `await sweepNewToWorking` / `sweepHoldWake` (14753-14754). The active tab only does `leads.filter(activeTab.filter)` (14821). `leads` is function-local, so nothing survives between clicks.
- **Mechanism:** Extra sequential round trips: depth ≥2 (≈2.8 s) plus re-running the write sweeps and re-parsing the full leads/organisations/sites payloads, for a change that is a pure in-memory filter. Also re-renders the tab bar and the whole table.
- **Who feels it:** Every salesperson, many times a day: each click on Raw / Working / Nurture / Hold / Review / Promoted / Dead, or Show Own/All/Team, freezes the register for ~3 s (longer when a sweep has work). Returning from a lead form pays the same.

- **Fix:** Split renderLeadsPage into loadLeadsRegister() (network + sweeps; stores `_leadsReg = { leads, sources, regions, people, orgs, sites }` in a module-level variable — in-memory page state exactly like cockpitData, no localStorage) and paintLeadsRegister() (filterLeadsByView + tab bar + makeSortableFilterableTable). Tab and scope buttons call `leadsViewTab=...; paintLeadsRegister()`. closeLeadPage (17653) refetches only the changed lead: `const [row] = await apiGet('leads','id=eq.'+leadData.id+'&select=<register cols>'); Object.assign(_leadsReg.leads.find(l=>+l.id===+row.id), row); paintLeadsRegister();` — 1 narrow GET instead of 4+. tickEditCountdowns (23615) → paintLeadsRegister() (status flip happens in memory from computeLeadStatus).

### LR-02 — App-layer sweeps PATCH eligible leads one at a time on every register/cockpit/dashboard load (N+M sequential writes, each firing the audit trigger)

**Impact high · effort M · db trigger · spot-checked (confidence 0.8)**

- **Where:** index.html:23492-23512 sweepHoldWake, 23517-23533 sweepNewToWorking; called at 14753-14754 (register), 15592-15593 (cockpit), and from _attentionLeadItems (~12140, dashboard). applyGroupStageCohesion 14395-14420 (per flipped lead: 2 GETs + k PATCHes).
- **Evidence:** 23499-23509: `for (const l of due) { ... await api('leads','PATCH', patch, 'id=eq.' + l.id); }`; 23527-23532: `for (const l of toFlip) { ... await api('leads','PATCH', ...); applyGroupStageCohesion(l,'Working'); }` — applyGroupStageCohesion (14395) does `await _groupMemberLeads(top)` (GET sites, GET leads) then `for (const m of pulled) await api('leads','PATCH',...)`. Comment at 23522: "replaces the retired DB status triggers". sql/add_audit_log.sql:75-82 attaches audit_row_change to leads (to_jsonb(new)/to_jsonb(old), jsonb_each join, audit_log insert with 3 indexes) per PATCH.
- **Mechanism:** Sequential round trips proportional to the number of eligible leads (~1.4 s each), issued by every user who opens the page (racing to do identical flips), plus per-row trigger work. The wake sweep is purely date-driven (`wake_date <= today`) and needs no user at all; the New→Working flip depends on first_engaged_at which is already stamped by a DB trigger on engagements.
- **Who feels it:** Anyone opening the register, a cockpit, or the dashboard the morning after several Hold leads come due, or when several New leads have just met the Working criteria: each such lead adds ~1.4 s (plus 2.8 s + k×1.4 s of background cohesion traffic competing for the browser's 6 connections and the Netlify function). Unpredictable page-load times.

- **Fix:** Move both sweeps server-side so page load issues ZERO writes. (1) Hold wake as a daily pg_cron job (Supabase has pg_cron): `select cron.schedule('wake-held-leads','5 22 * * *', $$update leads set wake_date=null, woke_at=now(), working_at=coalesce(working_at,now()), status=case when fit=2 and trigger_score=2 and access=2 and capacity=2 and service_major_id is not null and (target_org_id is not null or nullif(trim(target_org_name),'') is not null) and not coalesce(qualification_demoted,false) then 'Qualified' else 'Working' end, updated_at=now() where status='Hold' and wake_date<=current_date and promoted_at is null and dead_reason is null$$);` (22:05 UTC = 00:05 SAST). (2) New→Working: extend the existing engagements trigger that stamps first_engaged_at to also run `update leads set status='Working', working_at=coalesce(working_at,now()), updated_at=now() where id=NEW.lead_id and status='New' and dead_reason is null and wake_date is null and promoted_at is null and nullif(trim(description),'') is not null and next_action is not null and next_action_date is not null and first_engaged_at is not null and <source/target completeness as SQL>`. Interim (if the SQL criteria port is deferred): a single SECURITY DEFINER RPC `create function sweep_leads() returns setof leads language sql as $$ with w as (update leads ... returning *), n as (update leads ... returning *) select * from w union all select * from n $$;` called ONCE inside the Promise.all via `api('rpc/sweep_leads','POST',{})` — one round trip instead of N+M, and the returned rows are merged into the in-memory list. Group cohesion (14395) becomes a set-wise UPDATE in the same function.

### LR-06 — Do the register's joins in Postgres: a leads_register view makes the page ONE narrow round trip and removes all client-side .find() joins and the touches scan

**Impact high · effort L · db view or rpc · reviewer (confidence 0.7)**

- **Where:** index.html:14727-14749 (5-6 fetches), 14835-14863 (cols get() lookups), 14878-14893 (leadsGroupRenderer/leadBandOf), 14932-15060 (renderLeadRow lookups), 14286 (_loadOrgTouches); sql/ has no app views today
- **Evidence:** The register joins leads→lead_sources/regions/branches/people/sites/organisations(→parent chain)/industry_sectors and engagements(max date per org) entirely in the browser: `sources.find(...)`, `regions.find(...)`, `people.find(...)`, `orgs.find(...)` per row (14933-14937, 14852-14863), `leadBandOf` → `_ultimateParentOrg` walk per row (14882, 14210), `_leadSectorName` → 3 finds (11752, 11746), `leadEffectiveTouch` → `_groupTouchFor` chain walk (14319, 14303). Every one of those inputs is fetched as a separate table.
- **Mechanism:** Replaces 5-6 parallel table fetches + 1 sequential touches fetch + O(rows × (|orgs|+|sites|+|people|)) client joins with a single indexed query returning exactly the ~35 columns the rows display. Depth 2 → 1, bytes ≈ rows × 300 B, client CPU ≈ O(rows).
- **Who feels it:** Every register load/tab click for every user — and it scales: adding organisations/sites/people no longer slows the leads page at all.

- **Fix:**

```sql
```sql
create or replace view leads_register_v as
with recursive fam as (
  select id, id as top_id, parent_org_id, 0 as depth from organisations
  union all
  select f.id, o.id, o.parent_org_id, f.depth+1 from fam f join organisations o on o.id=f.parent_org_id where f.depth<10
), top as (select distinct on (id) id, top_id from fam order by id, depth desc),
cli as ( -- lead → client org: linked org, else site's org, else case-folded name match
  select l.id as lead_id, coalesce(l.target_org_id, s.organisation_id, nm.id) as org_id
  from leads l left join sites s on s.id=l.site_id
  left join organisations nm on l.target_org_id is null and s.id is null and lower(trim(nm.name))=lower(trim(l.target_org_name)) and nm.active is not false and not nm.home_organisation)
select l.id,l.status,l.owner_id,l.region_id,l.branch_id,l.source_id,l.site_id,l.site_name,l.target_org_id,l.target_org_name,
       l.fit,l.trigger_score,l.access,l.capacity,l.next_action,l.next_action_date,l.last_touch_date,l.promoted_at,l.promoted_deal_id,
       l.promotion_requested_at,l.promotion_request_type,l.promotion_request_note,l.dead_reason,l.dead_notes,l.working_at,l.wake_date,l.first_engaged_at,l.created_at,
       ls.name as source_name, r.name as region_name, b.name as branch_name,
       trim(p.first_name||' '||coalesce(p.last_name,'')) as owner_name,
       s.name as site_label,
       co.id as client_org_id, co.name as client_label, sec.name as sector_name,
       t.top_id as band_org_id, po.name as band_label, po.collective_since as band_collective_since,
       (select count(*) from top t2 where t2.top_id=t.top_id) as band_family_size,
       gt.last_touch as group_touch_date
from leads l
left join cli on cli.lead_id=l.id
left join lead_sources ls on ls.id=l.source_id
left join regions r on r.id=l.region_id
left join branches b on b.id=l.branch_id
left join people p on p.id=l.owner_id
left join sites s on s.id=l.site_id
left join organisations co on co.id=cli.org_id
left join industry_sectors sec on sec.id=co.sector_id
left join top t on t.id=co.id
left join organisations po on po.id=t.top_id
left join lateral (
  select max(e.engagement_date) as last_touch from engagements e
  join fam f on f.id=co.id and e.org_id=f.top_id   -- ancestor chain
  join organisations a on a.id=e.org_id and a.group_touch_soothes is not false
  where e.work_mode is distinct from 'internal') gt on true;
```
Client: `apiGetAll('leads_register_v', 'select=*&order=created_at.desc' + scope)` (scope as in LR-04); cols.get read `l.source_name`, `l.client_label`, `l.band_org_id` etc.; band key = `'o'+band_org_id` or `'x'+id`. Supporting indexes: organisations(parent_org_id), sites(organisation_id), engagements(org_id, engagement_date desc) where org_id is not null, leads(owner_id) [exists], leads(created_at desc). Keep the people/orgs allData intact for the lead form — the register simply stops depending on them.
```

### LR-03 — _loadOrgTouches(true) adds a sequential whole-engagements scan to every register render (no org_id index, capped at 1000 rows)

**Impact medium · effort S · db view or rpc · spot-checked (confidence 0.85)**

- **Where:** index.html:14749 (call, after the Promise.all), 14286-14299 (_loadOrgTouches); sql: only idx_engagements_lead exists on engagements (unify_engagements.sql:48; index_inventory.txt)
- **Evidence:** 14749: `await _loadOrgTouches(true);` runs after `await Promise.all([...])` at 14727. 14290: `apiGet('engagements', 'org_id=not.is.null&select=org_id,engagement_date,work_mode')` then a JS max() per org. `force=true` bypasses the in-memory memo every render. No `CREATE INDEX ... engagements (org_id)` anywhere in sql/. apiGet (not apiGetAll) → PostgREST 1000-row cap.
- **Mechanism:** One extra sequential ~1.4 s round trip per render; server-side a sequential scan of the entire engagements table (every deal + lead touch ever logged) filtered to org_id IS NOT NULL, shipping one row per collective engagement instead of one row per org; client folds to max(). Grows with total activity volume, not with leads.
- **Who feels it:** Every register load and every tab click (LR-01) — an unconditional +1.4 s. Assumption: engagements is the largest, fastest-growing table; at a few thousand rows the DB time is milliseconds and the round trip dominates, but the payload and scan grow forever.

- **Fix:** (a) Immediately: move the call into the Promise.all at 14727 (it is independent of the other fetches) — removes one sequential trip for free. (b) Aggregate server-side: `create view org_latest_touch as select org_id, max(engagement_date) as last_touch from engagements where org_id is not null and work_mode is distinct from 'internal' group by org_id;` and `create index engagements_org_touch_idx on engagements (org_id, engagement_date desc) where org_id is not null;` then `apiGet('org_latest_touch','select=*')` — index-only scan, one tiny row per org with touches, no 1000-row cap risk. (c) Or fold it into the register view (LR-06) so it costs no request at all.

### LR-04 — Register fetches the entire leads table with select=* (~60 columns incl. long text/jsonb) and then filters to the user's own leads client-side

**Impact medium · effort S · payload · reviewer (confidence 0.8)**

- **Where:** index.html:14728 (apiGetAll('leads','select=*&order=created_at.desc')), 11703-11712 filterLeadsByView applied at 14757; leadsOwnerView defaults to 'own' (11612)
- **Evidence:** 14728: `apiGetAll('leads', 'select=*&order=created_at.desc')`. 11710: `return leads.filter(l => l.owner_id != null && +l.owner_id === +pid); // 'own' (+ fallback)`. Columns the register actually reads (grep of l.* in 14701-15100): access, branch_id, capacity, dead_notes, dead_reason, fit, id, last_touch_date, next_action, next_action_date, owner_id, promoted_at, promoted_deal_id, promotion_request_note, promotion_request_type, promotion_requested_at, region_id, site_id, source_id, status, target_org_id, target_org_name, trigger_score, working_at (+ site_name, created_at, wake_date, first_engaged_at, source_* for the sweeps) ≈ 30 of ~60. Not needed: description, source_detail, fit/trigger/access/capacity_comment (lead_lifecycle_A_foundations.sql:63-66), peer_review_note, contacts jsonb (read at 25763), est_value, service_major_ids, etc. idx_leads_owner_id already exists.
- **Mechanism:** Over-fetch bytes: for a rep who owns 10% of leads the payload is ~10× larger than needed in rows and roughly 2× in bytes per row (free-text columns); JSON.parse and the 7 tab-count filters run over all rows. Paging past 1000 rows adds a sequential round trip per extra page.
- **Who feels it:** Every register load/tab click for every non-admin user. Magnitude scales with total lead count; becomes a second page (≥1000 leads) sooner than necessary.

- **Fix:** Narrow the projection and push the scope into the query: `const cols='id,status,source_id,region_id,branch_id,owner_id,site_id,site_name,target_org_id,target_org_name,fit,trigger_score,access,capacity,next_action,next_action_date,last_touch_date,promoted_at,promoted_deal_id,promotion_requested_at,promotion_request_type,promotion_request_note,dead_reason,dead_notes,working_at,wake_date,first_engaged_at,created_at'; const scope = leadsOwnerView==='all'&&can('view_all_leads') ? '' : leadsOwnerView==='team'&&isManagerViewer() ? `&or=(owner_id.eq.${pid},branch_id.in.(${branches}),region_id.in.(${regions}))` : `&owner_id=eq.${pid}`; apiGetAll('leads', `select=${cols}&order=created_at.desc${scope}`)`. Keep filterLeadsByView as a no-op safety net. With LR-02 done, the sweeps no longer need the source_*/description columns on the client. Add `create index leads_created_at_idx on leads (created_at desc, id asc)` so the ordered offset pages don't sort the table each page.

### LR-05 — organisations and sites are refetched fresh with select=* on every register render (and every tab click), though the register needs 3-6 columns of each; research_campaigns is fetched and never used

**Impact medium · effort M · payload · reviewer (confidence 0.75)**

- **Where:** index.html:14733-14738 (comment + apiGet('organisations','select=*'), apiGet('sites','select=*')), 14737 (research_campaigns), 14744-14748 (allData assignments). Column usage: leadClientOf 14177-14196 (id, name, organisation_id), _ultimateParentOrg 14210 (parent_org_id), _groupTouchFor 14303 (group_touch_soothes), _groupChipHtml 14259 (collective_since), _orgSectorName 11746 (sector_id), sites PAGES config 2775-2799 (~15 columns), organisations schema.sql:774 + add_org_detail_fields.sql:5-44 (~45 columns incl. notes, 10 address lines, bbbee, vat…)
- **Evidence:** 14733-14736: `// Orgs + sites always fresh: ... apiGet('organisations', 'select=*'),` and 14738 `apiGet('sites', 'select=*'),`. `campaigns` (14737) is only written to allData['research_campaigns'] (14746) and never referenced by cols/rows. The comment at ~12143 warns that writing a SLIM org list into allData poisoned option lists elsewhere, which is why the fetch stays select=*.
- **Mechanism:** Over-fetch bytes on two whole tables per render: organisations rows carry addresses/notes (~1-2 KB each) when the register uses ~100 bytes; sites likewise. These are also the arrays scanned linearly per row (LR-11), so their width also hurts CPU cache behaviour. Data-volume assumption: hundreds to low thousands of orgs/sites → hundreds of KB to a few MB per render.
- **Who feels it:** Every register load and tab click (LR-01), all users. Not a round-trip-depth cost (they run in the Promise.all) but a bandwidth + parse cost on every paint, worse on the field over mobile data.

- **Fix:** Fetch a register-local slim projection and pass it explicitly (leadClientOf/leadBandOf/renderLeadRow already take orgs/sites parameters): `apiGet('organisations','select=id,name,parent_org_id,sector_id,collective_since,group_touch_soothes,home_organisation,active')`, `apiGet('sites','select=id,name,organisation_id')`, kept in `_leadsReg.orgs/_leadsReg.sites` (LR-01) and NOT assigned to allData['organisations']/['sites'] — so the lead form's option lists keep their own full fetch and the 'slim cache poisoning' bug cannot recur. Make the implicit-allData helpers (leadSiteLabel 14158, leadEffectiveTouch 14319, _childHookHtml 14272, _leadSectorName 11752, _groupChipHtml 14259) read from a `_regCtx` when set. Drop the research_campaigns fetch (14737) from the register. (Superseded entirely by LR-06.)

### LR-07 — Cockpit: engagements fetch is a sequential third trip that could ride on the leads fetch via PostgREST embedding; campaign leads use select=*

**Impact medium · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** index.html:15597-15601 (interactions fetch after sweeps), 15575 (leads select=*), 15592-15593 (sweeps in between)
- **Evidence:** 15599: `interactions = await apiGet('engagements', 'lead_id=in.(' + leadIds.join(',') + ')&select=lead_id,engagement_date');` executes only after `await sweepNewToWorking(leads); await sweepHoldWake(leads);` (15592-15593), which themselves follow the Promise.all at 15568. engagements.lead_id → leads(id) FK exists (sql/unify_engagements.sql:31-32) so resource embedding is available. The Work Queue only needs a count of touches per lead (15798-15800 `byLead[+i.lead_id]`, `done = ix.length`).
- **Mechanism:** One avoidable sequential round trip (~1.4 s) on every cockpit open and after every cockpit action (all of which call renderResearchCampaignCockpit again: 15887, 15966, 15978, 16097, 16296). Plus over-fetch of full lead rows.
- **Who feels it:** Campaign workers: every cockpit open, every target save/disqualify/promote, every status change and cadence save.

- **Fix:** Embed and narrow in the parallel batch: `apiGet('leads', 'research_campaign_id=eq.'+cid+'&select=id,status,owner_id,site_id,site_name,target_org_name,target_person_name,description,next_action,next_action_date,est_value,cadence_started_at,created_at,wake_date,dead_reason,promoted_at,first_engaged_at,working_at,engagements(engagement_date)&order=created_at.desc')` and derive `interactions` from `leads.flatMap(l => l.engagements.map(e => ({lead_id:l.id, ...e})))`. Depth 2 → 1 (with LR-02 removing the sweeps). Likewise `campaign_targets` select can drop research_notes/contact_* for the list (they are re-fetched by the target modal anyway — see LR-10 for the opposite fix).

### LR-08 — Cockpit 'Log touch' opens the engagement modal with 8-10 strictly sequential GETs, re-fetching data the cockpit already holds (lead row, cadence steps) and fetching the lead's engagements three times

**Impact medium · effort M · parallelise · reviewer (confidence 0.8)**

- **Where:** index.html:16114-16131 cockpitQuickLogTouch → 16116, 25127 (loadLeadInteractions), 25148, 25154-25155 (_milLookups/_milForEngagements), 25582 (loadLiLookups), 25607 (leadCadenceModalContext), 25763 (_liLoadPeople), 25977 (_liInitStreamSection)
- **Evidence:** 16116: `const rows = await apiGet('leads', 'id=eq.' + leadId + '&select=*');` though `cockpitData.leads` (15575, select=*) contains that row. 25607: `steps = await apiGet('campaign_cadence_steps', 'research_campaign_id=eq.' + ...)` though `cockpitData.steps` (15576) is the same rows. Engagements of this lead are fetched at 15599 (cockpit), 25127 (`lead_id=eq.${leadId}&select=*`) and 25977 (`lead_id=eq.${parent.id}&select=id,stream_id,...`). Each `await` at 16119-16127 waits for the previous one; none depend on each other except the modal DOM existing.
- **Mechanism:** Sequential depth 8-10 (≈11-14 s) where the data dependencies allow depth 2-3; three redundant fetches of the same lead/engagements.
- **Who feels it:** Campaign workers logging touches from the Work Queue — the most frequent cockpit action — wait >10 s for the modal to become usable.

- **Fix:** (1) Reuse cockpit state: `leadData = cockpitData.leads.find(l => +l.id === +leadId) || (await apiGet(...))[0]`; give leadCadenceModalContext an optional `steps` argument and pass `cockpitData.steps` when `cockpitCampaignId === leadData.research_campaign_id`. (2) Fetch the lead's engagements once with select=* (25127) and derive the stream rows for _liInitStreamSection from that array instead of 25977. (3) Parallelise the remaining independents: `await Promise.all([loadLeadInteractions(leadId), loadLiLookups(), _liLoadPeople(), _liInitStreamSection()]); await maybeApplyCadencePrefill();` (the prefill needs `leadInteractions.length`). (4) Inside loadLeadInteractions run the lead-engagements GET and the org-chain GET in one request: `or=(lead_id.eq.L,org_id.in.(chain))&select=*` and split client-side. Result: depth ≈ 2.

### LR-09 — Group history modal issues 6-9 strictly sequential GETs where 2-3 suffice; the three engagements queries hit unindexed columns

**Impact medium · effort S · parallelise · reviewer (confidence 0.85)**

- **Where:** index.html:14462-14477 openParentHistory (sites → leads → deals → engL → engD → engO → activity_types → next_actions), 14520 (lead_sources)
- **Evidence:** 14462-14474: six consecutive `const x = await apiGet(...)` statements; leads and deals (14468-14469) are independent; the three engagement fetches (14471-14474) are independent and all `select=*`. No index on engagements.deal_id or engagements.org_id (index_inventory.txt lists only idx_engagements_lead); `_familyOrgIds` (14248) also walks all orgs in memory first.
- **Mechanism:** Sequential depth 6-9 (≈8-13 s); three separate sequential scans of the engagements table for the deal_id/org_id predicates.
- **Who feels it:** Anyone clicking a GROUP / HISTORY chip on a client band (and the modal reopens itself after logging a group engagement, 14684).

- **Fix:** Parallelise and merge: after `sites`, run `Promise.all([leads, deals, activity_types, next_actions, lead_sources])`; then ONE engagements request `apiGet('engagements', 'or=(lead_id.in.(' + leadIds + '),deal_id.in.(' + dealIds + '),org_id.in.(' + idList + '))&select=id,lead_id,deal_id,org_id,engagement_date,engagement_type,notes,created_by&order=engagement_date.desc')` → depth 3. Indexes: `create index engagements_deal_idx on engagements (deal_id); create index engagements_org_idx on engagements (org_id) where org_id is not null; create index leads_target_org_idx on leads (target_org_id); create index leads_site_idx on leads (site_id); create index sites_org_idx on sites (organisation_id);` (sites is not in sql/, assume unindexed). Longer term an RPC `family_history(parent_id bigint)` returning the joined rows makes it depth 1.

### LR-10 — Target modal refetches the target row the cockpit already holds, then resolves org contacts with two chained GETs instead of one embedded query

**Impact low · effort S · query shape · reviewer (confidence 0.9)**

- **Where:** index.html:16140-16147 openCampaignTargetModal, 16356-16374 _ctAffiliatedPeople (16361 roles → 16367 people), triggered from renderCampaignTargetModal 16244 and every company-field event (16280-16345)
- **Evidence:** 16142: `const rows = await apiGet('campaign_targets', 'id=eq.' + id + '&select=*');` — `cockpitData.targets` was loaded with `select=*` at 15574 and the row click passes its id (15764). 16361-16367: `const links = await apiGet('person_organisation_roles', 'org_id=eq.${orgId}&select=person_id...'); ... list = await apiGet('people', 'id=in.(...)&select=id,first_name,last_name,title,email,phone');`
- **Mechanism:** 1 avoidable round trip per target click (~1.4 s before the modal appears) + 1 extra sequential trip per linked org when its contacts aren't all in allData['people'].
- **Who feels it:** Campaign workers editing targets — every row click in the Target List.

- **Fix:** `campaignTargetData = (cockpitData.targets || []).find(t => +t.id === +id) || (await apiGet(...))[0];` (keep the fetch only as fallback). Replace the two-step contact lookup with resource embedding: `apiGet('person_organisation_roles', 'org_id=eq.'+orgId+'&select=person_id,is_primary,people(id,first_name,last_name,title,email,phone)&order=is_primary.desc')` → `list = links.map(l => l.people).filter(Boolean)`. Both FKs exist (person_organisation_roles_org_id_fkey; person_id → people).

### LR-11 — Register paint does ~15 linear .find() scans per row over organisations/sites/people, repeated inside the sort comparator and on every band toggle / sort / filter click

**Impact low · effort M · client cpu · reviewer (confidence 0.7)**

- **Where:** index.html:14932-14937 renderLeadRow (5 finds), 14158-14166 leadSiteLabel, 14177-14196 leadClientOf, 14272-14278 _childHookHtml, 11752-11750 _leadSectorName/_orgSectorName (3 finds), 14319-14325 leadEffectiveTouch + 14300-14316 _groupTouchFor, 14222-14234 leadBandOf + 14210-14220 _ultimateParentOrg, 14248-14252 _familyOrgIds (iterates ALL orgs per band, from _groupChipHtml 14259), cols.get closures 14852-14863 used by _renderTable's sort/filter (2305-2335); 43 `.find(` calls in 14147-15217
- **Evidence:** e.g. 14933-14937: `sources.find(...)`, `regions.find(...)`, `(allData['branches']||[]).find(...)`, `people.find(...)`, `orgs.find(...)`; 15039: `(allData['sites'] || []).find(s => +s.id === +l.site_id)`; 14882: `leadBandOf(l, orgs, sites)` per row; 14264: `O.forEach(o => { if (+_ultimateParentOrg(o, O).id === +parentId) ... })` per band; _renderTable 2315-2326 calls `col.get(a), col.get(b)` per comparison (n log n). toggleClientBand (11673) → full `_renderTable` (filter + sort + regroup + innerHTML of all rows).
- **Mechanism:** O(rows × (|orgs| + |sites| + |people| + …)) main-thread work per paint, re-done for every sort click, filter tick, Expand/Collapse-all and single band toggle. With e.g. 400 visible leads × 2,000 orgs it is several million comparisons (tens to low-hundreds of ms per paint); grows linearly with the organisation count, independent of leads.
- **Who feels it:** Sluggish sort/filter/band toggles on the register for everyone; becomes noticeable as organisations/sites grow (data-volume dependent — negligible at a few hundred orgs).

- **Fix:** Build Map indexes once per paint and precompute a view-model per row: `const byId = a => new Map(a.map(x => [+x.id, x])); const O = byId(orgs), S = byId(sites), P = byId(people), SRC = byId(sources), R = byId(regions), B = byId(allData.branches||[]), SEC = byId(sectors); const topOf = new Map(); /* memoised _ultimateParentOrg */ const orgByLowerName = new Map(orgs.map(o => [(o.name||'').trim().toLowerCase(), o])); const vm = leads.map(l => ({ l, source: SRC.get(+l.source_id)?.name||'', client: ..., band: ..., site: ..., owner: ..., sector: ..., touch: ... }));` and let cols.get / renderLeadRow read the precomputed fields. Toggle a band by flipping `hidden` on `tr.client-band-child[data-band]` rows instead of re-rendering the tbody. LR-06 removes the need for most of this.

### LR-12 — Missing indexes on the FK/predicate columns this slice queries (engagements.org_id/deal_id, sites.organisation_id, leads.target_org_id/site_id/created_at, organisations.parent_org_id)

**Impact low · effort S · db index · reviewer (confidence 0.6)**

- **Where:** sql/ (index_inventory.txt): engagements has only idx_engagements_lead; leads has owner_id, status, source_id, research_campaign_id, next_action_date; no index on sites/organisations FKs. Queries: index.html:14290 (org_id=not.is.null), 14463-14474 (deal_id=in, org_id=in, organisation_id=in, target_org_id.in/site_id.in), 14370 (target_org_id=eq), 14381-14385 (_groupMemberLeads), 15148 (org_id=in), 14728 (order=created_at.desc + offset paging), 15211 (promoted_deal_id=eq), 15328 (sales_campaign_id=eq)
- **Evidence:** predicates.txt: engagements `2 org_id=in`, leads `1 target_org_id=eq`, sites `2 organisation_id=in`; fk_columns.txt lists leads_target_org_id_fkey, leads_promoted_deal_id_fkey, engagements_deal_id_fkey, person_organisation_roles_org_id_fkey with no matching CREATE INDEX. Postgres does not auto-index FK columns. The sites table and engagements.org_id/work_mode columns are not in sql/ at all (added out of band) — assume unindexed.
- **Mechanism:** Sequential scans on every filtered read of these tables; engagements is the append-only activity table so its scans grow without bound. At current volumes (assumed thousands of rows) each scan is milliseconds and hidden behind the 1.4 s proxy trip — this is cheap insurance that keeps the DB flat as data grows, and it is required for LR-03/LR-06/LR-09 to be index-driven.
- **Who feels it:** Indirect today; protects register, group history, cockpit and lead-form loads from degrading as engagements/leads grow past tens of thousands of rows.

- **Fix:**

```sql
```sql
create index if not exists engagements_org_idx      on engagements (org_id, engagement_date desc) where org_id is not null;
create index if not exists engagements_deal_idx     on engagements (deal_id);
create index if not exists sites_org_idx            on sites (organisation_id);
create index if not exists leads_target_org_idx     on leads (target_org_id);
create index if not exists leads_site_idx           on leads (site_id);
create index if not exists leads_created_at_idx     on leads (created_at desc, id asc);
create index if not exists leads_promoted_deal_idx  on leads (promoted_deal_id);
create index if not exists leads_sales_campaign_idx on leads (sales_campaign_id);
create index if not exists organisations_parent_idx on organisations (parent_org_id) where parent_org_id is not null;
create index if not exists por_org_idx              on person_organisation_roles (org_id);
```
(Use `create index concurrently` when running against prod.)
```

### LR-13 — Research Study / Marketing Campaign edit modals refetch the entire people (and organisations) tables with select=* and chain 3-4 sequential round trips

**Impact low · effort S · parallelise · reviewer (confidence 0.8)**

- **Where:** index.html:26976-26985 openSalesCampaignModal → 26987-27045 renderSalesCampaignModal (27003-27009 Promise.all, 27027-27030 links, 27038-27041 missing rows); 26618-26627 openResearchCampaignModal → 26629-26652 (26648 apiGetAll people)
- **Evidence:** 27006-27007: `apiGetAll('people', 'select=*&order=first_name.asc'), apiGetAll('organisations', 'select=*&order=name.asc'),` — unconditional (no `allData[...] ||` guard) full-table refetches, then 27027 `const [orgLinks, personLinks] = await Promise.all([...])` and 27038 `const [gotOrgs, gotPpl] = await Promise.all([...])`. 26979: `await apiGet('sales_campaigns','id=eq.'+id)` completes before the lookups start although they are independent. Same pattern at 26648 for marketing campaigns.
- **Mechanism:** Depth 4 (≈5.6 s) for a modal with a handful of fields, plus two whole-table select=* payloads (organisations ≈45 columns) per open.
- **Who feels it:** Anyone editing a Research Study (row click on the Studies page) or a Marketing Campaign ('Edit' / 'Edit mission'). Infrequent compared with the register, but each open is several seconds.

- **Fix:** Fetch the campaign with its links embedded, in the same Promise.all as the lookups: `Promise.all([ apiGet('sales_campaigns', 'id=eq.'+id+'&select=*,sales_campaign_organisations(organisation_id,organisations(id,name)),sales_campaign_people(person_id,people(id,first_name,last_name))'), allData.regions || apiGet(...), allData.industry_sectors || apiGet(...), apiGetAll('people','select=id,first_name,last_name&order=first_name.asc'), apiGetAll('organisations','select=id,name,active,home_organisation&order=name.asc'), apiGet('home_organisation_members','select=person_id') ])` → depth 1, and the 'missing rows' step disappears because the embedded rows are already resolved. Apply the same to renderResearchCampaignModal (26648 → `select=id,first_name,last_name`, run the campaign GET inside the Promise.all).

### LR-14 — Register keeps a 1 Hz layout-forcing ticker running whenever any Working lead is in its edit-grace window, and an expiry triggers a full network reload

**Impact low · effort S · dom render · reviewer (confidence 0.7)**

- **Where:** index.html:14912 startEditCountdownTicker (called on every register paint), 23593-23616 tickEditCountdowns, 15013-15016 renderLeadRow cdChip
- **Evidence:** 23597: `const els = [...document.querySelectorAll('.edit-cd')].filter(el => el.offsetParent !== null);` every second (offsetParent forces layout); 23615: `else if (listExpired && currentPage === 'leads') renderLeadsPage();` — a chip reaching zero re-runs the whole register load (LR-01). The ticker self-stops only when no `.edit-cd` is visible.
- **Mechanism:** Continuous main-thread work (querySelectorAll + forced layout per tick) while the register is open with any in-grace lead; and a surprise multi-second reload when a countdown hits zero.
- **Who feels it:** Low background cost for anyone on the register while colleagues' leads are in their edit window; occasional unexpected 3 s freeze at expiry.

- **Fix:** Tick only the chips cached at paint time (`_cdEls = [...leadsBody.querySelectorAll('.edit-cd')]`) and skip the offsetParent check for list chips (they are visible by construction while currentPage==='leads'); on expiry call paintLeadsRegister() (LR-01) after setting `l.status` in memory via computeLeadStatus — no network. Consider a 5 s cadence for list chips (only the open-lead chip needs 1 s precision).


## Lead form

### LF-01 — Lead open serialises 8 independent round trips before the page is shown

**Impact high · effort S · parallelise · spot-checked (confidence 0.95)**

- **Where:** /home/user/Focus/index.html:17015-17074 (openLeadForm); child loaders 18466, 18116, 19277, 25124-25155, 20142, 17674
- **Evidence:** openLeadForm awaits in strict sequence: `const rows = await apiGet('leads', 'id=eq.' + id + '&select=*')` (17015) … `await initLeadForm()` (17050) … `await loadLeadDescriptionLog(id)` (17051) … `await loadLeadContacts(id)` (17052) … `await loadLeadServiceEstimates(id)` (17055) … `await loadLeadInteractions(id)` (17056) … `await loadLeadCadence()` (17057) … `await loadLeadQualificationSelections(id)` (17059) and only then `document.getElementById('lead-page').classList.add('active')` (17074). loadLeadInteractions itself awaits three more in sequence (25127 -> 25149 -> 25153/25154). All six child loaders filter only on lead_id / research_campaign_id / org chain, i.e. on data already known after 17015.
- **Mechanism:** Extra sequential round trips: depth 8 on a warm session (10 on the first open of a session) at ~1.4 s per proxied GET ≈ 11-14 s of blank wait; nothing is painted until the last await resolves.
- **Who feels it:** Every user, every time a lead is opened from the register, dashboard, campaign cockpit or a deal — the single most frequent navigation in the Leads workflow.

- **Fix:** Step 1 (no server change): after the lead row and initLeadForm resolve, call populateLeadForm() and add the 'active' class immediately, then `await Promise.all([loadLeadDescriptionLog(id), loadLeadContacts(id), loadLeadServiceEstimates(id), loadLeadInteractions(id), loadLeadCadence(), loadLeadQualificationSelections(id)])` and render each tab section as it lands (renderLeadCadenceRibbon after both interactions and cadence resolve). Inside loadLeadInteractions run the lead-engagements GET, the org-chain engagements GET and _milLookups() in one Promise.all, then engagement_milestones. Depth drops from 8 to 2 (lead row -> fan-out) with zero SQL. Step 2 is LF-02.

### LF-02 — Fold the whole lead bundle into one RPC / embedded select

**Impact high · effort M · db view or rpc · reviewer (confidence 0.9)**

- **Where:** /home/user/Focus/index.html:17015-17059 plus loaders at 18466, 19277, 25124-25155, 20142, 17674, 20239, 21055
- **Evidence:** Nine child reads per open are all keyed by the lead: lead_description_log?lead_id=eq (18468), lead_service_estimates?lead_id=eq (19283), engagements?lead_id=eq (25127), engagements?org_id=in.(chain) (25149), engagement_milestones?engagement_id=in.() (25154), campaign_cadence_steps?research_campaign_id=eq (20146), lead_red_flags?lead_id=eq + lead_strategic_decisions?lead_id=eq (17687-17688), lead_stage_requests?lead_id=eq&status=eq.pending (20243), promotion_requests?lead_id=eq&status=eq.pending (21057). FKs exist for engagements.lead_id (sql/unify_engagements.sql:31), lead_description_log.lead_id (sql/lead_lifecycle_A_foundations.sql:117), lead_red_flags / lead_strategic_decisions (schema.sql:2484, 2500), campaign_cadence_steps (add_campaign_cockpit.sql:56), promotion_requests (add_promotion_requests.sql:31).
- **Mechanism:** Ten proxied round trips (each a Netlify invocation + PostgREST query) where one would do; payload is small, latency is per-call.
- **Who feels it:** Same as LF-01: every lead open. Also cuts Netlify function invocations ~10x for this page.

- **Fix:** Create `create or replace function lead_bundle(p_lead_id bigint) returns jsonb language sql stable as $$ select jsonb_build_object('lead', (select to_jsonb(l) from leads l where id=p_lead_id), 'description_log', (select coalesce(jsonb_agg(d order by created_at desc, id desc),'[]') from lead_description_log d where lead_id=p_lead_id), 'estimates', (select coalesce(jsonb_agg(e),'[]') from lead_service_estimates e where lead_id=p_lead_id), 'engagements', (select coalesce(jsonb_agg(e order by engagement_date desc, created_at desc),'[]') from engagements e where lead_id=p_lead_id), 'group_engagements', (with recursive chain as (select o.id, o.parent_org_id from organisations o join leads l on o.id = coalesce(l.target_org_id,(select organisation_id from sites s where s.id=l.site_id)) where l.id=p_lead_id union select p.id, p.parent_org_id from organisations p join chain c on p.id=c.parent_org_id) select coalesce(jsonb_agg(e order by engagement_date desc),'[]') from engagements e where e.org_id in (select id from chain)), 'milestones', (select coalesce(jsonb_agg(m),'[]') from engagement_milestones m join engagements e on e.id=m.engagement_id where e.lead_id=p_lead_id), 'cadence', (select coalesce(jsonb_agg(s order by step_no),'[]') from campaign_cadence_steps s join leads l on l.research_campaign_id=s.research_campaign_id where l.id=p_lead_id), 'red_flags', (select coalesce(jsonb_agg(r),'[]') from lead_red_flags r where lead_id=p_lead_id), 'strategic_decisions', (select coalesce(jsonb_agg(r),'[]') from lead_strategic_decisions r where lead_id=p_lead_id), 'stage_request', (select to_jsonb(q) from lead_stage_requests q where lead_id=p_lead_id and status='pending' and request_type in ('hold','nurture') order by requested_at desc limit 1), 'promotion_request', (select to_jsonb(q) from promotion_requests q where lead_id=p_lead_id and status='pending' order by requested_at desc limit 1)) $$;` and call it once via `api('rpc/lead_bundle','POST',{p_lead_id:id})` (sb.js already forwards any /rest/v1 path). Populate leadData, leadDescriptionLog, window._leadSvcEstAsLoaded, leadInteractions, window._leadGroupEngs, window._leadMilMap, _leadCadence, window._leadRedFlags/_leadStrategicDecisions, window._leadStageRequest, window._leadPromotionRequest from the one result; keep the existing loaders as fallbacks. Alternative without a function: PostgREST embedding `leads?id=eq.X&select=*,lead_description_log(*),engagements!engagements_lead_id_fkey(*,engagement_milestones(*)),lead_red_flags(*),lead_strategic_decisions(*),promotion_requests(*),research_campaigns(name,campaign_cadence_steps(*))` (needs an FK on lead_service_estimates.lead_id and lead_stage_requests.lead_id — verify, their DDL is not in the repo).

### LF-03 — Promoted leads fire the deal-contacts fetch chain 8-10 times per open

**Impact medium · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:18244-18249 (renderLeadContacts) and 18190-18224 (_renderPromotedLeadContacts); synchronous callers 17946, 18716, 18922, 18840, 18865, 18591
- **Evidence:** renderLeadContacts routes Promoted leads straight to the fetcher: `if (leadData && leadData.id && leadData.status === 'Promoted' && leadData.promoted_deal_id) { _renderPromotedLeadContacts(el, +leadData.promoted_deal_id); return; }` (18248-18250). The cache is only written after the awaited chain completes (`_promotedLeadContactsCache = { dealId: +dealId, rows }` at 18225) — there is no in-flight promise. resetLeadForm alone calls renderLeadContacts four times synchronously (17946 directly; onLeadTargetOrgChange 18716 via 17921 and via clearLeadSiteField 18918; clearLeadSiteField 18922); initLeadForm's clearLeadSiteField (18047) adds two more, populateLeadForm's clearLeadSiteField/selectLeadSite/loadLeadContacts.then (18535-18591) three more. Each call issues GET deal_contacts (18206), often GET people?id=in (18210) and GET person_organisation_roles?org_id=eq (18216).
- **Mechanism:** Duplicate round trips: ~9 parallel chains of 1-3 GETs (10-27 proxied calls) for data needed once; the last to resolve wins the innerHTML.
- **Who feels it:** Anyone opening a Promoted lead (a growing share of the register as leads convert); also loads the proxy and DB 10x for those opens.

- **Fix:** Memoise the in-flight promise: `if (!_promotedLeadContactsCache || _promotedLeadContactsCache.dealId !== +dealId) _promotedLeadContactsCache = { dealId:+dealId, promise: (async () => { …existing fetch… return rows; })() }; const rows = await _promotedLeadContactsCache.promise;`. Also skip renderLeadContacts entirely while `window._leadPopulating` is true (call it once at the end of populateLeadForm). Longer term fold deal_contacts into the LF-02 bundle (`'promoted_contacts', (select … from deal_contacts dc join people p … where dc.deal_id = l.promoted_deal_id)`).

### LF-04 — person_organisation_roles is pulled whole-table, with duplicate fetches per keystroke while in flight

**Impact medium · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:19453-19461 (_ensurePersonAffiliationsLoaded); callers 18152, 18254, 18361, 19690
- **Evidence:** `allData['person_organisation_roles'] = await apiGet('person_organisation_roles', 'select=person_id,org_id,role_type,is_primary,end_date,job_title');` (19456) — no filter, so every session pays the full table; the only guard is `if (allData['person_organisation_roles']) return;` (19454), which is false until the response lands. onLeadSourcePersonNameInput calls it on every keystroke (`if (!allData['person_organisation_roles']) { _ensurePersonAffiliationsLoaded().then(() => … onLeadSourcePersonNameInput()) }` 19689-19696), as does onLeadContactNameInput (18152) and renderLeadContacts (18254). The data is used only to label ≤6 rendered candidates/contacts (_personAffiliationsLabel 19463, _isPersonAtOrg 17356, _personJobTitleAtOrg 19651).
- **Mechanism:** Over-fetch (every affiliation row ever, ~6 columns each; plain apiGet so also silently capped at 1000 rows) plus N duplicate full-table GETs for N keystrokes typed during the first ~1.4 s flight.
- **Who feels it:** First contact/referrer interaction of every session on the lead form; the duplicate storm hits anyone who types a referrer name at normal speed.

- **Fix:** 1) Share one in-flight promise: `let _porPromise=null; async function _ensurePersonAffiliationsLoaded(){ if (allData['person_organisation_roles']) return; if (!_porPromise) _porPromise = apiGet(...).then(r=>{allData['person_organisation_roles']=r;}).catch(...).finally(()=>{_porPromise=null;}); return _porPromise; }`. 2) Better: fetch only what is displayed — `person_organisation_roles?person_id=in.(${candidateIds})&end_date=is.null&select=person_id,org_id,job_title` for the ≤6 match candidates / current contacts, and `org_id=eq.${orgId}&end_date=is.null` for the at-this-client check (that query already exists at 18216). 3) Add `create index on person_organisation_roles (person_id) where end_date is null;` and `create index on person_organisation_roles (org_id) where end_date is null;` — predicates.txt shows 17 org_id=eq and 10 person_id=eq call sites and index_inventory.txt shows no index on either column.

### LF-05 — Every autosave tick runs two unindexed background GETs (maybeBirthCollective)

**Impact medium · effort S · query shape · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/index.html:23916 (saveLead) -> 14334-14362 (maybeBirthCollective); cache invalidation 2093
- **Evidence:** saveLead: `if (payload.target_org_id) maybeBirthCollective(+payload.target_org_id);` (23916) runs on every save including the 1.5 s silent autosave (17575 -> 17578 -> saveLead keepOpen/silent). maybeBirthCollective only short-circuits when `cached.collective_since` is set (14338); for every ordinary single-pursuit org it then does `Promise.all([apiGet('leads','target_org_id=eq.'…), apiGet('deals','org_id=eq.'+…+'&or=(opportunity_type.is.null,opportunity_type.eq.new_business)…')])` (14342-14345). Neither leads.target_org_id nor deals.org_id has an index (index_inventory.txt lists idx_leads_owner_id/status/source_id/research_campaign/next_action_date and deals_master_deal/parent_deal/opportunity_type only). When a second pursuit is found it PATCHes organisations, and api() then runs `_lkInvalidate('organisations')` (2093), nulling the org cache so the next lead open refetches the whole organisations table via plain `apiGet('organisations','select=*&order=name.asc')` (17961, 1000-row cap).
- **Mechanism:** 2 extra proxied GETs + 2 sequential scans (leads, deals) per autosave; occasionally a whole-table organisations refetch on the following open.
- **Who feels it:** Every edit burst on every lead (each qualification dot click, each blur) — background, so not felt directly, but it multiplies proxy invocations and DB load ~3x for the most frequent write path and is the kind of load that makes 'the app slow down when running'.

- **Fix:** Check once per form-open and per org: `if (window._collectiveCheckedOrg === orgId) return; window._collectiveCheckedOrg = orgId;` at the top of maybeBirthCollective (reset in openLeadForm/openNewLead), or only call it when target_org_id changed versus leadData (`+payload.target_org_id !== +preSave.target_org_id`). Better still, move the rule server-side: an AFTER INSERT OR UPDATE OF target_org_id trigger on leads (and on deals.org_id) that stamps organisations.collective_since when a second pursuit appears — the client then never polls. In any case add `create index on leads (target_org_id); create index on deals (org_id);` (both are FK columns used by many filters in predicates.txt).

### LF-06 — Fuzzy org/person matching runs the full similarity engine over every row on every keystroke, undebounced

**Impact medium · effort M · client cpu · reviewer (confidence 0.7)**

- **Where:** /home/user/Focus/index.html:19342-19397 (onLeadTargetOrgNameInput), 21497-21525 (_orgMatchScore/_findOrgMatches), 19668-19740 (onLeadSourcePersonNameInput), 19604-19647 (_personMatchScore/_findPersonMatches), 19519-19598 (Jaro-Winkler/Metaphone); bindings at 1251 and 1086
- **Evidence:** Org field: `oninput="onLeadTargetOrgNameInput()"` (1251) -> `_findOrgMatches(name, '', 5)` (19362) -> `orgs.map(o => ({ org: o, score: _orgMatchScore(o, colloquial, legal) }))` over all active non-home orgs (21516-21518); _orgMatchScore recomputes `_normaliseOrgName` for the query AND the org's name and legal_name on every call (21498-21501: 20 regex replaces + stopword split each) plus `_stringSimilarity` (2x Jaro-Winkler + 2x Metaphone) up to 4 times and a TF-IDF overlap. Person field: `oninput="onLeadSourcePersonNameInput()"` (1086) -> `_findPersonMatches(name)` (19698) -> `people.map(p => ({ person: p, score: _personMatchScore(p, query) }))` (19637-19638); for a two-token query _personMatchScore makes 5 _stringSimilarity calls = 10 Jaro-Winkler + 10 Metaphone encodings per person (19620-19625), re-encoding the stored names each keystroke. Neither handler debounces; the same _findPersonMatches also backs the contact-name blur (18164).
- **Mechanism:** O(N_orgs) / O(N_people) CPU with heavy per-row constant factors on every keystroke, plus a full innerHTML rebuild of the match strip. Assumption on volume: at 2-5k orgs/people this is roughly 50-200 ms per keystroke on a typical laptop, enough to make typing visibly stutter; below ~500 rows it is negligible.
- **Who feels it:** Anyone typing a new organisation, a referrer or a contact name on the lead form (every new lead).

- **Fix:** (a) Debounce both handlers ~200 ms (`clearTimeout(t); t = setTimeout(run, 200)`) while still updating leadData/readiness synchronously. (b) Precompute a derived in-memory match index once per list identity: for orgs `{ id, norm: _normaliseOrgName(name), normLegal, meta: _metaphone(norm), metaLegal }`, for people `{ id, first, last, full, mFirst, mLast, mFull }`, rebuilt only when `allData['organisations']`/`allData['people']` changes identity (the IDF index at 21451 already follows this pattern); change _stringSimilarity to accept pre-encoded phonetic strings so Metaphone runs 0 times per keystroke instead of 2N-10N. (c) Cheap prefilter before Jaro-Winkler: skip candidates whose normalised name shares no leading bigram with any query token and whose TF-IDF overlap is 0 (Jaro-Winkler ≥0.7 is practically impossible without a shared prefix or token). (d) Optionally cap `people` scoring to rows whose first or last name starts with the query's first character when the query is a single token.

### LF-07 — Site typeahead is O(sites x organisations) per keystroke

**Impact medium · effort S · client cpu · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:18749-18767 (_leadSiteSearch), bound at 1219-1221 (oninput="onLeadSiteInput()")
- **Evidence:** `const orgNameOf = id => (orgs.find(o => +o.id === +id)?.name) || '';` (18753) is called inside `.map(s => …)` over every active site (18754-18761), so each keystroke does a linear scan of organisations for each site, then two `tokenSetRatio` calls per site (each normalises both strings with regexes, 18762).
- **Mechanism:** O(S x O) client CPU per keystroke (e.g. 3k sites x 3k orgs = 9M comparisons) plus 2S regex normalisations; no debounce.
- **Who feels it:** Everyone capturing or changing a site on a lead (the site is the lead's primary field, so this is typed on nearly every new lead).

- **Fix:** Build the lookup once per call: `const orgName = new Map(orgs.map(o => [+o.id, o.name || '']));` and use `orgName.get(+s.organisation_id) || ''` — O(S + O). Also normalise the query once (`normaliseStr(q)`) and pre-split site tokens into a derived array rebuilt when allData['sites'] changes; debounce onLeadSiteInput ~150 ms.

### LF-08 — Missing indexes on the lead form's filter columns

**Impact medium · effort S · db index · reviewer (confidence 0.65)**

- **Where:** /home/user/Focus/index.html:25149 (engagements org_id=in), 25154 (engagement_milestones engagement_id=in), 19283 (lead_service_estimates lead_id=eq), 20243 (lead_stage_requests lead_id/status/request_type), 14342-14345 (leads target_org_id, deals org_id), 19456/18216 (person_organisation_roles); /home/user/Focus/sql/*.sql
- **Evidence:** index_inventory.txt contains no index on engagements(org_id), engagement_milestones(engagement_id), lead_service_estimates(lead_id), lead_stage_requests(lead_id), leads(target_org_id), deals(org_id), person_organisation_roles(person_id|org_id). engagements is the largest business table (every deal and lead activity) and is scanned by `engagements?org_id=in.(chain)` on every lead open (25149). Postgres does not auto-index FK columns. Caveat: the DDL for engagements.org_id, lead_service_estimates, lead_stage_requests, engagement_milestones and sites is not in the repo (sql/ last commit is v7.8.86; app is v7.9.x), so any indexes created ad hoc in the Supabase console cannot be seen here — confirm with `select * from pg_indexes where tablename in (...)` before adding.
- **Mechanism:** Sequential scans on each open/autosave for equality/IN predicates on unindexed columns; cost grows linearly with table size, and engagements grows daily.
- **Who feels it:** Every lead open (engagements org-chain query, estimates, stage request), every autosave (LF-05), every promoted-lead contacts render. Scale-dependent: negligible at a few thousand rows, seconds at hundreds of thousands.

- **Fix:** Run once in Supabase SQL editor (idempotent): `create index if not exists idx_engagements_org on engagements (org_id) where org_id is not null; create index if not exists idx_engagement_milestones_eng on engagement_milestones (engagement_id); create index if not exists idx_lead_service_estimates_lead on lead_service_estimates (lead_id); create index if not exists idx_lead_stage_requests_lead_pending on lead_stage_requests (lead_id, requested_at desc) where status = 'pending'; create index if not exists idx_leads_target_org on leads (target_org_id); create index if not exists idx_leads_site on leads (site_id); create index if not exists idx_deals_org on deals (org_id); create index if not exists idx_por_person_open on person_organisation_roles (person_id) where end_date is null; create index if not exists idx_por_org_open on person_organisation_roles (org_id) where end_date is null;` and commit the file to sql/ so the inventory stays truthful.

### LF-09 — First lead open per session pays 8-9 extra lookup round trips that the login warm-up does not cover

**Impact low · effort S · db view or rpc · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/index.html:17957-17968 (initLeadForm lookups), 17663-17667 (red_flags/strategic_decisions), 23139 (industry_sectors), 23188 (qualification_dimensions), 23990-23993 (milestone_groups/types), 20040 (decline_reasons); LOOKUP_CONFIG 2143-2153
- **Evidence:** initLeadForm fetches `research_campaigns` (17963), `sales_campaigns` (17964), `service_sub` under the key `service_sub_all` (17962 — LOOKUP_CONFIG already warms the same table under key 'service_sub' at 2150, so it is fetched twice), `red_flags` and `strategic_decisions` (17665-17666); renderLeadQualification fetches `qualification_dimensions` (23188) and refreshLeadQualSector `industry_sectors` (23139); loadLeadInteractions fetches `milestone_groups` + `milestone_types` (23990-23993). None are in LOOKUP_CONFIG, so on the first open they add one Promise.all depth in initLeadForm plus one in loadLeadInteractions, and 2-3 background GETs.
- **Mechanism:** Extra sequential round trips (depth +2) and 8-9 extra proxied calls on the first lead open of every session (i.e. every day for every user).
- **Who feels it:** First lead opened after login, every user, every day.

- **Fix:** Without touching the lookup cache: (1) alias the key — `allData['service_sub_all'] || allData['service_sub'] || apiGet(...)` and populate the sub list from the already-warm 'service_sub' (filter active client-side). (2) Serve the remaining small tables in one call via a view: `create view lead_form_lookups as select (select jsonb_agg(r order by sort_order,name) from red_flags r where active) red_flags, (select jsonb_agg(s order by sort_order,name) from strategic_decisions s where active) strategic_decisions, (select jsonb_agg(c order by name) from research_campaigns c where status='Active') research_campaigns, (select jsonb_agg(c order by name) from sales_campaigns c where status='Active') sales_campaigns, (select jsonb_agg(q order by sort_order) from qualification_dimensions q) qualification_dimensions, (select jsonb_agg(i order by name) from industry_sectors i) industry_sectors, (select jsonb_agg(g order by sort_order,id) from milestone_groups g) milestone_groups, (select jsonb_agg(t order by sort_order,id) from milestone_types t) milestone_types, (select jsonb_agg(d) from decline_reasons d) decline_reasons;` and fetch it once in initLeadForm (or include it in the LF-02 RPC as a second top-level key). (3) Fetch it in parallel with the lead row rather than after it.

### LF-10 — initLeadForm rebuilds two all-organisations <select>s and other pickers on every open

**Impact low · effort S · dom render · reviewer (confidence 0.6)**

- **Where:** /home/user/Focus/index.html:17980-18048 (initLeadForm DOM population), notably 18023-18024 and 18038-18039
- **Evidence:** `srcOrgSel.innerHTML = '<option value="">— select client —</option>' + pickerOrgs.map(o => `<option value="${o.id}">${o.name}</option>`).join('')` (18023-18024) and the same again for `tgtOrgSel` (18038-18039) run unconditionally on every openLeadForm/openNewLead, along with the owner select, source/region/branch/campaign selects and populateLeadServiceCombo (18000). resetLeadForm additionally re-renders contacts, red flags, decisions, qualification and description mode before populate does it again.
- **Mechanism:** DOM rebuild proportional to organisation count (2 x N <option> nodes parsed and attached, then the old ones garbage-collected) on each open, even though the underlying list is unchanged between opens; the target-org select is normally hidden behind the site typeahead. Assumption: at 2-5k orgs this is ~20-60 ms of main-thread work per open plus memory churn; small lists make it negligible.
- **Who feels it:** Every lead open and every 'Load Lead'.

- **Fix:** Cache the built option HTML per list identity: `if (srcOrgSel._builtFrom !== orgs) { srcOrgSel.innerHTML = …; srcOrgSel._builtFrom = orgs; }` (same for tgtOrgSel, campaigns, owner pool keyed on people+members), and append the lead's own out-of-list org as a single extra <option> when needed (the code already does this at 19437-19446 and 20977-20982). Or replace the two org selects with the existing similarity typeahead (onLeadTargetOrgNameInput) so no N-option list exists at all.

### LF-11 — 1 s edit-window ticker forces layout and rewrites every chip each second; started redundantly on every chrome refresh

**Impact low · effort S · dom render · reviewer (confidence 0.75)**

- **Where:** /home/user/Focus/index.html:23586-23612 (updateLeadFormCountdown, startEditCountdownTicker, tickEditCountdowns); callers 19891, 23956, 9189, 14912
- **Evidence:** `setInterval(tickEditCountdowns, 1000)` (23593). Each tick: `[...document.querySelectorAll('.edit-cd')].filter(el => el.offsetParent !== null)` (23599 — offsetParent forces a synchronous style/layout flush on a ~28k-line single-document DOM), then for every visible chip sets `el.textContent`, `el.style.background`, `el.style.color` (23606-23608) even when only the seconds digit changed and the colours are the same. updateLeadFormCountdown (23586) is called from refreshLeadWorkflowChrome (19891), which runs 4-5 times per open and after every autosave (23956).
- **Mechanism:** Recurring DOM work: 1 querySelectorAll + 1 forced layout + 3 writes per chip per second for as long as any chip is visible (lead form: 1 chip during the Working grace; leads register New lane: one per row, where a chip expiry also triggers a full renderLeadsPage() at 23611).
- **Who feels it:** Low on the lead form itself (one chip); noticeable only as background jank on long-lived tabs and on the leads register when many New-lane leads are in grace.

- **Fix:** Keep a registry instead of querying: push chips into a Set when rendered, and check visibility with `el.closest('.opp-page.active, .page.active')` (no layout flush) or an IntersectionObserver. Write only what changed: cache the last label on `el.dataset.cdLabel` and skip identical writes; set the colour class once when the chip flips to expired rather than every second. Use one `requestAnimationFrame`-aligned timer and pause it on `document.hidden`. Guard startEditCountdownTicker so it is only invoked when leadEditCountdownHtml actually returned a chip.

### LF-12 — loadLeadContacts runs twice per open and can PATCH the lead during open

**Impact low · effort S · query shape · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/index.html:17052 and 18591 (callers), 18116-18138 (loadLeadContacts), 18129-18135 (cid backfill + status recompute)
- **Evidence:** openLeadForm awaits `loadLeadContacts(id)` (17052) and populateLeadForm calls it again in the background (`loadLeadContacts(leadData.id).then(() => { renderLeadContacts(); … })` 18591). When `leadData.contacts` is NULL (legacy leads) each call does `await apiGet('leads', `id=eq.${leadId}&select=contacts`)` (18120) because `leadData.contacts = arr` stores null and the guard `if (arr == null)` stays true. If any contact lacks a cid the open path also writes: `if (assigned && leadData && leadData.id) { try { await _persistLeadContacts(); } … }` (18134) which PATCHes leads and then `await recomputeOpenLeadStatus()` (18135) may PATCH again.
- **Mechanism:** 1-2 redundant GETs (one in the awaited path) for legacy leads, plus up to 2 sequential PATCHes on open for leads with pre-cid contacts; each PATCH also fires the audit trigger.
- **Who feels it:** Opening older leads (pre-contacts-jsonb / pre-cid); once per lead for the backfill, every open for the NULL-contacts refetch.

- **Fix:** Set `leadData.contacts = arr || []` after the fetch so the second call is a no-op; drop the populateLeadForm call (the awaited one already ran) or make populateLeadForm only render. Run the cid backfill as a one-off SQL update instead of on open: `update leads set contacts = (select jsonb_agg(c || jsonb_build_object('cid', ord)) from jsonb_array_elements(contacts) with ordinality as t(c, ord)) where contacts is not null and exists (select 1 from jsonb_array_elements(contacts) c where c->>'cid' is null);` and delete the client backfill.


## Lead workflow actions and Promote wizard

### PW-01 — commitPromotion is a 13-36 step strictly sequential write chain with no transaction — should be one plpgsql RPC

**Impact high · effort L · db view or rpc · spot-checked (confidence 0.95)**

- **Where:** index.html:22564-22943 commitPromotion; callers savePromoteAll 22495-22514 and _doAcceptPromotionRequest 21145-21172; proxy path passthrough netlify/functions/sb.js `const path = event.path.replace('/.netlify/functions/sb', '/rest/v1')`
- **Evidence:** Every step is `await api(...)` with no Promise.all: POST organisations (22574) → POST people (22599) → GET por (22605) → GET por (22607) → POST por (22608) → GET sites (22626) → POST sites (22634/22645) → POST deals (22681) → POST deal_collaborators (22688) → POST deal_contacts (22700) → per-contact loop `for (const c of _leadContacts)` (22712-22755, 4-6 awaits each) → POST revenue_streams (22758) → POST revenue_stream_months (22781) → GET engagements (22789) → POST engagements (22808) → POST engagement_people (22821) → `for (let ci...) await api('engagements','PATCH',...)` (22824-22831) → PATCH engagements (22834) → POST engagements (22860) → PATCH engagements (22876) → POST people (22891) → POST por (22905) → PATCH leads (22920). Comment at 22776-22777 already acknowledges 'each proxied call costs ~1.4s'. Nothing rolls back: a failure after POST deals (22681) leaves a deal with no stream/months, the lead unstamped, and the promotion_request still pending; a retry creates a second org/person/deal because there is no idempotency key.
- **Mechanism:** 13-36 sequential proxied round trips (~1.4 s each) for one logical transaction; plus per-row audit_row_change on 12 audited tables (~30-45 audit_log inserts, including 12+ for revenue_stream_months) and refresh_lead_next_action firing once per closed lead engagement — all in separate HTTP-scoped transactions.
- **Who feels it:** Every promote (manager direct or Accept) blocks the modal for ≈18 s (minimal package) to ≈50 s (typical package). Partial writes on any network hiccup mid-chain (the proxy does not retry writes, sb.js comment 'a write whose socket died may still have landed').

- **Fix:**

```sql
Create `promote_lead(p jsonb) returns jsonb` (SECURITY DEFINER, plpgsql) that performs the whole §1-§9 sequence in one transaction and returns {deal_id, org, person, site} so the client can update allData without refetching. Sketch:

create or replace function promote_lead(p jsonb) returns jsonb language plpgsql security definer as $$
declare v_lead bigint := (p->>'lead_id')::bigint; v_actor bigint := (p->>'actor')::bigint; v_org bigint; v_person bigint; v_site bigint; v_deal bigint; v_stream bigint; v_stage bigint; v_margin numeric := coalesce((p->>'margin')::numeric,25); c record;
begin
  if (p->>'is_new')::bool then insert into organisations(name,legal_name,website,physical_line1) values (p->>'colloquial',p->>'legal',p->>'website',p->>'address') returning id into v_org;
  else v_org := (p->>'org_id')::bigint; update organisations set name=coalesce(nullif(p->>'colloquial',''),name), legal_name=coalesce(nullif(p->>'legal',''),legal_name), website=coalesce(nullif(p->>'website',''),website), physical_line1=coalesce(nullif(p->>'address',''),physical_line1) where id=v_org; end if;
  if p->>'contact_mode'='new' then insert into people(first_name,last_name,title,email,phone) select first_name,last_name,title,email,phone from jsonb_populate_record(null::people, p->'new_person') returning id into v_person; else v_person := (p->>'existing_person_id')::bigint; end if;
  insert into person_organisation_roles(person_id,org_id,role_type,is_primary,job_title,start_date,created_by) values (v_person,v_org,'Contact', not exists(select 1 from person_organisation_roles where org_id=v_org and is_primary), nullif(p->>'job_title',''), current_date, v_actor) on conflict (person_id,org_id) do nothing;
  select id into v_site from sites where organisation_id=v_org and id=(p->>'lead_site_id')::bigint;
  if v_site is null and nullif(p->>'site_name','') is not null then select id into v_site from sites where organisation_id=v_org and lower(trim(name))=lower(trim(p->>'site_name')); if v_site is null then insert into sites(organisation_id,name,created_by) values (v_org,p->>'site_name',v_actor) returning id into v_site; end if; end if;
  if v_site is null then select id into v_site from sites where organisation_id=v_org order by is_primary desc nulls last, id limit 1; if v_site is null then insert into sites(organisation_id,name,is_primary,created_by) values (v_org,p->>'colloquial',true,v_actor) returning id into v_site; end if; end if;
  select s.id into v_stage from stages s join stage_categories sc on sc.id=s.category_id where sc.name='Opportunity-Open' and s.active order by s.sort_order limit 1;
  insert into deals(name,org_id,site_id,region_id,branch_id,stage_id,service_major_id,service_sub_id,margin_pct,order_date,start_date,notes,owner_id,created_by) select p->>'deal_name',v_org,v_site,l.region_id,l.branch_id,v_stage,l.service_major_id,(p->>'service_sub_id')::bigint,v_margin,(p->>'order_date')::date,(p->>'start_date')::date,l.description,l.owner_id,v_actor from leads l where l.id=v_lead returning id into v_deal;
  insert into deal_collaborators(deal_id,person_id,role,is_owner) select v_deal,owner_id,'Owner',true from leads where id=v_lead and owner_id is not null;
  insert into deal_contacts(deal_id,person_id) values (v_deal,v_person);
  for c in select * from jsonb_to_recordset(p->'extra_contacts') as x(person_id bigint, first_name text, last_name text, email text, phone text, job_title text, moved bool) loop /* insert people if person_id null; upsert por; insert deal_contacts */ end loop;
  insert into revenue_streams(deal_id,stream_type,locked) values (v_deal,'opportunity',false) returning id into v_stream;
  insert into revenue_stream_months(stream_id,month,opportunity_revenue,opportunity_margin) select v_stream, to_char((p->>'start_date')::date + ((m.ord-1)||' month')::interval,'YYYY-MM'), m.v::numeric, round(m.v::numeric*v_margin/100,2) from jsonb_array_elements_text(p->'month_values') with ordinality m(v,ord);
  with src as (select *, row_number() over (order by engagement_date,id) rn from engagements where lead_id=v_lead and next_action_done=false), ins as (insert into engagements(deal_id,engagement_date,engagement_type,activity_type_id,notes,next_action,next_action_id,action_details,next_action_date,next_action_done,created_by,stream_label) select v_deal,engagement_date,engagement_type,activity_type_id,notes,next_action,next_action_id,action_details,next_action_date,false,coalesce(created_by,v_actor),'Sales #'||(rn+1) from src returning id) update engagements e set stream_id=e.id from ins where e.id=ins.id;
  update engagements set next_action_done=true,next_action_completed_at=now(),next_action_completion_note='Engagement copied to opportunity for completion.' where lead_id=v_lead and next_action_done=false;
  /* promotion engagement (stream_id=id), referrer person, lead stamp (§9) — same as today */
  return jsonb_build_object('deal_id',v_deal,'org_id',v_org,'person_id',v_person,'site_id',v_site);
end $$;

Client: `const out = await api('rpc/promote_lead','POST',{p: packagePayload},'')` — sb.js forwards /rpc/* unchanged, and X-Actor-Id still reaches audit_row_change via request.headers inside the function. Then `_lkInvalidate('organisations'); _lkInvalidate('people'); _lkInvalidate('sites')` (api() only auto-busts by table name). Also fold the trailing PATCH promotion_requests (21156) and the leads status→'Promoted' stamp into the same function so Accept is 1 round trip + 1 refresh. Net: 36 → 1-2 round trips, and either everything lands or nothing does.
```

### PW-02 — Every lead action pays a read-after-write GET plus a second status PATCH (reloadLeadAfterServerChange + recomputeOpenLeadStatus) that the first PATCH's representation already makes redundant

**Impact high · effort S · query shape · spot-checked (confidence 0.9)**

- **Where:** index.html:21038-21050 reloadLeadAfterServerChange; 23466-23486 recomputeOpenLeadStatus; api() 2051 sets `Prefer: return=representation` for every PATCH. Callers in slice: 20386, 20415, 20459, 20507, 20620, 20688, 20777, 21163, 21234, 21386, 22509, 22548, 23084, 26357
- **Evidence:** applyStageRequest 20617 `await api('leads','PATCH',patch,'id=eq.'+req.lead_id)` returns the full row (representation), yet 20620 → 21041 `const rows = await apiGet('leads', `id=eq.${leadData.id}&select=*`)` refetches it, then 21044 → 23482 `await api('leads','PATCH',{status,working_at,qualified_at,updated_at},'id=eq.'+leadData.id+'&select=*')` writes the derived status in a third round trip. For Hold (status derived from wake_date), Promote (promoted_at), Decline (dead_reason) and Request (promotion_requested_at) the derived status always differs, so the third call always fires.
- **Mechanism:** 2 extra sequential proxied round trips (≈2.8 s) appended to 14 distinct user actions; the second PATCH also fires audit_row_change (jsonb_each diff of the ~90-column leads row) and leads_log_stage_event a second time.
- **Who feels it:** Stage request, resume, approve/decline request, exec kill/ignore, confirm/reject/reopen dead, decline lead, request/accept/reject promotion, promote, and every engagement save on a lead each wait ≈2.8 s longer than necessary; status flips (e.g. Hold badge) appear only after the 3rd/4th call.

- **Fix:**

```sql
Add one helper and route all 14 callers through it; compute the status client-side BEFORE the write and let the PATCH response refresh leadData:

async function patchLeadAndRefresh(patch) {
  const nowIso = patch.updated_at || new Date().toISOString();
  const next = Object.assign({}, leadData, patch);
  const st = computeLeadStatus(next, { primaryContact: null });
  patch.status = st;
  if (st === 'Working' && !next.working_at) patch.working_at = nowIso;
  if (st === 'New') patch.working_at = null;
  if (st === 'Qualified' && !next.qualified_at) patch.qualified_at = nowIso;
  const rows = await api('leads', 'PATCH', patch, `id=eq.${leadData.id}&select=*`);
  if (rows && rows[0]) leadData = rows[0];
  populateLeadForm();
}

Order each action so the leads PATCH is the LAST write (e.g. saveDecline: closeLeadOpenActions → POST lead_stage_requests → patchLeadAndRefresh), so trigger-side effects on leads (refresh_lead_next_action clearing next_action) are already in the returned representation. This turns 3-4 round trips into 1-2 per action with no DB change.
```

### PW-03 — Logging one lead engagement costs 10-13 sequential round trips; three writes hit the same new row and four independent reads run in series

**Impact high · effort M · query shape · reviewer (confidence 0.85)**

- **Where:** index.html:26134-26365 saveLeadInteraction; 26077-26094 bumpLeadLastTouch; 25120-25152 loadLeadInteractions
- **Evidence:** 26188 GET engagements (dup shield) → 26257 POST engagements → 26284 `api('engagements','PATCH',{stream_id: engId, stream_label...},'id=eq.'+engId)` → 26292 _liSyncMilestones → 26309 `api('engagements','PATCH',{contacts: refs},'id=eq.'+engId)` (refs are built from window._liPeople and do not depend on engId) → 26346 bumpLeadLastTouch: 26085 GET engagements order=engagement_date.desc limit=1 then 26090 PATCH leads → 26354 loadLeadInteractions: 25127 GET engagements, 25149 GET engagements org_id=in, 25150 _milLookups, 25151 GET engagement_milestones → 26357 GET leads → 23482 PATCH leads. Each `await` is on its own line; no Promise.all in the chain.
- **Mechanism:** Sequential proxied round trips (~1.4 s each); 3 writes to one engagements row (INSERT + 2 PATCH) each firing audit_row_change and engagements_refresh_next_action (→ SELECT + UPDATE leads + audit row) three times for one logical insert.
- **Who feels it:** ≈14-18 s spinner after 'Save' on the single most frequent action (every call, meeting, email logged by every user, daily).

- **Fix:** (a) Put `contacts: refs` in the POST body at 26257 (delete the PATCH at 26309). (b) Give stream_id a DB default so the self-PATCH at 26284/22876/22828 disappears: `create or replace function trg_eng_default_stream() returns trigger language plpgsql as $$ begin if new.stream_id is null and new.deal_id is not null then new.stream_id := new.id; end if; return new; end $$; create trigger engagements_default_stream before insert on engagements for each row execute function trg_eng_default_stream();` and send stream_label in the POST. (c) Derive last_touch from data already in hand instead of the GET at 26085: after the POST, `last_touch_date = max(engagement_date over the reloaded list where work_mode='client')` — or move it server-side into trg_engagements_refresh_next_action (`update leads set last_touch_date = (select max(engagement_date) from engagements where lead_id=new.lead_id and work_mode='client') where id=new.lead_id`), removing GET+PATCH. (d) Run the post-save reads together: `const [list, group, mil, lead] = await Promise.all([apiGet('engagements', lead_id...), apiGet('engagements','org_id=in...'), _milForEngagements(...), apiGet('leads', id=eq...)])` — or one PostgREST embed `leads?id=eq.X&select=*,engagements(*,engagement_milestones(*))` for list+milestones+lead in one call. (e) Apply PW-02 for the final status PATCH. Expected: 12 → 3-4 sequential round trips.

### PW-04 — Per-copy PATCH loop and duplicate open-engagement fetch inside commitPromotion §7.5/§8 (interim fix if PW-01 is deferred)

**Impact medium · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** index.html:22789 (GET), 22824-22831 (for loop PATCH), 22860-22878 (POST then PATCH same row); source of the duplicate: 21986 openPromoteQ4Screen1 `s._openActs = await apiGet('engagements', lead_id=eq...&next_action_done=eq.false...)`
- **Evidence:** 22789 `const openRows = await apiGet('engagements', `lead_id=eq.${leadData.id}&next_action_done=eq.false&select=*...`)` re-reads what Q4 screen 1 fetched moments earlier (same filter, only the select differs). 22824-22831: `for (let ci = 0; ci < created.length; ci++) { ... await api('engagements','PATCH',{ stream_id: cId, stream_label: 'Sales #' + (ci + 2) }, 'id=eq.' + cId); }` — one round trip per carried-forward engagement. 22876 PATCHes the promotion engagement inserted at 22860 solely to set stream_id = its own id.
- **Mechanism:** 1 duplicate GET + N+1 sequential PATCH round trips (N = open lead engagements, typically 1-5), each PATCH also firing audit_row_change and engagements_refresh_next_action.
- **Who feels it:** Adds ≈(N+2)×1.4 s ≈ 4-10 s to every promote/accept.

- **Fix:** Fetch `select=*` once at 21986 and reuse `s._openActs` at 22789 (Accept path: the package already carries the ids; refetch only if `!s._openActs`). Replace the loop with the BEFORE INSERT default from PW-03(b) plus `stream_label: 'Sales #' + (i + 2)` in the copies array at 22797-22807 and `stream_label: 'Sales'` in the promotion POST at 22860 — the N+1 PATCHes vanish. If a trigger is not wanted, PostgREST bulk upsert does it in one call: `api('engagements','POST', created.map((r,i)=>({id:r.id, deal_id:dealId, engagement_date:r.engagement_date, stream_id:r.id, stream_label:'Sales #'+(i+2)})), 'on_conflict=id')` with `Prefer: resolution=merge-duplicates` (api() would need to pass that header for this call).

### PW-05 — Non-primary contact materialisation is 4-6 sequential round trips per contact inside a for loop

**Impact medium · effort M · query shape · reviewer (confidence 0.8)**

- **Where:** index.html:22712-22755 commitPromotion §6.5
- **Evidence:** `for (const c of _leadContacts) { ... const cp = await api('people','POST',...) (22723) ... const here = await apiGet('person_organisation_roles', `person_id=eq.${cpid}&org_id=eq.${orgId}&end_date=is.null...`) (22731) ... const others = await apiGet(...) (22736) ... await api('person_organisation_roles','PATCH',...) (22737) ... await api('person_organisation_roles','POST',...) (22740) ... await api('deal_contacts','POST',...) (22750) }`
- **Mechanism:** await inside a loop: sequential depth grows linearly with the number of provisional contacts; every iteration does a read-then-write on person_organisation_roles that the UNIQUE (person_id, org_id) constraint (schema.sql:1969) could resolve server-side via on_conflict.
- **Who feels it:** A lead with 3 extra contacts adds ≈12-18 s to promote/accept.

- **Fix:** Inside PW-01's RPC this is a single loop in plpgsql (no network). Interim client-side: (1) bulk `POST people` with an array body for all new contacts (PostgREST returns rows in input order); (2) one `GET person_organisation_roles?person_id=in.(ids)&org_id=eq.X&end_date=is.null` for all; (3) one `POST person_organisation_roles?on_conflict=person_id,org_id` array with `Prefer: resolution=ignore-duplicates` for the affiliations; (4) one array `POST deal_contacts`. 4 round trips total regardless of contact count instead of 4-6 × N.

### PW-06 — Dead/decline/reopen/request actions write 2-4 rows sequentially with no transaction — small RPCs or parallel writes

**Impact medium · effort M · db view or rpc · reviewer (confidence 0.8)**

- **Where:** index.html:23050-23090 saveDecline; 20752-20781 saveDeclineStageRequest; 20356-20390 saveExecFlagVerdict; 20489-20511 saveReopenLead; 22516-22560 savePromoteAsRequest; 21212-21243 submitRejectPromotion; 20398-20404 _updatePendingDeadRequest (GET then PATCH)
- **Evidence:** saveDecline: 23065 PATCH leads → 23074 PATCH engagements → 23077 POST lead_stage_requests → reload (2 more). saveExecFlagVerdict kill: 20363 PATCH lead_red_flags → 20373 PATCH leads → 20382 PATCH engagements → 20385 loadLeadQualificationSelections (2 GETs) → reload (2). savePromoteAsRequest: 22529 POST promotion_requests → 22539 PATCH leads → reload (2). _updatePendingDeadRequest: 20400 `apiGet('lead_stage_requests', lead_id=eq&status=eq.pending&request_type=eq.dead&...limit=1)` then 20402 PATCH by id — a filter-PATCH would do it in one. None of the writes in any of these functions are independent-but-parallel today, and none are transactional: saveDecline can leave a Dead lead with no oversight queue row; savePromoteAsRequest can leave a pending promotion_requests row with no lead pointer (badge missing, re-request creates a second pending row).
- **Mechanism:** 3-7 sequential proxied round trips per action for one logical transaction; independent writes (lead PATCH, engagements PATCH, lead_stage_requests POST) serialised by successive awaits.
- **Who feels it:** Decline ≈8-10 s, Exec kill ≈10 s, Request promotion ≈5.6 s, Reject ≈5.6 s — each a modal that stays blocked.

- **Fix:** Preferred: one plpgsql function per lifecycle action, e.g. `lead_decline(p_lead bigint, p_reason text, p_reason_id bigint, p_notes text, p_actor bigint, p_self_oversee bool) returns leads` that updates leads, closes open engagements (`update engagements set next_action_done=true, next_action_completed_at=now(), next_action_completion_note=... where lead_id=p_lead and next_action_done=false and next_action is not null`), inserts the lead_stage_requests row and returns the updated lead row (status computed client-side is passed in, or the function sets status='Dead'). Same shape for `lead_stage_request(...)`, `lead_reopen(...)`, `promotion_request_submit(...)`, `promotion_request_reject(...)`. Client: `leadData = (await api('rpc/lead_decline','POST',{...},''))` then populateLeadForm — 1 round trip, atomic. Interim without SQL: `await Promise.all([closeLeadOpenActions(...), api('lead_stage_requests','POST',...)])` then the single leads PATCH from PW-02; replace _updatePendingDeadRequest's GET+PATCH with `api('lead_stage_requests','PATCH',patch,`lead_id=eq.${id}&status=eq.pending&request_type=eq.dead`)`.

### PW-07 — Group stage cohesion PATCHes each pulled sibling lead one at a time

**Impact low · effort S · query shape · reviewer (confidence 0.75)**

- **Where:** index.html:14395-14417 applyGroupStageCohesion (called from submitStageRequest 20597 and sweepNewToWorking); 14385-14393 _groupMemberLeads
- **Evidence:** `for (const m of pulled) { const patch = { status: targetStage, updated_at: now }; if (!m.working_at) patch.working_at = now; if (targetStage === LEAD_STAGE_X) patch.nurture_cadence_days = m.nurture_cadence_days || cadence; await api('leads','PATCH',patch,'id=eq.'+(+m.id)); }` preceded by GET sites (14388) then GET leads (14392) in series.
- **Mechanism:** 2 + N sequential proxied round trips, un-awaited by the caller but each holding _netBusy and each firing audit_row_change + leads_log_stage_event; the sites→leads GETs are serial although the leads filter only needs site ids when sites exist.
- **Who feels it:** Moving a group member to Nurture keeps the network bar busy for (2+N)×1.4 s and competes with the user's next click for proxy capacity; a 6-site estate group ≈ 11 s of background traffic.

- **Fix:** Group members by identical patch and issue one filtered PATCH per group: members with working_at set → `PATCH leads?id=in.(a,b,c)` {status, updated_at, nurture_cadence_days} for those lacking a cadence, another for those that have one, and a third for the no-working_at set — at most 3 round trips regardless of N. Or one RPC `cohere_group_stage(p_root_org bigint, p_stage text, p_cadence int)` doing `update leads set status=..., working_at=coalesce(working_at,now()), nurture_cadence_days=coalesce(nurture_cadence_days,p_cadence) where (target_org_id = any(...) or site_id in (select id from sites where organisation_id = any(...))) and ...` in one statement.

### PW-08 — _liSyncMilestones and deal engagement_people sync issue one write per checkbox / per person

**Impact low · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** index.html:25087-25120 _liSyncMilestones (25101 POST, 25109 PATCH, 25116 DELETE inside `for (const cb of boxes)`); 26299-26305 saveLeadInteraction deal branch `for (const p of (window._liPeople || [])) { ... await api('engagement_people','POST',...) }`
- **Evidence:** `for (const cb of boxes) { ... if (cb.checked && !row) { await api('engagement_milestones','POST',{...},''); } else if (...) { await api('engagement_milestones','PATCH',...); } else if (...) { await api('engagement_milestones','DELETE',null,'id=eq.'+row.id); } }` and `if (editId) await api('engagement_people','DELETE',null,'engagement_id=eq.'+engId); for (const p of ...) await api('engagement_people','POST',{engagement_id: engId, person_id: +p.person_id},'')`. engagement_people has UNIQUE (engagement_id, person_id) (schema.sql:1785).
- **Mechanism:** await inside loops: sequential round trips proportional to milestones ticked / people involved; PostgREST accepts array bodies for POST and `id=in.()` filters for DELETE.
- **Who feels it:** A meeting with 4 attendees and 2 milestones adds ≈8 s to the engagement save.

- **Fix:** Milestones: collect `toInsert[]`, `toReset[]`, `toDeleteIds[]` then `await Promise.all([ toInsert.length && api('engagement_milestones','POST',toInsert,''), toDeleteIds.length && api('engagement_milestones','DELETE',null,`id=in.(${toDeleteIds.join(',')})`), ...toReset.map(r => api('engagement_milestones','PATCH',...)) ])`. People: one `api('engagement_people','POST', people.map(p=>({engagement_id: engId, person_id:+p.person_id})), 'on_conflict=engagement_id,person_id')` with `Prefer: resolution=ignore-duplicates` (extend api() to accept an extra header), replacing DELETE + N POSTs with 1-2 calls.

### PW-09 — Modal-open lookups awaited in series when they are independent (Q4 screen 1, Decline modal, commitPromotion §3/§3.5)

**Impact low · effort S · parallelise · reviewer (confidence 0.9)**

- **Where:** index.html:21970 then 21986 openPromoteQ4Screen1; 22975 then 22984 openDeclineModal; 22605, 22607, 22626 commitPromotion
- **Evidence:** openPromoteQ4Screen1: `allData['_next_actions_opps'] = await apiGet('next_actions', ...)` (21970) then `s._openActs = await apiGet('engagements', ...)` (21986). openDeclineModal: `reasons = await apiGet('decline_reasons', ...)` (22975) then `openActs = await apiGet('engagements', ...)` (22984). commitPromotion: GET por person+org (22605) → GET por org+is_primary (22607) → later GET sites organisation_id (22626): three reads that depend only on orgId/personId known up front; the first two can be one query.
- **Mechanism:** Independent GETs serialised by successive awaits: 2 round trips where 1 wall-clock round trip would do.
- **Who feels it:** Decline modal and Q4 screen 1 each take ≈2.8 s to open instead of ≈1.4 s (first open of session); promote loses another ≈2.8 s.

- **Fix:** `const [na, acts] = await Promise.all([ allData['_next_actions_opps'] ? Promise.resolve(allData['_next_actions_opps']) : apiGet('next_actions', ...), apiGet('engagements', ...) ])` at 21970-21986 and the same shape at 22975-22984. In commitPromotion replace 22605+22607 with one `GET person_organisation_roles?org_id=eq.${orgId}&select=id,person_id,is_primary` (answers both 'already linked?' and 'has a primary?') and run it in Promise.all with the sites GET at 22626: 3 → 1 round trip.

### PW-10 — Write-path lookups on person_organisation_roles(org_id), sites(organisation_id) and the free-text lead-link trigger have no supporting index

**Impact low · effort S · db index · reviewer (confidence 0.6)**

- **Where:** sql/schema.sql:1969 (UNIQUE (person_id, org_id) only), schema.sql:224-243 trg_orgs_link_freetext_leads, scratchpad index_inventory.txt (no CREATE INDEX on sites or person_organisation_roles); client predicates: predicates.txt person_organisation_roles `17 org_id=eq`, sites `1 organisation_id=eq, 2 organisation_id=in`; hits in slice at index.html:21736, 22607, 22626, 14388
- **Evidence:** person_organisation_roles has UNIQUE (person_id, org_id) — usable for person_id-leading lookups but not for `org_id=eq.X` (17 call sites) or `org_id=eq.X&is_primary=eq.true` (22607). sites has no index on organisation_id (22626, 14388). `orgs_link_freetext_leads` runs `UPDATE leads ... WHERE target_org_id IS NULL AND target_org_name IS NOT NULL AND lower(trim(target_org_name)) = lower(trim(NEW.name))` on every organisations INSERT/name UPDATE (22574, 22589, findOrCreateProspectOrg 21552) — a sequential scan on leads with no matching expression index.
- **Mechanism:** Sequential scans on each of these lookups/trigger statements. At the presumed current volume (hundreds to a few thousand rows per table) each scan is a few ms, so this is dwarfed by the 1.4 s proxy round trip — it becomes material only once these tables reach tens of thousands of rows.
- **Who feels it:** Negligible today (ms), grows linearly with people/orgs/sites/leads growth; the same lookups are on the promote and org-screen critical path.

- **Fix:**

```sql
create index if not exists por_org_idx on person_organisation_roles (org_id, is_primary) where end_date is null;
create index if not exists sites_org_idx on sites (organisation_id);
create index if not exists leads_freetext_org_idx on leads (lower(trim(target_org_name))) where target_org_id is null and target_org_name is not null;
(Also worth adding while there: `create index if not exists engagements_deal_idx on engagements (deal_id)` — no index exists on engagements.deal_id anywhere in sql/, and the deal engagement list and refresh paths filter on it.)
```

### PW-11 — Row-level audit + next-action triggers multiply per-statement work on the promote path (only matters once round trips are collapsed)

**Impact low · effort M · db trigger · reviewer (confidence 0.5)**

- **Where:** sql/add_audit_log.sql:31-70 audit_row_change (row-level on organisations, people, sites, deals, deal_contacts, deal_collaborators, person_organisation_roles, revenue_streams, revenue_stream_months, engagements, promotion_requests, lead_red_flags, leads); sql/unify_engagements.sql:77-96 trg_engagements_refresh_next_action; index.html:22781 (12+ month rows), 22834 (bulk close)
- **Evidence:** One typical promote inserts ~30-45 audit_log rows (12 of them for revenue_stream_months at 22781, 3 for engagement copies, 3 for the close PATCH at 22834, plus one per org/person/site/deal/contacts/stream/lead write). The close PATCH at 22834 fires refresh_lead_next_action once per closed row, each doing `SELECT ... FROM engagements WHERE lead_id=... ORDER BY next_action_date, id DESC LIMIT 1` then `UPDATE leads ... WHERE id=p_lead_id` — N identical updates of the same leads row, each producing another audit_log row via the leads audit trigger. UPDATEs on leads diff the ~90-column row with two jsonb_each() joins per row.
- **Mechanism:** Trigger work per row inside each statement's transaction; N repeated UPDATE leads for one statement; jsonb diff on wide rows.
- **Who feels it:** Low today — each trigger call is sub-millisecond to a few ms, so it is hidden under the 1.4 s proxy latency; it becomes the visible residual once PW-01/PW-02 remove the round trips.

- **Fix:** Make refresh_lead_next_action idempotent per statement: convert engagements_refresh_next_action to a statement-level trigger using transition tables (`AFTER UPDATE ... REFERENCING NEW TABLE AS n FOR EACH STATEMENT` then `PERFORM refresh_lead_next_action(lead_id) FROM (select distinct lead_id from n where lead_id is not null) x`), and add `AND (next_action, next_action_date) IS DISTINCT FROM (v_next_action, v_next_action_date)` to its UPDATE leads so unchanged leads produce no write/audit row. Optionally drop revenue_stream_months from the audited table list in add_audit_log.sql (rows are fully derivable from the stream and re-generated on every edit) — a product decision, so flagged rather than assumed.


## Engagement History, Attention, Reports, Milestones, Internal Activity

### ATT-1 — Attention 'Outstanding actions' fetches the whole leads and deals tables sequentially to label a few open actions; embed the parents in the engagements query

**Impact high · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** index.html:12373-12410 (_attentionActionRows)
- **Evidence:** 12376-12377 `acts = await apiGet('engagements', 'next_action_done=eq.false&next_action_date=not.is.null&select=id,lead_id,deal_id,...')`; 12394 `const leads = await apiGet('leads', 'select=id,owner_id,branch_id,region_id,target_org_name,description,site_id,site_name,sites(name)');` 12395 `const deals = await apiGet('deals', 'select=id,owner_id,branch_id,region_id,name');` — two whole-table reads awaited one after the other, only to look up the parents of `acts`. Called by both the dashboard card (12412) and the Attention page (24157).
- **Mechanism:** 3 sequential round trips (~4 s) and whole-table payloads (all leads incl. Dead/Promoted, all deals) where only the parents of open actions are needed; plain apiGet also silently caps at 1000 rows.
- **Who feels it:** Every dashboard render (Outstanding Actions card) and every Attention Workbench open.

- **Fix:**

```sql
One call:

engagements?next_action_done=eq.false&next_action_date=not.is.null&select=id,lead_id,deal_id,next_action,next_action_date,engagement_type,stream_id,engagement_date,leads(id,owner_id,branch_id,region_id,target_org_name,description,site_id,site_name,sites(name)),deals(id,owner_id,branch_id,region_id,name)&order=next_action_date.asc

then `parent = a.leads || a.deals`. Keep the per-stream dedupe in JS, or move it into a view so the client never sees superseded rows:

create view v_open_actions as
select distinct on (coalesce(e.stream_id, e.id)) e.id, e.lead_id, e.deal_id, e.next_action, e.next_action_date, e.engagement_type, e.stream_id, e.engagement_date
from engagements e where e.next_action_done = false and e.next_action_date is not null
order by coalesce(e.stream_id, e.id), e.engagement_date desc, e.id desc;

(PostgREST embeds through views whose columns map to the base FK columns.) Depth 3 -> 1 for both the card and the page. Pair with the partial index in IDX-1.
```

### EH-1 — Engagement History pays 8-18 sequential round trips; PostgREST embedding collapses it to 1-2

**Impact high · effort M · query shape · spot-checked (confidence 0.85)**

- **Where:** index.html:16533-16617 (_engHistLoad), 24012-24023 (_milForEngagements), 16564-16569 (missingRoots loop), 16584-16587
- **Evidence:** 16540: `const engs = await apiGet('engagements', ...&select=*&order=engagement_date.desc,id.desc&limit=1000)`; 16546-16551 Promise.all(deals, leads, engagement_people, service_sub); 16557-16558 `await _milLookups(); st.milestones = await _milForEngagements(engIds);` whose body is `for (let i = 0; i < engIds.length; i += 150) { (await apiGet('engagement_milestones', ...)) }` (24016-24020); 16564-16569 `for (let i = 0; i < missingRoots.length; i += 150) { ... await apiGet('engagements', id=in.(...)&select=id,stream_label) }`; 16584-16587 a further Promise.all for people and organisations names. All FKs needed for embedding exist: engagements_deal_id_fkey, engagements_lead_id_fkey (unify_engagements.sql:31-33), engagement_people_engagement_id_fkey/person_id_fkey (schema.sql:2380,2388), deals_org_id_fkey/deals_owner_id_fkey, leads_target_org_id_fkey/leads_owner_id_fkey/leads_target_person_id_fkey. The app already uses embedding (`sites(name)` at 16548).
- **Mechanism:** Extra sequential round trips: depth = 4 + ceil(N/150) + ceil(R/150). At the default 180-day window with ~1000 rows that is up to 18 proxied hops (~1.4 s each) before anything renders; ~8 hops (~11 s) at 300 rows. The chunk loops are `for ... await`, so 150-id batches run one after another even though they are independent.
- **Who feels it:** Every user opening Engagement History (Outreach/Sales/Contract/Project are the first nav items for many roles), and again on every Category or date change, and again after every milestone decision (_milAfterChange 24047). Typically 10-25 s of 'Loading engagement history...'.

- **Fix:**

```sql
Replace steps 2-6 with one embedded select on the engagements query (step 1), then run only the out-of-window root-label lookup in parallel with it:

engagements?deal_id=not.is.null&engagement_date=gte.<from>&select=id,deal_id,lead_id,engagement_date,engagement_type,notes,next_action,next_action_date,next_action_done,duration_minutes,work_mode,stream_id,stream_label,created_by,deals(id,name,org_id,stage_id,service_sub_id,owner_id,organisations(name),owner:people!deals_owner_id_fkey(first_name,last_name)),leads(id,target_org_id,target_org_name,target_person_id,target_person_name,description,owner_id,site_id,site_name,sites(name),org:organisations!leads_target_org_id_fkey(name),owner:people!leads_owner_id_fkey(first_name,last_name),contact:people!leads_target_person_id_fkey(first_name,last_name)),engagement_people(person_id,people(first_name,last_name)),engagement_milestones(*)&order=engagement_date.desc,id.desc&limit=1000

Then build dealsById/leadsById/peopleByEng/st.milestones from the nested objects (no change to st.rows shape). For stream roots outside the window: either add an FK engagements.stream_id -> engagements(id) and embed `root:engagements!engagements_stream_id_fkey(stream_label)`, or keep one query `engagements?id=in.(<roots>)&select=id,stream_label` but fire the 150-id chunks with Promise.all instead of a serial loop. Result: depth 1-2 instead of 8-18. Keep _milLookups (cached per session) in the same Promise.all.
```

### LI-2 — Saving a lead engagement costs 12-14 sequential round trips and writes the new row three times; fold fields into the insert and parallelise the follow-ups

**Impact high · effort M · query shape · reviewer (confidence 0.85)**

- **Where:** index.html:26134-26346 (saveLeadInteraction), 26077-26093 (bumpLeadLastTouch), 25078-25117 (_liSyncMilestones), 21038-21050 (reloadLeadAfterServerChange)
- **Evidence:** 26251 `await api('engagements','POST',{...payload,...target,created_by},'select=*')`; 26279-26282 new stream: `await api('engagements','PATCH',{stream_id: engId, stream_label},'id=eq.'+engId)`; 26301 `await api('engagements','PATCH',{contacts: refs},'id=eq.'+engId)` — the same row is written 3 times; 26272 supersede PATCH; 26287 `_liSyncMilestones` (per checkbox `await api(...)`, 25086-25116); 26333 `bumpLeadLastTouch` = GET newest client engagement (26085) + PATCH leads (26091); 26341 `await loadLeadInteractions(...)` (3 reads, 25127/25145/25150); 26344 `await reloadLeadAfterServerChange()` (GET leads 21041, then PATCH via recomputeOpenLeadStatus 23483). Each engagement write fires `audit_engagements` (jsonb_each diff, add_audit_log.sql:43-49) and `engagements_refresh_next_action` (unify_engagements.sql:94-96 -> refresh_lead_next_action: SELECT engagements by lead + UPDATE leads -> audit_leads + leads_log_stage_event).
- **Mechanism:** Sequential round trips (depth 12-14 ~ 17-20 s in the busy state) and write amplification (3 engagement writes + 2-3 leads updates + 5+ audit_log rows for one logical save).
- **Who feels it:** Every engagement save by every sales user; the 'Logging engagement...' overlay is the single most repeated wait in the app.

- **Fix:**

```sql
Step 1 (S): put `contacts: refs` and `stream_label` into the POST body (26251) and drop the PATCHes at 26279 and 26301; make stream_id self-default in the DB so no second write is needed:

create or replace function trg_engagements_default_stream() returns trigger language plpgsql as $$
begin if new.stream_id is null and new.lead_id is not null or new.deal_id is not null then new.stream_id := new.id; end if; return new; end $$;
create trigger engagements_default_stream before insert on engagements for each row execute function trg_engagements_default_stream();

(new.id is already assigned from the sequence default in a BEFORE ROW trigger.) Step 2 (S): run the independent follow-ups together — `await Promise.all([supersedePatch, _liSyncMilestones(engId), bumpLeadLastTouch(leadId,{woke_at:null})])` and then `await Promise.all([loadLeadInteractions(id), reloadLeadAfterServerChange()])` (the lead GET does not depend on the interactions GET). Step 3 (M, optional): an RPC `log_engagement(p jsonb)` that inserts the row, applies the supersede, upserts milestones and returns the row in one transaction (`api('rpc/log_engagement','POST',{p},'')` already routes through sb.js, which rewrites /.netlify/functions/sb/<x> to /rest/v1/<x>). Expected depth after steps 1-2: ~6.
```

### MIL-1 — Milestones register joins designations -> engagements -> parents with a sequential chunk loop; one embedded query does it

**Impact high · effort S · query shape · reviewer (confidence 0.8)**

- **Where:** index.html:24785-24800 (renderMilestonesPage)
- **Evidence:** 24786 `apiGetAll('engagement_milestones', 'select=*&order=proposed_at.desc')`; 24792-24794 `for (let i = 0; i < engIds.length; i += 150) (await apiGet('engagements', \`id=in.(...)&select=id,lead_id,deal_id,engagement_date,engagement_type\`)).forEach(...)`; 24797-24800 Promise.all(leads id=in (+sites(name,organisation_id)), deals id=in). The dashboard Milestone Pulse (24968-24985) and Approvals widget (12349-12355) repeat the same pattern.
- **Mechanism:** Sequential round trips: depth 1 + pages + ceil(M/150) + 1 where M is the all-time milestone count (register loads every designation, all statuses). M=500 -> 7 hops, ~10 s; grows with history.
- **Who feels it:** Reviewers opening Milestones, and again after every approve/decline/withdraw (_milAfterChange 24052 re-runs renderMilestonesPage).

- **Fix:**

```sql
One call (page with apiGetAll):

engagement_milestones?select=*,engagements(id,lead_id,deal_id,engagement_date,engagement_type,leads(id,owner_id,target_org_id,target_org_name,site_id,site_name,description,sites(name,organisation_id),org:organisations!leads_target_org_id_fkey(name)),deals(id,owner_id,name,org_id,site_id,organisations(name))),proposer:people!engagement_milestones_proposed_by_fkey(first_name,last_name),decider:people!engagement_milestones_decided_by_fkey(first_name,last_name)&order=proposed_at.desc

Then `const e = m.engagements; const parent = e.leads || e.deals;` in the items loop — the organisations/people whole-table fetches (24787-24788) become unnecessary. Depth: 2 (lookups + one paged read). Requires the FK engagement_milestones.engagement_id -> engagements(id) (the milestones migration is referenced as sql/add_engagement_milestones.sql at 24782 but is not in the repo — verify the FK exists; add `alter table engagement_milestones add constraint engagement_milestones_engagement_id_fkey foreign key (engagement_id) references engagements(id) on delete cascade` if not). Optionally add `status=eq.<tab>` server-side and load 'All' lazily, since the register defaults to the Pending tab.
```

### RPT-1 — Activity report runs ~20 sequential round trips; parallelise and embed parents/milestones to reach depth 1-2

**Impact high · effort M · query shape · reviewer (confidence 0.85)**

- **Where:** index.html:24435-24490 (_rptActivity)
- **Evidence:** 24444 `const engs = await apiGetAll('engagements', ...)`; 24452 `const futureRows = await apiGet('engagements', engagement_date=gt...)`; 24460 `stageEvents = await apiGetAll('lead_stage_events', ...)`; 24466-24470 `for (let i = 0; i < engIds.length; i += 150) mils.push(...await apiGet('engagement_milestones', ...))`; 24471 `await _milLookups()`; 24482-24485 `for (...) (await apiGet('leads', id=in.(...)&select=id,owner_id,region_id,branch_id,status,target_org_id,target_org_name,site_name,description))`; 24486-24488 same for deals; 24489-24490 `allData['organisations'] = await apiGet(...)` / `allData['people'] = await apiGet(...)` sequentially. Nothing between these awaits depends on the previous result except the id lists, which embedding removes.
- **Mechanism:** Sequential round trips: depth = pages + 3 + ceil(N/150) + ceil(L/150) + ceil(D/150) (+2 lookups). For 'Last 12 months' with ~1500 engagements, 400 leads, 200 deals: ~20 hops = ~28 s. 'All time' is worse.
- **Who feels it:** Sales management opening Reports, and again on every preset / date / scope / interval click.

- **Fix:**

```sql
Fire the three independent reads together and let PostgREST do the joins:

const [engs, futureRows, stageEvents] = await Promise.all([
  apiGetAll('engagements', `engagement_date=gte.${winFrom}&engagement_date=lte.${st.to}&select=id,lead_id,deal_id,engagement_date,engagement_type,created_by,work_mode,leads(id,owner_id,region_id,branch_id,status,target_org_id,target_org_name,site_name,description),deals(id,owner_id,region_id,branch_id,name),engagement_milestones(milestone_type_id,status)`),
  apiGet('engagements', `engagement_date=gt.${st.to}&select=id,lead_id,deal_id,engagement_type,created_by,work_mode,leads(owner_id,region_id,branch_id),deals(owner_id,region_id,branch_id)&limit=500`),
  apiGetAll('lead_stage_events', `to_status=eq.Qualified&at=gte.${winFrom}&at=lt.${_rptAddDays(st.to,1)}&select=lead_id,at,from_status,leads(id,owner_id,region_id,branch_id,status,target_org_id,target_org_name,site_name,description,org:organisations!leads_target_org_id_fkey(name))`),
  _milLookups(),
]);

parentOf(e) becomes `e.leads || e.deals`; mils = engs.flatMap(e => e.engagement_milestones.map(m => ({...m, engagement_id: e.id}))); orgLabel reads l.org.name; the organisations/people whole-table fetches (24489-24490) are no longer needed for anything but pName (created_by) — embed `creator:people!engagements_created_by_fkey(first_name,last_name)` on the engagements select instead. Depth becomes 1 (+ paging). If the report grows further, move the bucketing itself into an RPC `rpt_activity(p_from date, p_to date)` returning one row per (period, measure, key) with GROUP BY date_trunc, but the embedded version already removes ~90% of the wait.
```

### ATT-2 — Attention 'Leads needing attention' pulls every lead (incl. Dead/Promoted) and every group engagement; filter server-side and aggregate touches in a view

**Impact medium · effort S · payload · reviewer (confidence 0.8)**

- **Where:** index.html:12139-12175 (_attentionLeadItems), 14286-14299 (_loadOrgTouches), 23492-23511 (sweepHoldWake)
- **Evidence:** 12140-12141 `const leads = await apiGet('leads', 'select=id,owner_id,branch_id,...,sites(name)')` (27 columns, no filter); 12157 `if (l.status === 'Dead' || l.status === 'Promoted') continue;` discards them client-side; 14290 `apiGet('engagements', 'org_id=not.is.null&select=org_id,engagement_date,work_mode')` then reduces to max(engagement_date) per org in JS (14291-14296); 23497-23509 `for (const l of due) { ... await api('leads', 'PATCH', patch, 'id=eq.' + l.id); }` one PATCH per woken lead, sequential. The same collector runs on the dashboard banner (12180).
- **Mechanism:** Over-fetch bytes (Dead/Promoted leads are the growing majority over time; every org engagement row streamed to compute one date per org) plus 3 sequential hops before the aging loop can run, plus k sequential PATCHes on wake days.
- **Who feels it:** Dashboard load for every role (banner) and the Attention Workbench.

- **Fix:**

```sql
(1) 12140: add `&status=not.in.(Dead,Promoted)` (idx_leads_status exists) — identical results, smaller payload. (2) Replace _loadOrgTouches' row pull with a grouped view:

create view v_org_last_touch as
select org_id, max(engagement_date) as last_touch from engagements
where org_id is not null and coalesce(work_mode,'client') <> 'internal' and engagement_date is not null group by org_id;

and `apiGet('v_org_last_touch','select=org_id,last_touch')` (rows = orgs with group activity, not engagements). (3) sweepHoldWake: fire the PATCHes with Promise.all (disjoint rows), or one RPC `wake_due_leads()` doing `update leads set wake_date=null, woke_at=now(), working_at=coalesce(working_at,now()) where status='Hold' and wake_date<=current_date and promoted_at is null and dead_reason is null returning *` (status derivation would need porting or a follow-up client PATCH). (4) Run the two collectors' first reads in the same Promise.all as today but have the Attention page reuse the dashboard's results when navigated from it (pass them via _attnState) to avoid paying the trace twice within seconds.
```

### EH-2 — Bulk 'Shift due dates' issues one PATCH per distinct date then reloads the whole page; a single RPC UPDATE does it in one hop

**Impact medium · effort S · db view or rpc · reviewer (confidence 0.8)**

- **Where:** index.html:16770-16805 (applyEngShift)
- **Evidence:** 16791-16798: `for (const [cur, ids] of byDate) { ... for (let i = 0; i < ids.length; i += 150) await api('engagements','PATCH',{ next_action_date: next }, \`id=in.(${ids.slice(i,i+150).join(',')})\`); }` — one awaited PATCH per distinct current date; 16801 `await _engHistReload();` afterwards. Each updated row fires audit_engagements (jsonb_each diff) and engagements_refresh_next_action -> UPDATE leads (unify_engagements.sql:78-96), so a lead with several shifted engagements is re-updated once per engagement.
- **Mechanism:** D sequential round trips (D distinct dates, typically 5-20 when 'moving the pile') plus the full history reload (8-18 hops). Postgres can express the whole shift as one statement.
- **Who feels it:** Sales users clearing their follow-up backlog; ~10-50 s per shift.

- **Fix:**

```sql
create or replace function shift_next_action_dates(p_ids bigint[], p_days int) returns setof engagements language sql as $$
  update engagements set next_action_date = next_action_date + p_days
  where id = any(p_ids) and next_action_done = false and next_action_date is not null returning *; $$;

Client: `const upd = await api('rpc/shift_next_action_dates','POST',{ p_ids: targets.map(r=>+r.e.id), p_days: days },'')` then update `st.rows` in place from the returned rows and call `_engHistApply()` instead of `_engHistReload()`. One hop total. (If an RPC is not wanted, at minimum run the byDate PATCHes with Promise.all — the id sets are disjoint — and patch st.rows locally.)
```

### IA-1 — Internal Activity fetches participants in sequential 150-id chunks; embed engagement_people and the project name

**Impact medium · effort S · query shape · reviewer (confidence 0.8)**

- **Where:** index.html:26433-26449 (_intActLoad), 26418-26421
- **Evidence:** 26437-26438 `st.rows = await apiGetAll('engagements', \`work_project_id=not.is.null${fromQ}${toQ}&select=*&order=engagement_date.desc,id.desc\`)`; 26442-26447 `for (let i = 0; i < engIds.length; i += 150) { ... (await apiGet('engagement_people', \`engagement_id=in.(...)&select=engagement_id,person_id\`)) }`; 26418 separately fetches work_projects and (if not cached) all people just to resolve names (26499 `st.people.find` per participant).
- **Mechanism:** Sequential round trips: depth 1 + pages + ceil(N/150); select=* streams notes/action_details for every row.
- **Who feels it:** Everyone logging internal time (page load and every From/To change via reloadIntAct 26478).

- **Fix:**

```sql
engagements?work_project_id=not.is.null&engagement_date=gte.<from>&select=id,engagement_date,engagement_type,notes,duration_minutes,work_mode,work_project_id,created_by,work_projects(id,name),engagement_people(person_id,people(first_name,last_name))&order=engagement_date.desc,id.desc

Build peopleByEng from the nested array; drop the chunk loop and the people whole-table read for name resolution. The work_projects list is still needed for the 'Log against' picker — keep that one call in parallel. Depth -> 1 (+paging). Requires FK engagements.work_project_id -> work_projects(id) (migration sql/add_engagement_time.sql is referenced at 26428 but not in the repo; add the FK if missing).
```

### LI-1 — Opening 'Log Engagement' on a lead runs 3-4 independent fetches back-to-back, one of them a duplicate of data already loaded

**Impact medium · effort S · parallelise · reviewer (confidence 0.85)**

- **Where:** index.html:25563-25577 (openLeadInteractionModal), 25589-25599 (openLeadInteractionRelated), 25969-25977 (_liInitStreamSection), 25741-25766 (_liLoadPeople), 25603-25608 (leadCadenceModalContext)
- **Evidence:** 25573-25576: `await loadLiLookups(); await maybeApplyCadencePrefill(); await _liLoadPeople(); await _liInitStreamSection();` — four sequential awaits. _liInitStreamSection 25976-25977 fetches `engagements?lead_id=eq.${parent.id}&select=id,stream_id,stream_label,engagement_date,next_action,next_action_date,next_action_done&order=...&limit=1000` although loadLeadInteractions (25127-25128) already loaded `engagements?lead_id=eq.${leadId}&select=*` into `leadInteractions` for the same lead when the form opened. _liLoadPeople 25764 re-reads `leads?id=eq.${parent.id}&select=contacts` although leadData.contacts is in memory (18061).
- **Mechanism:** 3-4 sequential proxied round trips (~4-6 s) before the form is interactive; two of them re-fetch data the page already has.
- **Who feels it:** Every 'Log Engagement' / '+ Related engagement' click on a lead — the most frequent write path in the app.

- **Fix:** (1) Run them together: `await Promise.all([loadLiLookups(), maybeApplyCadencePrefill(), _liLoadPeople(), _liInitStreamSection()])` (maybeApplyCadencePrefill only touches DOM after its fetch, and preselect order is unaffected because nothing here depends on another's result). (2) In _liInitStreamSection, when `window._engParent.kind==='lead' && Array.isArray(leadInteractions) && +leadData?.id === +parent.id`, build `rows` from `leadInteractions` (same lead, select=* superset) and skip the GET; keep the fetch for the deal/standalone paths. (3) In _liLoadPeople use `leadData.contacts` when the open lead matches parent.id, else fetch. Result: 0-1 round trips after the first open in a session.

### LI-3 — leads.last_touch_date is recomputed by the browser (GET + PATCH) although a trigger already scans the lead's engagements on every write

**Impact medium · effort M · db trigger · reviewer (confidence 0.7)**

- **Where:** index.html:26077-26093 (bumpLeadLastTouch), sql/unify_engagements.sql:53-96 (refresh_lead_next_action / engagements_refresh_next_action)
- **Evidence:** 26085 `rows = await apiGet('engagements', \`lead_id=eq.${leadId}&work_mode=eq.client&select=engagement_date&order=engagement_date.desc.nullslast&limit=1\`)`; 26091 `await api('leads','PATCH', {last_touch_date: last, updated_at, ...extraPatch}, 'id=eq.'+leadId)`. Meanwhile the AFTER INSERT/UPDATE/DELETE trigger on engagements already runs `SELECT ... FROM engagements WHERE lead_id = p_lead_id ...` and `UPDATE leads SET next_action..., updated_at = now()` for the same lead (unify_engagements.sql:60-75).
- **Mechanism:** Two extra sequential round trips per save (~3 s) and a second UPDATE on the leads row (second audit_leads insert) for a value the DB can set in the same statement it already executes.
- **Who feels it:** Every lead engagement save (26333) and every standalone lead engagement save from the dashboard (26325).

- **Fix:**

```sql
Extend refresh_lead_next_action to also maintain last_touch_date in the same UPDATE:

UPDATE public.leads SET next_action = v_next_action, next_action_date = v_next_action_date,
  last_touch_date = (select max(engagement_date) from engagements where lead_id = p_lead_id and coalesce(work_mode,'client') = 'client'),
  updated_at = now() WHERE id = p_lead_id;

Add `woke_at = case when tg_op='INSERT' and coalesce(new.work_mode,'client')='client' then null else woke_at end` via a parameter if the wake-clear must stay tied to a new client touch. Then bumpLeadLastTouch reduces to nothing (or a single PATCH for woke_at only where still needed) — removes one GET and one PATCH from every save and halves the leads UPDATE count per save.
```

### LI-4 — People-involved and milestone sync write one HTTP call per row; PostgREST bulk insert/upsert does each in one call

**Impact medium · effort S · query shape · reviewer (confidence 0.8)**

- **Where:** index.html:26291-26296 (engagement_people sync), 25078-25117 (_liSyncMilestones)
- **Evidence:** 26293-26295: `if (editId) await api('engagement_people','DELETE',null,'engagement_id=eq.'+engId); for (const p of (window._liPeople||[])) { ... await api('engagement_people','POST',{engagement_id: engId, person_id: +p.person_id}, '') }` — N sequential POSTs. 25086-25116: `for (const cb of boxes) { ... await api('engagement_milestones','POST'|'PATCH'|'DELETE', ...) }` — one call per ticked/unticked milestone type.
- **Mechanism:** Extra sequential round trips proportional to attendees/milestones (a 4-person meeting on a deal = 1 DELETE + 4 POSTs ~ 7 s).
- **Who feels it:** Deal and project engagement saves with several attendees; any save with multiple milestones.

- **Fix:** engagement_people: `await api('engagement_people','POST', people.map(p => ({engagement_id: engId, person_id: +p.person_id})), '')` — PostgREST accepts a JSON array body as a bulk insert (one statement, one trigger batch). Milestones: one bulk upsert `POST engagement_milestones?on_conflict=engagement_id,milestone_type_id` with header `Prefer: return=representation,resolution=merge-duplicates` (the comment at 25104 confirms the unique (engagement_id, milestone_type_id) key), plus one `DELETE engagement_milestones?id=in.(...)` for unticked rows. api() currently hard-codes Prefer (2051); add an optional `headers` argument (`api(table, method, body, params, extraHeaders)`) — sb.js already forwards the browser's Prefer header verbatim (`'Prefer': event.headers['prefer'] || ''`).

### LI-5 — Opening an engagement from Attention / Dashboard / Internal Activity takes up to 8 sequential hops; one embedded select returns record, parent and people

**Impact medium · effort S · query shape · reviewer (confidence 0.75)**

- **Where:** index.html:25514-25549 (openEngagement), 25741-25830 (_liLoadPeople deal/project branches)
- **Evidence:** 25516 `eng = (await apiGet('engagements', \`id=eq.${engId}&select=*\`))[0]`; then 25521/25524/25528 one of `apiGet('leads', id=eq...&select=id,target_org_name,description,site_id,site_name,sites(name))`, `apiGet('deals', id=eq&select=id,name)`, `apiGet('work_projects', ...)`; 25541 `await loadLiLookups()`; 25545 `await _liLoadPeople()` which for a deal does `apiGet('engagement_people', engagement_id=eq...)` (25782) -> `apiGet('people', id=in...)` (25750) -> `Promise.all(deals org_id, deal_collaborators)` (25813-25816) -> `apiGet('person_organisation_roles', org_id=eq...)` (25820) -> `apiGet('people', id=in...)` (25826).
- **Mechanism:** Sequential round trips (depth ~8, ~11 s) for a modal that could be filled from one row.
- **Who feels it:** Every row click on Outstanding Actions (dashboard card and Attention page) and on the Internal Activity table.

- **Fix:**

```sql
First call becomes:

engagements?id=eq.<id>&select=*,leads(id,target_org_name,description,site_id,site_name,sites(name),contacts),deals(id,name,org_id,deal_collaborators(person_id),organisations(id,person_organisation_roles(person_id))),work_projects(id,name),engagement_people(person_id,people(id,first_name,last_name))

Parent label, already-linked people (with names) and the deal candidate pool ids all arrive in one hop; run `loadLiLookups()` in the same Promise.all. Resolve the remaining pool names with one `people?id=in.(...)` (or embed `people(first_name,last_name)` under deal_collaborators / person_organisation_roles). Depth 8 -> 2.
```

### MIL-2 — After one milestone decision the app reloads the whole history page / register instead of patching the row in memory

**Impact medium · effort S · other · reviewer (confidence 0.8)**

- **Where:** index.html:24045-24053 (_milAfterChange), called from decideMilestone 24130 and withdrawMilestone 24140
- **Evidence:** 24047 `if (window._engHist && document.getElementById('eh-results')) await _engHistReload();` (full EH-1 trace); 24048-24051 re-runs `_milForEngagements` for the lead form; 24052 `if (document.getElementById('mil-page')) await renderMilestonesPage();` (full MIL-1 trace).
- **Mechanism:** Redundant sequential round trips: approving a milestone is one PATCH (24124), but the refresh costs 7-18 further hops to re-derive a status the client already knows.
- **Who feels it:** A reviewer working the Pending queue waits ~10-25 s after every Approve/Decline; the dashboard 'Approvals Outstanding' click-through lands here.

- **Fix:** Make _milAfterChange(id, patch|null) mutate in place and re-run the pure renderers: for the history page update `st.milestones[engId]` (replace/remove the row) then `_engHistApply()`; for the register update `window._milPageItems` (status, decidedBy) then `_milPageApply()`; for the lead form update `window._leadMilMap` then `renderLeadInteractions()`. decideMilestone already receives the PATCHed row if it requests `select=*` (api() sends Prefer: return=representation for PATCH, 2051). Keep a full reload only as the fallback when the row is not found locally.

### RPT-2 — Reports refetch everything when only the client-side scope or interval changes

**Impact medium · effort S · other · reviewer (confidence 0.85)**

- **Where:** index.html:24406-24407 (_rptSet/_rptSetDate), 24497-24501 (inScope), 24439-24442 (periods)
- **Evidence:** 24406: `function _rptSet(k, v) { _rptState[k] = v; if (k === 'detail') { _rptPaint(); } else { _rptRun(); } }` — 'scope' and 'interval' both trigger _rptRun, which re-runs the full _rptActivity fetch (24411-24431). Scope is applied purely in memory: 24497 `const inScope = (parent, createdBy) => { if (st.scope === 'all') return true; ...}`. Interval only changes `_rptPeriods` bucketing (24439); the fetch window is st.from..st.to (winFrom only differs when >60 buckets are dropped, 24441).
- **Mechanism:** Redundant sequential round trips: each Mine/Team/All or Week/Month/Quarter/FY click repeats the entire ~20-hop fetch of RPT-1 to re-bucket data already in memory.
- **Who feels it:** Every toggle on the Reports page costs the full report load (~10-28 s) instead of an instant re-paint.

- **Fix:** Split _rptActivity into fetch (keyed by from/to) and compute. Keep `window._rptRaw = { from, to, engs, futureRows, stageEvents }`; in _rptRun, only refetch when st.from/st.to differ from _rptRaw (or the 60-bucket cut changes winFrom); otherwise recompute totals/matrices from _rptRaw and _rptPaint(). Scope and interval become in-memory operations (like the 'detail' tabs already are).

### EH-3 — Engagement History rebuilds the entire grouped list on every search keystroke and re-concatenates a search string per row each time

**Impact low · effort S · dom render · reviewer (confidence 0.7)**

- **Where:** index.html:16659 (search input), 16680-16703 (_engHistFilteredRows), 16808-16880 (_engHistApply)
- **Evidence:** 16659 `<input type="text" id="eh-search" ... oninput="_engHistApply()">`; 16700 `if (q) rows = rows.filter(r => (r.clientName + ' ' + r.parentLabel + ' ' + r.persons.join(' ') + ' ' + (r.e.notes || '') + ' ' + (r.e.engagement_type || '') + ' ' + (r.e.next_action || '')).toLowerCase().includes(q));` then _engHistApply regroups, sorts and sets `out.innerHTML` for all sections (16879).
- **Mechanism:** DOM rebuild + O(rows) string building per keystroke: with 1000 rows and notes up to 240 chars rendered, each keystroke re-serialises ~1000 row templates and re-parses several hundred KB of HTML; typing a 6-letter word does it 6 times.
- **Who feels it:** Noticeable input lag while typing in the search box on large windows; not a network cost.

- **Fix:** Precompute `r.searchText = (...).toLowerCase()` once in _engHistLoad's row mapper (16591-16609); debounce the oninput handler (~150 ms) for the search box only; keep other controls immediate.

### IDX-1 — engagements is indexed only on lead_id; the slice's predicates hit deal_id, engagement_date, open next actions, org_id, work_project_id and engagement_people.engagement_id unindexed

**Impact low · effort S · db index · reviewer (confidence 0.6)**

- **Where:** sql/unify_engagements.sql:48 (only index: idx_engagements_lead), sql/schema.sql:404-470 and 1797-1801 (engagement_people and engagements: PK only); predicates at index.html:16540, 12376, 14290, 26437, 16549, 24444, 25976, 26196
- **Evidence:** index_inventory.txt lists for engagements only `idx_engagements_lead ON public.engagements (lead_id)`; nothing on engagement_people. Predicates used by this slice (predicates.txt): `deal_id=not.is.null`/`deal_id=eq`/`deal_id=in`, `engagement_date=gte/lte/gt/eq` with `ORDER engagement_date.desc,id.desc` (x4) and `engagement_date.desc,created_at.desc` (x2), `next_action_done=eq.false&next_action_date=not.is.null` (x5), `org_id=in`/`org_id=not.is.null`, `work_project_id=not.is.null`, `engagement_people.engagement_id=in` (x2, up to 1000 ids), `engagement_milestones.engagement_id=in` (x2) and `status=eq` (x2). Postgres does not auto-index FK columns.
- **Mechanism:** Every one of these reads is a sequential scan of engagements (or engagement_people). At today's volume (thousands of rows) each scan is milliseconds and is masked by the ~1.4 s proxy hop; it becomes visible once engagements reaches tens of thousands, and the ordered date-window query then also needs a sort.
- **Who feels it:** All pages in the slice, increasingly as engagement volume grows; low today, protective for the modular rebuild.

- **Fix:**

```sql
create index if not exists engagements_deal_idx on engagements (deal_id);
create index if not exists engagements_date_idx on engagements (engagement_date desc, id desc);
create index if not exists engagements_open_action_idx on engagements (next_action_date) where next_action_done = false and next_action_date is not null;
create index if not exists engagements_org_idx on engagements (org_id) where org_id is not null;
create index if not exists engagements_project_date_idx on engagements (engagement_date desc) where work_project_id is not null;
create index if not exists engagements_stream_idx on engagements (stream_id);
create index if not exists engagement_people_eng_idx on engagement_people (engagement_id);
create index if not exists engagement_milestones_eng_idx on engagement_milestones (engagement_id);
create index if not exists engagement_milestones_status_idx on engagement_milestones (status) where status = 'pending';

(The lead-side `lead_id=eq` reads and refresh_lead_next_action are already covered by idx_engagements_lead; lead_stage_events already has (to_status, at).) Assumption: engagement_milestones DDL is not in the repo (referenced migration sql/add_engagement_milestones.sql is missing), so verify it does not already carry these.
```

### MIL-3 — openMilestoneReview refetches the milestone row that every caller already holds in memory

**Impact low · effort S · other · reviewer (confidence 0.75)**

- **Where:** index.html:24060-24063
- **Evidence:** 24063 `try { m = (await apiGet('engagement_milestones', 'id=eq.' + id + '&select=*'))[0]; } catch (e) {}` — callers pass only the id from _milBadgeHtml (24035, badge onclick) and the register rows (24911, 24940), although st.milestones / window._milPageItems / window._leadMilMap contain the row.
- **Mechanism:** One extra proxied round trip (~1.4 s, up to 12 s with retries) before the modal can render.
- **Who feels it:** Every click on a milestone star badge or register row.

- **Fix:** Look the row up locally first: `let m = _milFindLocal(id)` scanning window._milPageItems (i.m), window._engHist?.milestones and window._leadMilMap; only fall back to the GET when not found. The subsequent PATCH/DELETE already refreshes state.

### PAY-1 — History and Internal Activity pull select=* engagements through a body-buffering proxy; narrow the column list

**Impact low · effort S · payload · reviewer (confidence 0.65)**

- **Where:** index.html:16540 (_engHistLoad), 26437-26438 (_intActLoad), 25127-25128 (loadLeadInteractions), netlify/functions/sb.js response handling (`let d = ''; res.on('data', c => d += c)`)
- **Evidence:** 16540 `select=*&order=engagement_date.desc,id.desc&limit=1000`; the renderer uses only engagement_date, engagement_type, notes (sliced to 240 chars, 16836), next_action, next_action_date, next_action_done, duration_minutes, work_mode, stream_id, stream_label, created_by, deal_id, lead_id (16809-16880). select=* also returns action_details, next_action_completion_note, next_action_completed_at, contacts (jsonb array of names), related_interaction_id, activity_type_id, next_action_id, org_id, work_project_id. The Netlify function concatenates the whole upstream body into a string before responding, so payload size adds directly to latency.
- **Mechanism:** Over-fetch bytes: at 1000 rows with free-text notes/action_details/completion notes and a contacts array, the body is plausibly 1-2 MB per load, serialised by PostgREST, buffered by the function, parsed by the browser.
- **Who feels it:** Engagement History (each load/category change), Internal Activity, lead form interactions list. Magnitude depends on how much free text users write (assumption: a few hundred bytes per row).

- **Fix:** Replace `select=*` with the explicit column list the renderer reads (see EH-1's query). For notes, if only a preview is shown, expose a trimmed column via a view or a generated column (`left(notes, 260)`) and fetch the full text only when an engagement is opened (openEngagement already does `select=*` for one row).

### RPT-3 — Report bucketing formats two Dates per row per period inside findIndex

**Impact low · effort S · client cpu · reviewer (confidence 0.6)**

- **Where:** index.html:24503 (idx), used at 24513, 24537, 24565
- **Evidence:** 24503 `const idx = iso => periods.findIndex(p => iso >= _rptIso(p.s) && iso < _rptIso(p.e));` — `_rptIso` (24299) builds a padded string from a Date; called for every engagement, milestone and stage event, up to 60 periods each.
- **Mechanism:** Client CPU: ~rows x periods x 2 Date-to-string formats (e.g. 2000 rows x 60 periods = 240k formats, tens to a few hundred ms on a laptop) on every run; trivially avoidable.
- **Who feels it:** Small extra pause after data arrives on the Reports page; scales with 'All time' + 'Week'.

- **Fix:** Precompute `periods.forEach(p => { p.sIso = _rptIso(p.s); p.eIso = _rptIso(p.e); })` once and compare strings; or since periods are contiguous and sorted, binary-search the start ISO array.

### TRG-1 — Per-row engagement triggers re-run a lead refresh for every row in a bulk update; make it once per affected lead

**Impact low · effort M · db trigger · reviewer (confidence 0.65)**

- **Where:** sql/unify_engagements.sql:78-96 (trg_engagements_refresh_next_action), sql/add_audit_log.sql:43-49 & 82 (audit_row_change on engagements and leads), sql/add_lead_stage_events.sql:110-114
- **Evidence:** `CREATE TRIGGER engagements_refresh_next_action AFTER INSERT OR DELETE OR UPDATE ON public.engagements FOR EACH ROW EXECUTE FUNCTION public.trg_engagements_refresh_next_action();` — the function does `SELECT ... FROM engagements WHERE lead_id = p_lead_id ... ORDER BY next_action_date ASC, id DESC LIMIT 1` and `UPDATE public.leads SET ... updated_at = now() WHERE id = p_lead_id` for every row. The leads UPDATE then fires `audit_leads` (jsonb_each diff of the whole row) and `leads_log_stage_event`. A bulk shift (EH-2) of N engagements on the same lead performs N SELECT+UPDATE pairs and N audit_leads diffs where 1 would do; every ordinary save (LI-2) fires it 3 times for the 3 writes on the same row.
- **Mechanism:** Trigger work multiplied by row count and by write count per logical operation; each UPDATE leads also rewrites the lead row (bloat) and appends an audit row even when only updated_at changed on the lead (the audit function skips a diff that is ONLY updated_at, but next_action fields often bounce).
- **Who feels it:** Bulk shift and multi-write saves; grows with the number of engagements per lead. Secondary to the round-trip findings at current volume.

- **Fix:**

```sql
Convert to a statement-level trigger with transition tables so each affected lead is refreshed once per statement:

create or replace function trg_engagements_refresh_next_action_stmt() returns trigger language plpgsql as $$
begin
  perform refresh_lead_next_action(lead_id) from (
    select lead_id from new_rows where lead_id is not null
    union select lead_id from old_rows where lead_id is not null) d;
  return null; end $$;
drop trigger engagements_refresh_next_action on engagements;
create trigger engagements_refresh_next_action_ins after insert on engagements referencing new table as new_rows for each statement execute function ...;
(create the UPDATE variant with `referencing old table as old_rows new table as new_rows`, and the DELETE variant with old_rows only; use empty CTEs where a transition table is absent.)

Also make refresh_lead_next_action skip the UPDATE when nothing changes: `... WHERE id = p_lead_id AND (next_action IS DISTINCT FROM v_next_action OR next_action_date IS DISTINCT FROM v_next_action_date)` — avoids the leads row rewrite and the audit/stage-event trigger invocations on no-op refreshes.
```


## Generic tables, clients/contacts, settings and admin pages

### G1 — Ownership scope is a second sequential hop of three whole-table pulls on every Contacts visit and every scoped Clients visit

**Impact high · effort M · db view or rpc · spot-checked (confidence 0.9)**

- **Where:** /home/user/Focus/index.html:3468-3489 (_ensureOwnershipScope), 3574-3580 (awaited after the primary Promise.all at 3559-3563)
- **Evidence:** 3559: const [primaryRows] = await Promise.all([ apiGetAll(cfg.table, ...) ...]);  then 3577: } else if (page === 'contacts') { const s = await _ensureOwnershipScope(); ... }  and 3472-3476: await Promise.all([ apiGet('leads','select=owner_id,target_org_id,contacts'), apiGet('deals','select=id,owner_id,org_id'), apiGet('deal_contacts','select=deal_id,person_id') ]). The contacts branch runs for view_all users too (3579 filters by allContactPersons). The comment at 3468-3471 says 'Computed per page-load'.
- **Mechanism:** Extra sequential proxied round trip (~1.4 s per the loadTable comment) after the primary fetch has already completed; the three queries do not depend on the primary result. Each is a full-table scan pull (leads incl. the jsonb contacts column, all deals, all deal_contacts) that is discarded after computing a Set of ids client-side.
- **Who feels it:** Every user opening Contacts (always) and every non-view_all user opening Clients: page shows 'Loading...' for two full hops instead of one. Also re-paid after every save/delete on those pages because saveRecord/deleteRecord call loadTable again (4649, 4707).

- **Fix:** Quick (S): decide needScope = (page==='clients' && !can('view_all_clients')) || page==='contacts' before the fetch and put _ensureOwnershipScope() inside the same Promise.all as apiGetAll(cfg.table,...), then apply the filter after; depth 2 -> 1 with no behaviour change. Proper (M): move the join to Postgres so the page makes ONE narrow call.  create or replace view v_contact_scope as select l.owner_id, l.target_org_id as org_id, (c->>'person_id')::bigint as person_id from leads l cross join lateral jsonb_array_elements(coalesce(l.contacts,'[]'::jsonb)) c union all select d.owner_id, d.org_id, dc.person_id from deals d join deal_contacts dc on dc.deal_id=d.id union all select d.owner_id, d.org_id, null from deals d;  create or replace function contacts_in_scope(p_me bigint, p_all boolean) returns setof people language sql stable as $$ select p.* from people p where p.id in (select person_id from v_contact_scope where person_id is not null and (p_all or owner_id=p_me)) order by p.id $$;  (same shape for clients_in_scope returning organisations). Client: apiGet('rpc/contacts_in_scope', `p_me=${me}&p_all=${can('view_all_contacts')}`) — GET on a stable function works through the existing api() URL builder (2039) and sb.js path rewrite. This also removes the silent 1000-row cap on the leads/deals scope pulls.

### G2 — Client contacts modal and page each do links -> people as two sequential hops (four hops modal-to-page); one embedded PostgREST query does it in one

**Impact medium · effort S · query shape · reviewer (confidence 0.9)**

- **Where:** /home/user/Focus/index.html:3926-3941 (showClientContacts), 3997-4005 (renderClientContactsPage)
- **Evidence:** 3926: const links = await apiGet('person_organisation_roles', `org_id=eq.${orgId}&end_date=is.null&select=person_id,job_title,is_primary&order=is_primary.desc`); ... 3941: const people = await apiGet('people', `id=in.(${personIds.join(',')})&select=id,first_name,last_name,title,email,phone`);  The page (3997/4005) repeats the identical pair after 'Manage Contacts' (openClientContactsPage -> showPage -> renderClientContactsPage).
- **Mechanism:** Second round trip exists only to resolve person_id -> people columns; the FK person_organisation_roles_person_id_fkey (schema.sql:2652) already lets PostgREST embed people in the first query. The modal->page hand-off discards the already-fetched rows and fetches both again.
- **Who feels it:** Every time anyone opens a client's contacts (Clients page 'Contacts' button, then 'Manage Contacts'): 2 hops for the popup, 2 more for the page; also 2 hops after every add/edit/remove of a contact because those call renderClientContactsPage (4145, 4225, 4247).

- **Fix:** Replace both pairs with one resource-embedding GET: apiGet('person_organisation_roles', `org_id=eq.${orgId}&end_date=is.null&select=id,person_id,job_title,is_primary,people(id,first_name,last_name,title,email,phone)&order=is_primary.desc`) and read l.people.first_name etc. Then make openClientContactsPage(orgId, rows) pass the modal's rows into renderClientContactsPage so the page renders with zero new calls (only re-fetch after a write). Add the supporting index: create index if not exists por_org_open_idx on person_organisation_roles (org_id) where end_date is null;

### G3 — Per-row Group chip and per-cell lookup .find() make list rendering O(rows x lookup) — O(clients x orgs x parented-orgs) on Clients/Organisations — re-run on every sort or filter click

**Impact medium · effort S · client cpu · reviewer (confidence 0.75)**

- **Where:** /home/user/Focus/index.html:3598-3620 (helperCols.get and rowRenderer), 2819 and 2759 (Group column render), 14259-14268 (_groupChipHtml), 14248-14252 (_familyOrgIds), 14211-14221 (_ultimateParentOrg)
- **Evidence:** 3602/3617: const found = lookup.find(r => +r.id === +val);  2819: { key: 'id', label: 'Group', render: v => _groupChipHtml('o' + (+v)) }  14264: const n = _familyOrgIds(id).length;  14251: O.forEach(o => { if (+_ultimateParentOrg(o, O).id === +parentId) ids.add(+o.id); });  14216: const p = (orgs || []).find(x => +x.id === +cur.parent_org_id);  _renderTable (2306-2373) rebuilds the whole tbody via rowRenderer on every _cycleSort/_toggleValue.
- **Mechanism:** Client CPU. For every client row, _groupChipHtml does one .find over all organisations, then _familyOrgIds walks ALL organisations and for each one with a parent_org_id does a .find per hop. Cost per render ~= C x (O + P x O x depth) where C = client rows, O = organisations, P = organisations that have a parent. The Organisations admin page is O x (O + P x O). Lookup columns (Affiliations page: person_id and org_id over people/organisations; Sites page: organisation_id; System Users; Regions; Stages) add rows x lookup per pass, and sorting calls col.get twice per comparison (2320-2333) i.e. n log n x lookup.
- **Who feels it:** Clients and Organisations pages (initial paint and every header sort / filter checkbox) and the Affiliations/Sites admin lists. Data-volume dependent: at 1,500 clients, 3,000 organisations and ~50 parented orgs that is ~230M loop steps per render (hundreds of ms to seconds of frozen UI); at a few hundred orgs it is invisible.

- **Fix:** Build indexes once per render instead of per cell: in loadTable, before makeSortableFilterableTable, const idx = {}; for (const col of cfg.columns) if (col.lookup) idx[col.lookup] = new Map((allData[col.lookup]||[]).map(r => [+r.id, r])); and use idx[col.lookup].get(+val) in both helperCols.get and rowRenderer. For the chip: compute family sizes once per organisations snapshot — const top = new Map(); const byId = new Map(O.map(o=>[+o.id,o])); for each org walk parent_org_id via byId (memoising top per id), then const familySize = new Map() counting tops — and have _groupChipHtml read familySize.get(id). Invalidate the memo whenever allData['organisations'] is reassigned (it is written from ~30 places; key the memo on the array identity). Also store col.get results on the row for the sort comparator (compute once per row per sort).

### G4 — Every generic-page save or delete re-downloads the whole table (plus ownership scope) although the write already returned the row

**Impact medium · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:4634-4649 (saveRecord), 4700-4707 (deleteRecord); apiPatch/apiPost at 2113-2114
- **Evidence:** 4634: saved = await apiPatch(cfg.table, editingId, body); ... 4648: allData[cfg.table] = null; // clear cache  4649: await loadTable(currentPage);  apiPatch already requests `id=eq.${id}&select=*` with Prefer: return=representation (2051), so `saved[0]` is the full updated row. loadTable then re-runs apiGetAll(cfg.table,'select=*') and, for clients/contacts, _ensureOwnershipScope.
- **Mechanism:** 1-2 extra sequential proxied round trips (3-5 with paging and scope) and a full re-parse/re-render of the list for a single-row change.
- **Who feels it:** Every Save and every Delete on all ~25 generic admin/lookup pages and on Clients/Contacts/Organisations/Sites/People; each costs a full page reload (~1.4-3 s) after the write's own ~1.4 s.

- **Fix:** Splice instead of reload: after a PATCH replace the row in currentData (const row = saved[0]; const i = currentData.findIndex(r => +r.id === +row.id); if (i>=0) currentData[i] = row;), after a POST push it, after DELETE filter it out; keep allData[cfg.table] in step the same way when !cfg.filter; then call _renderTable('page-'+currentPage) (2306) which re-applies the user's current sort/filter. Keep the full loadTable only for the system_users page (login_role side-table) if you prefer not to touch it. Result: 0 extra hops per save/delete.

### G5 — Add/Edit client contact chains 5-6 sequential hops, including a whole-table people refetch and a re-read of a row the modal already holds

**Impact medium · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:4116-4151 (saveAddContactToClient), 4139-4166 (openEditClientContact), 4225-4245 (saveEditClientContact)
- **Evidence:** 4133: const existing = await apiGet('person_organisation_roles', `org_id=eq.${_contactsClientId}&person_id=eq.${personId}&end_date=is.null&select=id`);  4144: if (!allData['people']) allData['people'] = await apiGet('people', 'select=*');  (the POST at 4123 nulled it via _lkInvalidate at 2094, so this always runs)  4238: const cur = (await apiGet('person_organisation_roles', `id=eq.${affiliationId}&select=person_id,org_id,job_title,role_type,is_primary`))[0] || {};  — the same row was fetched at 4141 when the modal opened. 4164: history fetched sequentially after the Promise.all at 4139.
- **Mechanism:** Sequential round trips that carry no new information: the dup pre-check duplicates a constraint the DB can enforce; the people select=* refetch downloads every person to add one; the affiliation is re-read on save; the edit modal's history query waits on a query whose only needed output (org_id) is already known from the affiliation row on the page.
- **Who feels it:** Every contact added (6 hops ~8 s) or edited (2 hops to open + 5-6 to save) from the Client Contacts page — the main data-entry path for sales users.

- **Fix:** (a) Drop the pre-check and let the DB refuse duplicates: create unique index if not exists por_open_unique on person_organisation_roles (org_id, person_id) where end_date is null; catch a 409/23505 on the POST and show the 'already a contact' message (saveHomeMember at 28016-28040 already uses this pattern). (b) After POST people, push personResult[0] into allData['people'] (re-hydrate the array if null) instead of refetching the table. (c) Keep the affiliation row from openEditClientContact in module state (or pass it via the Save button's closure) and reuse it in saveEditClientContact — removes the 4238 GET. (d) In openEditClientContact fetch everything in one query: apiGet('person_organisation_roles', `person_id=eq.${personId}&select=id,org_id,job_title,role_type,is_primary,start_date,end_date,people(id,first_name,last_name,title,email,phone)&order=end_date.desc.nullsfirst`) then pick id===affiliationId for the current row and rows with the same org_id and end_date for history — depth 2 -> 1. With G2, the re-render after save is one hop, so add becomes 3 hops and edit-save 2-3.

### G6 — Clients/Organisations lists fetch select=* on a ~45-column table (notes, two address blocks, compliance fields) to show 5-7 columns

**Impact medium · effort M · payload · reviewer (confidence 0.7)**

- **Where:** /home/user/Focus/index.html:3559-3560 (loadTable primary fetch), 2809-2825 (PAGES.clients columns), 2536-2583 (ORG_DETAIL_FIELDS); sql/schema.sql:774-785 + sql/add_org_detail_fields.sql (28 ADD COLUMN) + sql/add_client_fields.sql
- **Evidence:** 3560: apiGetAll(cfg.table, 'select=*&order=id.asc' + (cfg.filter ? '&' + cfg.filter : '')),   // paged: admin lists must show every row  — Clients shows name, account_no, legal_name, client_status, id only. renderTabbedForm(row) at 3712 is the only consumer of the other ~40 fields, and it reads them from currentData (3705).
- **Mechanism:** Over-fetch bytes: every organisation row carries notes/text/address/compliance columns (~1-2 KB JSON each) versus ~150 B for the displayed columns; the whole body is buffered as a string inside the Netlify function (sb.js: let d=''; d+=c) and JSON.parsed in the browser. Netlify synchronous functions cap the response at 6 MB, so a 1000-row page of wide rows is also a hard-failure risk as the table grows.
- **Who feels it:** Clients page for everyone on every visit and after every save (G4); Organisations admin page. Size-dependent: at 2,000 client rows that is roughly 2-4 MB versus ~300 KB.

- **Fix:** For the clients page (cfg.filter is set, so loadTable never writes these rows into allData — 3567) request only what the list renders: add cfg.select = 'id,name,account_no,legal_name,client_status' and use `select=${cfg.select||'*'}` at 3560; on Edit fetch the full row on demand: openEditModal -> const row = (await apiGet('organisations', `id=eq.${id}&select=*`))[0]; renderTabbedForm(row). Do the same for sites (select=id,name,organisation_id,province,is_primary,active). For the Organisations admin page (no filter — rows are cached into allData['organisations'] for the whole app) either keep select=* or list every column other code reads from that cache (id,name,legal_name,website,client_status,home_organisation,allows_system_users,is_client,active,parent_org_id,collective_since,group_touch_soothes,sector_id,region_id,account_no) — do not narrow it blindly.

### G7 — Research Study / Marketing Campaign modals re-download all people and all organisations (select=*, paged) on every open and render them as thousands of <option>s

**Impact medium · effort M · payload · reviewer (confidence 0.7)**

- **Where:** /home/user/Focus/index.html:26993-26999 (renderSalesCampaignModal fetch), 26632-26639 (renderResearchCampaignModal fetch), 27078, 27097, 27109 (option lists)
- **Evidence:** 26995: apiGetAll('people', 'select=*&order=first_name.asc'),  26996: apiGetAll('organisations', 'select=*&order=name.asc'),  27078: ${orgs.map(o => `<option value="${o.id}">${esc(o.name)}</option>`).join('')}  (repeated at 27109 for the new-person org picker) 27097: ${people.map(p => `<option ...`)}. The comment at 26990-26993 says these are fetched FRESH deliberately for staleness.
- **Mechanism:** Full-table over-fetch of the two widest lookup tables on each modal open (apiGetAll pages sequentially per 1000 rows, 2127-2130), then DOM construction of 2 x organisations + people <option> nodes inside modal-root innerHTML.
- **Who feels it:** Outreach users opening/editing a Research Study or Marketing Campaign: a multi-second modal open, plus a sluggish native select with thousands of entries. Volume-dependent (people/organisations in the low thousands assumed).

- **Fix:** Keep the freshness but shrink the request and the DOM: fetch only the picker columns and do NOT write them over allData (other pages expect select=* rows there): const people = await apiGetAll('people','select=id,first_name,last_name&order=first_name.asc'); const orgs = await apiGetAll('organisations','select=id,name,home_organisation&order=name.asc'); Replace the three giant <select>s with a text input + findSimilar/startsWith suggestion strip (the modal already has scCreateOrg/scCreatePerson match strips at 26860-26880 and 26910-26925), rendering only the chips that are picked. Optionally add a server-side search instead of any list download: GET organisations?name=ilike.*${q}*&select=id,name&limit=20 on keystroke (debounced) — zero upfront payload.

### G8 — apiGetAll pages sequentially past PostgREST's 1000-row cap — each extra page is another full round trip on the critical path

**Impact medium · effort S · proxy infra · reviewer (confidence 0.65)**

- **Where:** /home/user/Focus/index.html:2120-2131 (apiGetAll), used by loadTable 3560, preloadLookups 2193, audit/bug pages 13847/14031, campaign modals 26636/26995-26996
- **Evidence:** 2127: for (let offset = 0; ; offset += PAGE) { 2128: const page = await api(table, 'GET', null, `${tie}${tie ? '&' : ''}limit=${PAGE}&offset=${offset}`); ... 2130: if (page.length < PAGE) return out; }  The comment at 2116-2119 records that the 1000-row cap already bit the pipeline's month fetch, i.e. at least one table is past 1000 rows.
- **Mechanism:** Sequential round trips: a 2,500-row people/organisations/leads table costs 3 hops (~4 s) wherever apiGetAll is used, before the page can render. The api() helper discards response headers, so the caller cannot learn the total and fan out.
- **Who feels it:** Contacts, People, Organisations, Clients pages and the login preload for every table over 1000 rows; campaign modals; audit/bug people fetch. Data-volume dependent — only bites on tables > 1000 rows, which the code comment confirms exist.

- **Fix:** Infra (S): raise Supabase's API 'Max rows' (Project Settings -> API -> Max rows, i.e. PostgREST db-max-rows) from 1000 to e.g. 5000 so ordinary tables arrive in one page; pair with narrower selects (G6/G7) so single responses stay well under Netlify's 6 MB function limit. Code alternative (S): have api() return {rows, headers} for a new apiGetPage that sends Prefer: count=planned (or count=exact) on page 1, read Content-Range's total, then Promise.all the remaining offsets — depth becomes 2 regardless of row count. sb.js already forwards the Prefer header (line 'Prefer': event.headers['prefer'] || '').

### G10 — Audit Log page pulls full row_data/changes jsonb for every one of the 200 rows per page although the list only shows a label and a collapsed field count

**Impact low · effort M · db view or rpc · reviewer (confidence 0.7)**

- **Where:** /home/user/Focus/index.html:13861-13871 (_auditReload query), 13906-13927 (_auditRowHtml), 13898-13903 (_auditRowLabel); sql/add_audit_log.sql:15-27
- **Evidence:** 13861: const parts = ['select=*', 'order=at.desc,id.desc', `limit=${AUDIT_PAGE_SIZE}`, `offset=${_auditOffset}`];  13913-13916: for INSERT/DELETE the row_data is only used for kv.length and a <details> that is closed by default; _auditRowLabel reads d.name / first_name+last_name / description / notes. row_data is the full to_jsonb(new) snapshot of leads/deals/organisations rows (add_audit_log.sql:52-56).
- **Mechanism:** Over-fetch bytes: 200 x (1-3 KB row snapshot) per page, plus JSON.parse and innerHTML of every field for the collapsed details. Filter combinations op=eq.* have no index; table_name filters use audit_log_row_idx (table_name,row_id) which does not help an ORDER BY at desc, forcing a sort of every matching row before LIMIT 200.
- **Who feels it:** Admins on the Audit Log page: each page and each 'Load 200 more' is a few hundred KB; slow as the log grows (every write on 17 tables appends a row). Admin-only, low frequency.

- **Fix:** List view without the blobs: create view v_audit_log_list as select id, at, actor_id, real_actor_id, table_name, row_id, op, changes, coalesce(row_data->>'name', nullif(concat_ws(' ', row_data->>'first_name', row_data->>'last_name'),''), row_data->>'description', row_data->>'notes') as row_label, (select count(*) from jsonb_object_keys(coalesce(row_data,'{}'::jsonb))) as field_count from audit_log;  Query it with select=* and lazy-load one row's snapshot when the <details> is opened: apiGet('audit_log', `id=eq.${id}&select=row_data`). Add create index if not exists audit_log_table_at_idx on audit_log (table_name, at desc) for the filtered views and audit_log_op_at_idx on audit_log (op, at desc) if the Action filter is used.

### G11 — No indexes on person_organisation_roles(org_id / person_id) or deal_contacts(deal_id) — the columns the client filters on 27+ times

**Impact low · effort S · db index · reviewer (confidence 0.6)**

- **Where:** sql/schema.sql:942-950 (person_organisation_roles has only the PK); scratchpad/index_inventory.txt (no index on these columns); client predicates: person_organisation_roles org_id=eq x17, person_id=eq x10, end_date=is x8 (predicates.txt); index.html:3926, 3997, 4133, 4164, 4238, 4301, 16361, 21736, 25822, 28116
- **Evidence:** schema.sql:942: CREATE TABLE public.person_organisation_roles ( id bigint NOT NULL, person_id bigint, org_id bigint, role_type text NOT NULL, is_primary boolean DEFAULT false, start_date date, end_date date );  grep of sql/ for an index on person_organisation_roles returns nothing; Postgres does not index FK columns automatically. deal_contacts is not defined anywhere in sql/ (live-only table; only referenced by add_audit_log.sql:77), so its indexes cannot be verified.
- **Mechanism:** Sequential scan per query on every org_id=/person_id= lookup; also the ON DELETE CASCADE from people/organisations (schema.sql:2644-2652) must scan the table on each delete. Today the tables are small enough that this is milliseconds hidden inside the ~1.4 s hop — this is not the cause of the felt slowness, it is insurance that stays cheap as contacts grow.
- **Who feels it:** Every contact popup/page, person profile, add/edit contact, home-org member check, lead/deal contact pickers. Currently negligible; grows linearly with affiliations.

- **Fix:** create index if not exists por_org_open_idx on person_organisation_roles (org_id) where end_date is null; create index if not exists por_person_idx on person_organisation_roles (person_id); create index if not exists deal_contacts_deal_idx on deal_contacts (deal_id); create index if not exists deal_contacts_person_idx on deal_contacts (person_id); create index if not exists deals_owner_idx on deals (owner_id); create index if not exists deals_org_idx on deals (org_id); (the last two back G1's scope view). Combine with G5's partial unique index which doubles as the (org_id,person_id) lookup index.

### G12 — Org-merge card: preview is 10 count queries and the merge is 12+ sequential writes from the browser; both belong in one transactional RPC

**Impact low · effort M · db view or rpc · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/index.html:27452-27470 (previewOrgMerge), 27472-27512 (runOrgMerge), 27407/27414 (two full organisation <select>s)
- **Evidence:** 27461: const counts = await Promise.all(ORG_MERGE_REFS.map(async ([t, c, label]) => [label, (await apiGet(t, `${c}=eq.${dupId}&select=id`)).length]));  27463: counts.push(['research-study participations', (await apiGet(...)).length]);  27494: for (const [t, c] of ORG_MERGE_REFS) { await api(t, 'PATCH', { [c]: keepId }, `${c}=eq.${dupId}`); }  followed by DELETE organisations. The comment at 27506-27508 admits a mid-way failure leaves a half-merged state.
- **Mechanism:** Preview: 9 parallel + 1 sequential round trips that download every referencing row id just to count it. Merge: 2 GETs + N junction writes + 9 PATCHes + 1 DELETE strictly sequential (~15+ hops, 20-30 s), each firing the audit trigger per repointed row; no atomicity. Pickers render 2 x N organisation options.
- **Who feels it:** Admins only, rare (deduplicating a capture-born Prospect). Slow and non-atomic rather than a daily pain.

- **Fix:** create or replace function merge_organisation(p_dup bigint, p_keep bigint) returns jsonb language plpgsql as $$ declare r jsonb := '{}'; begin  delete from sales_campaign_organisations s where s.organisation_id=p_dup and exists (select 1 from sales_campaign_organisations k where k.organisation_id=p_keep and k.sales_campaign_id=s.sales_campaign_id);  update sales_campaign_organisations set organisation_id=p_keep where organisation_id=p_dup;  update leads set target_org_id=p_keep where target_org_id=p_dup; update leads set source_org_id=p_keep where source_org_id=p_dup; update sites set organisation_id=p_keep where organisation_id=p_dup; update deals set org_id=p_keep where org_id=p_dup; update person_organisation_roles set org_id=p_keep where org_id=p_dup; update campaign_targets set organisation_id=p_keep where organisation_id=p_dup; update quote_sites set organisation_id=p_keep where organisation_id=p_dup; update work_projects set organisation_id=p_keep where organisation_id=p_dup; update organisations set parent_org_id=p_keep where parent_org_id=p_dup;  delete from organisations where id=p_dup; return r; end $$;  and a matching merge_organisation_preview(p_dup) returning the counts via count(*) per table. Client: api('rpc/merge_organisation','POST',{p_dup:dupId,p_keep:keepId},'') — one hop, all-or-nothing. Replace the two giant selects with a typed-name search over allData or GET organisations?name=ilike.*q*&select=id,name,client_status&limit=20.

### G9 — System Users page: loadEligiblePeople is three sequential hops (orgs -> affiliations -> people) inside the page's Promise.all, making the page 3 deep

**Impact low · effort S · query shape · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/index.html:28109-28125 (loadEligiblePeople), invoked from loadTable 3562 when a field has lookupTable 'eligible_people' (PAGES.system_users 2913)
- **Evidence:** 28112: const eligibleOrgs = await apiGet('organisations', 'allows_system_users=eq.true&select=id'); ... 28116: const affiliations = await apiGet('person_organisation_roles', 'org_id=in.(' + orgIds + ')&select=person_id'); ... 28120: const people = await apiGet('people', 'id=in.(' + personIds + ')&select=*');
- **Mechanism:** Three dependent round trips to express a two-join filter that PostgREST can evaluate server-side in one query via embedded !inner filters.
- **Who feels it:** Admins opening System Users (and it re-runs after every save/delete on that page via loadTable, G4).

- **Fix:** One call: apiGet('people', 'select=id,first_name,last_name,title,email,phone,initials,person_organisation_roles!inner(org_id,organisations!inner(id))&person_organisation_roles.organisations.allows_system_users=eq.true') then dedupe by id client-side (a person affiliated to two eligible orgs comes back once with two embedded rows). Or a tiny view: create view v_eligible_people as select distinct p.* from people p join person_organisation_roles r on r.person_id=p.id join organisations o on o.id=r.org_id where o.allows_system_users; and apiGet('v_eligible_people','select=*').


## Proposal / quote builder

### PB-01 — openQuote issues 12-16 strictly sequential GETs before the editor can paint

**Impact high · effort M · parallelise · spot-checked (confidence 0.95)**

- **Where:** index.html:5972-6019 (openQuote); called from the quote list row onclick (5959) and createNewQuote (5969)
- **Evidence:** Every fetch is `await apiGet(...)` on its own line with no Promise.all: 5974 quote_quotes, 5976 quote_posts, 5979-5982 four post-child tables, 6000-6001 grades/areas, 6004-6006 three allowance catalogs ('Always fresh' comment), 6008-6009 rules + members via apiGetAll/apiGet, 6011-6012 standard names. Steps 8-16 do not depend on steps 2-7 at all; steps 4-7 depend only on the post ids from step 3.
- **Mechanism:** Extra sequential round trips: 15 proxied Netlify->PostgREST trips in series (12 after the first open) for data that is either independent or reachable in one PostgREST resource-embedding call. The FK chain exists for embedding: quote_posts.quote_id -> quote_quotes, quote_post_shifts/quote_post_*_allowances/incentives.post_id -> quote_posts (all PK-prefixed on post_id, so the embedded joins are index lookups).
- **Who feels it:** Every sales user, every time a quote is opened from the Commercial tab or the sandbox, and immediately after '+ New Quote'. At the ~1.4 s/trip figure in the code this is 17-22 s of 'Loading'; at 300 ms it is still 4-5 s. This is the single largest wait in the slice.

- **Fix:** Option A (S, no DB change): two stages. Stage 1 = Promise.all([quote, posts, grades?, areas?, statAllow, discAllow, incentives, rules, ruleMembers, postNames?, headingNames?]); stage 2 = Promise.all of the four post-child GETs. Depth 16 -> 2. Option B (M): collapse stage 1+2 into one embedded read: `quote_quotes?id=eq.<id>&select=*,quote_posts(*,quote_post_shifts(*),quote_post_statutory_allowances(*),quote_post_discretionary_allowances(*),quote_post_discretionary_incentives(*))` (PostgREST resolves via the existing FKs; add `quote_posts.order=display_order,id`), run in the same Promise.all as the lookups -> depth 1, 9 calls. Option C (M, best): one RPC `pb_open_quote(p_quote_id bigint) returns jsonb` (SQL, STABLE) built with jsonb_build_object over sub-selects for quote, posts+children (jsonb_agg per post), grades, areas, the three catalogs, rules, rule_members, post_names, heading_names; client does `api('rpc/pb_open_quote','POST',{p_quote_id:id})` - the sb.js proxy already maps /sb/rpc/x to /rest/v1/rpc/x. Depth 1, one call, one payload. Drop the redundant quote header GET (5974): the row is already in the list from loadProposalBuilder, or comes back in the embed.

### PB-02 — Every edit in the quote editor waits for its PATCH and then rebuilds the whole editor with innerHTML, destroying focus and in-flight input

**Impact high · effort M · dom render · reviewer (confidence 0.85)**

- **Where:** index.html:6491-6499 (renderQuoteEditor override), called from 35 sites incl. pbUpdatePostField 6852, pbUpdateShiftCell 6880, pbStatAllowToggle 6228/6234/6239, pbSaveQuoteField (none, but pbUpdateShiftsPerDay 6584), pbToggleDetail 6172, pbTogglePostExpanded 6843, pbSwitchTab 5919
- **Evidence:** renderQuoteEditor = function(){ ... root.innerHTML = pbRenderDatalists() + renderQuoteEditorTopBar() + renderQuoteEditorTabBar() + '<div class="pb-editor-tab-content">' + renderQuoteEditorTabContent() + '</div>'; } (6491-6499). pbUpdatePostField: `await apiPatch('quote_posts', postId, {[field]: value}); loc.heading.posts[loc.index][field] = value; renderQuoteEditor();` (6850-6852) - the model update and the repaint are both gated on the network. renderPost (6142) builds a grade <select>, two pbShiftSummary calls and, when expanded, renderShiftTable (N x 4-8 groups x [10-option select + 2 inputs + 2 buttons]) plus pbAllowanceCols (three sorted pbCurrentByCode passes) for every post, on every call.
- **Mechanism:** DOM rebuild + network-gated render: (1) the on-screen state lags one round trip behind the user's action; (2) when the PATCH resolves ~1.4 s later the entire subtree is replaced, so the element the user has since focused (next post name, next shift cell, the grade select they are opening) is destroyed and any characters typed into it are discarded (the new DOM is rendered from the model, which never received them); (3) pure UI toggles (expand, detail, tab, heading collapse) also rebuild every post's shift table and allowance columns instead of toggling one node.
- **Who feels it:** Every keystroke-commit while building a quote: post names, grades, all shift cells, allowance ticks/amounts. Users tabbing through a post's schedule lose focus and lose typed values after each cell, which reads as 'the app is slowing down / eating my input'. Scales with number of expanded posts ('Expand all posts').

- **Fix:** Optimistic, targeted rendering. (a) In pbUpdatePostField / pbUpdateShiftCell / pbStatAllowToggle / pbAmtSave: update the model FIRST, patch only what changed, then fire the write and only on failure revert + showStatus. (b) Add `pbRerenderPost(postId)`: `const el = root.querySelector('.pb-post[data-post-id="'+id+'"]'); el.outerHTML = renderPost(p, h, idx);` plus `pbRerenderTotals()` that rewrites `.pb-totals-wrap` and the section counter; use these instead of renderQuoteEditor from the field-level handlers. (c) For the summary-row inputs the DOM already shows the typed value, so after a name/grade change only the totals/cost cells need updating - no re-render at all. (d) Reserve renderQuoteEditor for structural changes (add/delete/move post, tab switch). (e) Send `Prefer: return=minimal` on these PATCHes (see PB-12) - the echoed row is never used.

### PB-03 — Saving a salary-rate version is ~22 sequential writes plus a 3-stage reload, and is not atomic

**Impact medium · effort M · db view or rpc · reviewer (confidence 0.9)**

- **Where:** index.html:7984-8015 (_srSave: loops at 7990, 7997, 8004), 7959-7982 (_srBuildSavePlan), 7437-7492 (renderSalaryRateGrid reload), 8029-8069 (_srCreateVersion same shape)
- **Evidence:** `for (const p of plan.ratePatches) await api('quote_salary_rates','PATCH',...)` (7990); `await api('quote_rate_area_groups','DELETE',...)` (7996) then `for (const g of plan.areaGroups){ const made = await api(...,'POST',...,'select=id'); ... await api('quote_rate_area_group_members','POST',...) }` (7997-8001); same DELETE + per-group POST+POST for quote_rate_groups / quote_rate_group_cells (8003-8009); then `await renderSalaryRateGrid()` (8012) which is Promise.all(3) -> Promise.all(5) -> GET people (7449, 7458, 7478). Each of the group tables has an audit_row_change trigger (add_quote_rate_groups.sql / add_quote_rate_area_groups.sql), so the delete-and-recreate also writes ~2x(groups+members+cells) audit rows.
- **Mechanism:** Extra sequential round trips (typ. 22 writes + 9 reads in 3 stages = depth ~25) where a single transaction would do; plus a correctness hazard - an error between the DELETE at 7996/8003 and the re-creation leaves the version stripped of its groupings.
- **Who feels it:** HR/Executive users capturing or approving the annual determination (Statutory Salary Rates screen): ~35 s per Save at 1.4 s/trip, again on Submit/Approve/Decline/Reopen (each = 1 write + 9 reads in 3 stages) and on '+ New version' (~18 deep). Infrequent, but the slowest single action in the app.

- **Fix:** One RPC, one transaction: `create function pb_save_rate_version(p_version date, p_plan jsonb) returns jsonb language plpgsql` that (1) `update quote_salary_rates r set monthly_salary=x.monthly, hourly_rate=x.hourly from jsonb_to_recordset(p_plan->'rates') x(area_id bigint, grade_id bigint, monthly numeric, hourly numeric) where r.effective_date=p_version and r.area_id=x.area_id and r.grade_id=x.grade_id and (r.monthly_salary,r.hourly_rate) is distinct from (x.monthly,x.hourly)`; (2) `insert ... on conflict (effective_date, grade_id, area_id) do nothing` for new cells; (3) `delete from quote_rate_area_groups where effective_date=p_version`, then `for g in select * from jsonb_array_elements(p_plan->'areaGroups') loop insert ... returning id into v_id; insert into quote_rate_area_group_members select v_id, p_version, a from jsonb_array_elements_text(g->'members') a; end loop` and the same for cellGroups; (4) return the fresh grid payload (rates/groups/cells/areaGroups/members/versions + people names) so the client repaints without the 3-stage reload. Client: `_srBuildSavePlan()` already produces exactly this JSON - post it with `api('rpc/pb_save_rate_version','POST',{p_version:v,p_plan:plan})`. Depth 25 -> 1. Reuse the same function's shape for _srCreateVersion (copy structure from the previous version server-side: one INSERT ... SELECT per table). If an RPC is not wanted: bulk-POST all area groups in one call (`select=id` returns ids in input order), then all members in one call; same for cell groups (depth 25 -> ~9), and merge the two Promise.all stages of renderSalaryRateGrid into one (PB-08).

### PB-04 — pbPersistPostLayout PATCHes changed posts one at a time in series

**Impact medium · effort S · db view or rpc · reviewer (confidence 0.9)**

- **Where:** index.html:6719-6731 (pbPersistPostLayout); callers pbMoveHeading 6641, pbMovePost 6739, pbMovePostToHeading 6752, pbDropPostAt 6836
- **Evidence:** `for (const h of pbHeadings) { for (const p of h.posts) { ... if (Object.keys(body).length) { await apiPatch('quote_posts', p.id, body); Object.assign(p, body); } ord++; } }` - one awaited PATCH per post whose display_order or heading_text changed. display_order is renumbered globally, so moving a heading or dropping a post into an earlier heading changes every later post.
- **Mechanism:** Extra sequential round trips: 2 for a one-step post move, up to P (posts in the quote) for a heading move or a cross-heading drag. On error the fallback is a full openQuote (12-16 more).
- **Who feels it:** Anyone reordering posts or headings in a quote (arrows or drag-and-drop). On a 20-post quote a heading move can be 10-20 trips (~15-30 s) while the optimistic UI silently persists in the background - and a later edit can race with the still-running loop.

- **Fix:** One call. RPC: `create function pb_set_post_layout(p_rows jsonb) returns void language sql as $$ update quote_posts p set heading_text = r.heading_text, display_order = r.display_order from jsonb_to_recordset(p_rows) as r(id bigint, heading_text text, display_order smallint) where p.id = r.id and (p.heading_text, p.display_order) is distinct from (r.heading_text, r.display_order) $$;` and post the whole layout `[{id, heading_text, display_order}]` from pbPersistPostLayout. Alternative without an RPC: PostgREST bulk upsert `POST quote_posts?columns=id,quote_id,name,heading_text,display_order` with `Prefer: resolution=merge-duplicates` (quote_id and name must be included because they are NOT NULL without defaults) - needs api() to accept a Prefer override (PB-12). Depth P -> 1.

### PB-05 — Shift-schedule bulk writes are per-post DELETE+POST loops or per-shift PATCH loops

**Impact medium · effort S · query shape · reviewer (confidence 0.95)**

- **Where:** index.html:6568-6590 (pbUpdateShiftsPerDay), 6945-6957 (pbDoResetPostShifts), 6889-6921 (pbToggleWeekdaysExpanded collapse), 7013-7071 (pbApplyCopy)
- **Evidence:** pbUpdateShiftsPerDay: `await apiPatch('quote_quotes', ...); for (const h of pbHeadings) for (const p of h.posts) { await api('quote_post_shifts','DELETE',null,'post_id=eq.'+p.id); const rows = pbDefaultShiftRows(p.id, N); await apiPost('quote_post_shifts', rows); ... }` (6574-6583) = 1 + 2P sequential. pbDoResetPostShifts: DELETE then POST (6950-6952). pbToggleWeekdaysExpanded collapse: `for (let s = 1; s <= N; s++) await api('quote_post_shifts','PATCH',...)` (6906-6913). pbApplyCopy 'equal': one PATCH per shift index (7028-7031) then optional group/shift/adjacent PATCHes (7043, 7052, 7067). quote_post_shifts PK is (post_id, shift_index, day_type), so every one of these is a set of rows with known keys.
- **Mechanism:** Extra sequential round trips: 1+2P for a shifts/day change (21 on a 10-post quote), 2 for a reset, up to N for a weekday collapse, up to N+2 for a copy-Apply, where each is one upsert of at most 32 x P rows.
- **Who feels it:** Changing shifts/day on the Basic info tab is the worst (the confirm dialog warns it resets everything, then the user waits ~30 s on a 10-post quote); reset/copy/collapse are 2-6 s each and happen many times while laying out a schedule.

- **Fix:** Replace DELETE+POST and PATCH loops with one upsert on the composite PK. Either (a) `POST quote_post_shifts` with `Prefer: resolution=merge-duplicates,return=minimal` sending every (post_id, shift_index, day_type, num_officers, start_time, end_time) row for all affected posts in one body (needs api() Prefer override, PB-12) - for pbUpdateShiftsPerDay first one `DELETE quote_post_shifts?post_id=in.(all ids)&shift_index=gt.N` to drop rows for removed shift indexes, then one upsert POST: depth 1+2P -> 3; or (b) an RPC `pb_reset_shifts(p_quote_id bigint, p_n smallint)` that PATCHes the quote and regenerates default rows with one `insert ... select from quote_posts cross join generate_series(1,p_n) cross join unnest(day_types) on conflict (post_id,shift_index,day_type) do update ...` plus a delete of indexes > p_n: depth 1. pbApplyCopy/collapse: compute the full target row set client-side (already done for the in-memory model) and send it as one upsert.

### PB-06 — Adding or duplicating a post is two dependent writes (post, then its 16-32 shift rows)

**Impact medium · effort M · db trigger · reviewer (confidence 0.8)**

- **Where:** index.html:6656-6674 (pbAddPost), 6688-6717 (pbDuplicatePost)
- **Evidence:** `const r = await apiPost('quote_posts', payload); ... const rows = pbDefaultShiftRows(post.id, N); await apiPost('quote_post_shifts', rows);` (6661-6666); duplicate builds the rows from src.shifts and does the same (6696-6707). The second POST cannot start until the first returns the new id.
- **Mechanism:** Extra sequential round trip per add (2 -> could be 1), plus a full editor re-render after.
- **Who feels it:** Every '+ Post' / '+ Add post' / 'Duplicate' click while building a quote - ~3 s instead of ~1.5 s each, repeated per post.

- **Fix:** Move default-shift creation into the database: `create function pb_post_default_shifts() returns trigger ... after insert on quote_posts` that inserts 8 x q.shifts_per_day rows (using PB_SHIFT_DEFAULTS ported into a small CASE/VALUES) when NEW has no shifts yet; then pbAddPost does a single `POST quote_posts?select=*,quote_post_shifts(*)` (PostgREST returns the embedded shift rows in the insert representation) and builds post.shifts from the response. For duplicate: RPC `pb_duplicate_post(p_post_id bigint) returns bigint` that copies the post row, its quote_post_shifts and (a current omission) its allowance/incentive link rows in one statement, then the client fetches the new post with the same embedded select or has the RPC return the jsonb. Depth 2 -> 1.

### PB-07 — Allowance ticks and amounts do DELETE+POST where a single PATCH/upsert suffices

**Impact low · effort S · query shape · reviewer (confidence 0.9)**

- **Where:** index.html:6203-6244 (pbStatAllowToggle: 6222-6224, 6233), 6247-6266 (pbStatAllowOverrideConfirm: 6257-6258), 6268-6306 (pbAmtSave: 6292-6295)
- **Evidence:** pbAmtSave: `if ((p[mapKey] || {})[+itemId] != null) await api(table, 'DELETE', null, where); const row = {post_id: postId, rate_amount: n}; row[idCol] = itemId; await api(table, 'POST', row, '');` - changing an existing amount is delete + insert. pbStatAllowOverrideConfirm: `if (...) await api(..., 'DELETE', ...); await api(..., 'POST', {..., state:'off', override_reason, created_by}, '')`. All three link tables have PK (post_id, <ref_id>) and an audit_row_change trigger (add_statutory_allowance_rules.sql, add_allowance_help_retire.sql), so each change writes two audit rows with full row_data.
- **Mechanism:** Extra sequential write (2 instead of 1) + double audit-trigger work per change, followed by a full editor re-render (PB-02).
- **Who feels it:** Every amount edit or statutory tick on an expanded post's Allowances section - ~3 s per change instead of ~1.5 s.

- **Fix:** When a link row exists, `PATCH quote_post_discretionary_allowances?post_id=eq.<p>&discretionary_allowance_id=eq.<a>` with `{rate_amount: n}` (or `{state, override_reason}` for statutory); POST only when absent. Or a single upsert `POST ... Prefer: resolution=merge-duplicates` regardless (needs PB-12). Combine with PB-02 so the input is not rebuilt afterwards.

### PB-08 — Salary-rate grid load is three sequential stages and is re-run in full after every status change

**Impact low · effort S · parallelise · reviewer (confidence 0.9)**

- **Where:** index.html:7437-7492 (renderSalaryRateGrid: 7449 Promise.all, 7458 Promise.all, 7478 people GET); re-invoked at 8012, 8067, 8115, 8167
- **Evidence:** `const [rates, areas, grades] = await Promise.all([...])` then `[groups, cells, areaGroups, areaMembers, versionStatus] = await Promise.all([...])` (comment says the split exists only to detect missing migrations) then `window._srData.people = await apiGet('people', 'id=in.(' + pids.join(',') + ')&select=id,first_name,last_name')`. All eight table reads are independent; only the people lookup depends on quote_rate_versions. apiGetAll('quote_salary_rates') pulls every version (4 x 20 = 80 rows today, +20/year) although only one version is painted - acceptable at this volume, but the version list could come from quote_rate_versions alone.
- **Mechanism:** Extra sequential round trips: depth 3 (9 calls) where depth 1 (8 calls) is possible; repeated after Save, Submit, Approve, Decline, Reopen, Create, Delete.
- **Who feels it:** HR/Executive users opening the Statutory Salary Rates screen and after every action on it: ~4 s of 'Loading rates' per visit/action instead of ~1.4 s.

- **Fix:** One Promise.all of all eight reads (wrap the five migration-dependent ones with `.catch(e => { missing = true; return []; })` to keep the migration hint); embed the reviewer names with FK hints so the people call disappears: `quote_rate_versions?select=*,entered:people!quote_rate_versions_entered_by_fkey(id,first_name,last_name),submitted:people!quote_rate_versions_submitted_by_fkey(id,first_name,last_name),approved:people!quote_rate_versions_approved_by_fkey(id,first_name,last_name)&order=effective_date.asc`. If PB-03's RPC returns the grid payload, _srSetStatus can do the same and skip the reload entirely. Depth 3 -> 1.

### PB-09 — Statutory Allowances year grid repaints the whole table after every field blur

**Impact low · effort S · dom render · reviewer (confidence 0.85)**

- **Where:** index.html:8292-8312 (_saPatch), 8215-8290 (_saPaint)
- **Evidence:** `await api('quote_statutory_allowances', 'PATCH', { [field]: val }, 'id=eq.' + id); r[field] = val; _saPaint();` - _saPaint rewrites `top.innerHTML` and `out.innerHTML` (the entire tab bar + table of inputs). The screen's own hint says 'Edits save as you leave a field' (8248), so tabbing along a row triggers a PATCH + full repaint per cell.
- **Mechanism:** Network-gated DOM rebuild: ~1.4 s after each blur the input the user has moved to is destroyed and recreated, losing focus and any typed text (same mechanism as PB-02, smaller scale).
- **Who feels it:** HR admin typing the year's rates/help text/last-active dates - every cell edit interrupts the next one. Admin-only, annual.

- **Fix:** Do not repaint after a successful PATCH: update `r[field]`, then patch in place - toggle the red 'missing' outline on that cell and update the missing-count badge/text via querySelector; call _saPaint only on error (to restore the server value) or on structural changes (_saAdd, _saCreateYear). Optionally fire the PATCH without awaiting before updating the model (optimistic).

### PB-10 — Generic HR grid re-fetches the whole table after each row save/add/delete although the write already returns the row

**Impact low · effort S · query shape · reviewer (confidence 0.85)**

- **Where:** index.html:8595-8652 (renderPbEditor), 8708-8720 (pbAddRow), 8731-8752 (pbSaveRow), 8754-8763 (pbDeleteRow)
- **Evidence:** pbSaveRow: `await apiPatch(schema.table, rowId, updates); pbEditingRowId = null; await renderPbEditor(pbActiveSchema, {...})` - apiPatch already requests `select=*` with return=representation, and renderPbEditor then does Promise.all(lookups) (cached after first) + `pbRows = await apiGet(schema.table, params)` + rebuilds `body.innerHTML` from all rows. pbEditRow (8723) also re-runs renderPbEditor (a full re-render, no fetch since lookups are cached, but still a GET of rows at 8615).
- **Mechanism:** Extra sequential round trips: 2 per save/add/delete (write + full re-read), and a GET of the whole table just to switch one row into edit mode.
- **Who feels it:** HR admin editing any of the 12 list-style tiles (discretionary allowances/incentives, leave, shared salary options, calc ratios, extraordinary hours) and Standard Posts/Headings - each Edit/Done/Add/Delete is ~3 s instead of ~1.5 s.

- **Fix:** Use the returned representation: on save `Object.assign(pbRows.find(r => r.id === rowId), result[0])`, on add `pbRows.push(result[0])`, on delete `pbRows = pbRows.filter(...)`; then re-render only that `<tr>` (give rows `data-row-id` and replace via outerHTML with pbRenderRow) and update the count in #page-sub. pbEditRow needs no network at all - just repaint the row. Depth 2 -> 1; edit-mode switch 1 -> 0.

### PB-11 — Allowance catalogs and rules are fetched whole (every year's rows) on every quote open and filtered in JS; the DB views built for this are unused and the wrong shape

**Impact low · effort M · db view or rpc · reviewer (confidence 0.8)**

- **Where:** index.html:6004-6009 (openQuote), 6313-6324 (pbCurrentByCode), 8452-8456 (renderAllowRules); sql/quote_tool_phase_a.sql 261-312 (v_quote_*_current views), quote_tool_phase_b.sql 200-224 (v_quote_quotes_full, v_quote_posts_full)
- **Evidence:** grep for `v_quote_` in index.html returns nothing - none of the 10 views is referenced; the client re-joins in JS (pbCurrentByCode picks the newest effective_date <= as-at per code and applies retired_date and null-rate rules). The views use CURRENT_DATE, ignore retired_date (added later in add_allowance_help_retire.sql) and the NULL-rate rule (statutory_allowances_annual.sql), so they cannot be swapped in as-is. quote_statutory_allowances is cloned in full every year by _saCreateYear (8351-8356), so the five whole-table GETs at 6004-6009 grow linearly with years captured. Being plain (non-materialised) views, the unused ones cost nothing at runtime.
- **Mechanism:** Over-fetch (all years of three catalogs + rules + members = 5 calls, growing yearly) plus client-side DISTINCT ON per render (pbAllowanceCols runs three pbCurrentByCode+sort passes per expanded post on every renderQuoteEditor). Volume is small today (tens of rows per table) - this is mostly a round-trip finding, folded into PB-01's RPC.
- **Who feels it:** Every quote open (5 of the 12-16 trips in PB-01); every editor repaint with expanded posts does the JS join again. Low today, grows with each captured year.

- **Fix:** Serve the as-at-filtered lists from the database in one call: either a parameterised RPC `pb_current_allowances(p_as_at date) returns jsonb` using `select distinct on (code) * from quote_statutory_allowances where effective_date <= p_as_at order by code, effective_date desc` (then `where retired_date is null or retired_date >= p_as_at`, and `rate is not null`) for each catalog, plus rules and members - or fold these into PB-01's `pb_open_quote(p_quote_id)` using the quote's `coalesce(contract_start_date, quote_date)`. The (code, effective_date DESC) index already exists on quote_statutory_allowances; add the same on quote_discretionary_allowances and quote_discretionary_incentives if they ever exceed a few hundred rows (not needed today). Either drop the 10 unused views or replace them with the parameterised function so the definitions cannot drift further from pbCurrentByCode.

### PB-12 — api() hard-codes Prefer: return=representation on every write and cannot send resolution=merge-duplicates or return=minimal

**Impact low · effort S · payload · reviewer (confidence 0.9)**

- **Where:** index.html:2049-2052 (api opts.headers), 2113-2115 (apiPost/apiPatch); netlify/functions/sb.js proxy forwards `Prefer` verbatim (line ~275 `'Prefer': event.headers['prefer'] || ''`)
- **Evidence:** `headers: { 'Content-Type': 'application/json', 'Prefer': method === 'POST' ? 'return=representation' : method === 'PATCH' ? 'return=representation' : '' }` - no way for a caller to ask for an upsert or to suppress the echo. Consequences in this slice: bulk shift PATCHes (up to 32 rows x day types) and 16-32-row shift POSTs echo every row back through the proxy though only pbAddPost reads the result; the delete-then-insert patterns in PB-05 and PB-07 exist because upsert is unreachable; pbPersistPostLayout (PB-04) cannot bulk-upsert.
- **Mechanism:** Payload bytes on every write (the echoed representation) and, more importantly, an enabler: without a Prefer override the single-call fixes in PB-04/05/07 need RPCs instead of plain PostgREST upserts.
- **Who feels it:** Indirect - unlocks the one-call versions of the shift, layout and allowance writes; direct saving is small (a few KB per write).

- **Fix:** Add an optional 5th argument: `async function api(table, method, body, params, prefer)` and use `'Prefer': prefer != null ? prefer : (method === 'POST' || method === 'PATCH' ? 'return=representation' : '')`. Then e.g. `api('quote_post_shifts','POST',rows,'', 'resolution=merge-duplicates,return=minimal')` for upserts on the composite PK, and `return=minimal` on fire-and-forget PATCHes in pbUpdatePostField/pbUpdateShiftCell. sb.js needs no change (it already forwards Prefer and its CORS allow-list includes it).


## Client CPU and rendering

### CPU-1 — Leads register does ~15 linear lookup scans per row, and re-runs lookup getters inside the sort comparator and filter pass

**Impact high · effort M · client cpu · reviewer (confidence 0.85)**

- **Where:** index.html:14932-15060 (renderLeadRow), 14856-14868 (column getters), 14875-14896 (leadsGroupRenderer), 2312-2331 (_renderTable filter/sort), 2395 (_openFilterPopup), helpers 14157-14165, 14179-14197, 14209-14235, 14251-14257, 14276-14284, 14294-14318, 11746-11757
- **Evidence:** renderLeadRow opens with five scans: `const source = sources.find(...)`, `regions.find`, `(allData['branches'] || []).find`, `people.find`, `orgs.find` (14933-14937). Each row then calls leadSiteLabel (14160 `(allData['sites'] || []).find`), leadClientLabel (14186-14192: up to O.find + S.find + O.find), _childHookHtml (14278 `O.find` + _ultimateParentOrg 14214 `orgs.find` per parent hop), _leadSectorName (11754 sites.find, 11748 orgs.find, 11750 industry_sectors.find), leadEffectiveTouch (14314 sites.find + _groupTouchFor 14298 `O.find`), and hookOrgId (15038-15039 sites.find). The column getters (14856-14868) repeat the same scans ('source','client','target','region','branch','sector','owner'), and _renderTable evaluates them inside the comparator: `const va = col.get(a), vb = col.get(b);` (2323) and per row per active filter (2315 `_tblDisplay(col, row)`), and again for every row when a filter popup opens (2395). The group renderer adds leadBandOf per row (14224 leadClientOf + 14227 `O.find(x => 'o' + x.id === c.key)` — a string concat per organisation per lead) and per band `_groupChipHtml(b.key)` (15130) -> _familyOrgIds (14251 `O.forEach(o => { if (+_ultimateParentOrg(o, O).id === +parentId) ...`) which walks the entire organisations array. The helper's own comment is stale: 2283 "Datasets are small (<1000 rows per list) so this is fast." while leads are fetched with `apiGetAll('leads', ...) // paged: survives the 1000-row cap` (14728).
- **Mechanism:** O(n x M) CPU join per render: n leads (paged, so assume 1,000-3,000 across all tabs; the active tab is the filtered subset), M organisations/sites/people in allData (select=* full tables, 2148-2150; also paged with apiGetAll at 2195, so assume 1,000-5,000). ~15 scans/row x M/2 average iterations ~= 2,000 x 15 x 1,000 = 30M closure invocations per render (hundreds of ms). Sorting by a lookup column costs n log2 n comparisons x 2 getters x 1-3 scans each: 2,000 x 11 x 2 x 2 x 1,000 ~= 90M invocations (up to seconds). Every band click (toggleClientBand 11673-11677 -> _renderTable), Expand/Collapse all (11680-11684), sort click and filter checkbox repeats the whole cost. Volume assumption: if organisations+sites are only a few hundred rows this drops to tens of ms and becomes minor.
- **Who feels it:** Leads register (default landing page for sales users after the dashboard): initial paint after data arrives, and every sort/filter/band click, freezes the tab for hundreds of ms to seconds while nothing is on the network. Felt on every visit and every interaction with the register.

- **Fix:** Two layers. (1) Client: build index Maps once per render and pass them down — `const orgById = new Map(orgs.map(o => [+o.id, o])), siteById = ..., personById = ..., sourceById = ..., regionById = ..., branchById = ..., sectorById = ...;` then precompute a display record per lead ONCE (`const view = leads.map(l => ({ l, source: sourceById.get(+l.source_id)?.name || '', client: ..., site: ..., region: ..., branch: ..., sector: ..., owner: ..., touchDays: ... }))`) and make the column getters read those fields (`get: v => v.client`) so filter/sort/popup are O(1) per row; renderLeadRow(view) then does zero scans. Replace `O.find(x => 'o' + x.id === c.key)` (14227) with `orgById.get(+c.key.slice(1))`. Memoise _ultimateParentOrg per org id per render (Map) and compute family sizes once (`familyCount` Map from topOf) instead of _familyOrgIds per band. (2) Server: stop joining on the client at all — PostgREST resource embedding on the leads fetch, e.g. `leads?select=*,owner:people!leads_owner_id_fkey(first_name,last_name),source:lead_sources(name),region:regions(name),branch:branches(name),site:sites(name,organisation:organisations(id,name,parent_org_id,sector:industry_sectors(name))),org:organisations!leads_target_org_id_fkey(id,name,parent_org_id,sector:industry_sectors(name))&order=created_at.desc` (use the actual FK constraint names from sql/schema.sql for the `!fk` hints where a table has two FKs to the same target). Then getters become `l.org?.name`. This also removes the need to refetch full organisations/sites (select=*) for the register (14732-14735).

### CPU-3 — Shared table helper rebuilds every row via innerHTML on each interaction, with no pagination or virtualisation, using ~1.5 KB of inline-styled HTML per lead row

**Impact high · effort M · dom render · reviewer (confidence 0.8)**

- **Where:** index.html:2306-2378 (_renderTable), 2346 and 2369 (innerHTML writes), 2380-2391 (_cycleSort), 2452-2461 (_toggleValue), 11673-11684 (toggleClientBand/setLeadBandsAll), 11737-11740 (toggleLineage), 14932-15060 (renderLeadRow), 3603-3640 (loadTable rowRenderer), apiGetAll-backed lists at 3560, 11768, 13706, 14061, 14728, 24786, 24974
- **Evidence:** `bodyRoot.innerHTML = s.groupRenderer ? s.groupRenderer(filtered) : filtered.map(rowRenderer).join('');` (2369) and `headRoot.innerHTML = banner + ...` (2346) run on every _renderTable, and every interaction routes there: `_cycleSort` -> `_renderTable(tableId)` (2390), `_toggleValue` -> `_renderTable` (2459), `toggleClientBand` -> `_renderTable(page === 'leads' ? 'leads-' + leadsViewTab : 'opportunities')` (11676), `toggleLineage` -> `_renderTable('opportunities')` (11739). renderLeadRow emits ten `<td style="padding:10px 12px;font-size:13px;">` cells (15040-15049), four inline-styled qual-dot spans (~170 B each, 14970-14973), a next-action div, a touch span and a `<tr onclick=...>` — roughly 1.3-1.6 KB per row. Generic admin rows add 2-4 `.btn` buttons each (3613-3633). No list applies limit/offset for display; the primary reads are apiGetAll (3560, 11768, 13706, 14728).
- **Mechanism:** DOM rebuild: for 2,000 leads a ~3 MB HTML string is built, parsed, style-resolved (inline `style` on every cell = per-element style recalculation) and laid out on every click, on top of the CPU-1 join cost. Opening one client band or toggling one lineage family discards and recreates every row. Browser parse+layout for ~20k table cells is typically 200-600 ms on a laptop; the old tree is garbage-collected shortly after, contributing to GC pauses during a long session.
- **Who feels it:** Every register page (Leads, Opportunities, Deal Admin, Clients, Contacts, People, Milestones, Bug reports): visible freeze on each sort/filter/band/lineage click; scroll jank right after render; larger lists get proportionally worse. Felt many times per session by every user.

- **Fix:** (a) Patch instead of rebuild for band/lineage toggles: give child rows `data-band="<key>"` and toggle `hidden` on `tbody.querySelectorAll('tr[data-band="k"]')` plus the toggle arrow class — no re-filter/sort/render. (b) Move the repeated inline styles to classes (`.reg td{padding:10px 12px;font-size:13px}` `.qdot{display:inline-block;width:10px;height:10px;border-radius:50%;margin:0 1px}`) — cuts the string by ~40% and removes per-cell inline style resolution. (c) Window the rows: render the first 150-200 rows of `filtered`, then append the next chunk on an IntersectionObserver sentinel or a 'Show 200 more' button (`_tableState[tableId].shown += 200`). Tab counts already come from the in-memory array so they are unaffected. (d) Cache getter values per row (precomputed view records, see CPU-1) so the filter/sort passes never re-run lookups. (e) For true server-side paging later, use PostgREST `Range`/`limit=200&offset=` with `Prefer: count=exact` for the total, and keep tab counts from a tiny aggregate view (`SELECT status, count(*) FROM leads GROUP BY status`).

### CPU-2 — Organisations and Clients admin lists are O(M^2): the per-row 'Group' column walks the whole organisations array for every row

**Impact medium · effort S · client cpu · reviewer (confidence 0.9)**

- **Where:** index.html:2759 and 2819 (PAGES.organisations / PAGES.clients column config), 14260-14270 (_groupChipHtml), 14251-14257 (_familyOrgIds), 14209-14219 (_ultimateParentOrg), 3603-3611 (loadTable rowRenderer), 2369 (_renderTable)
- **Evidence:** Both list configs carry `{ key: 'id', label: 'Group', render: v => _groupChipHtml('o' + (+v)) }` (2759, 2819). _groupChipHtml does `const n = _familyOrgIds(id).length;` (14264) and _familyOrgIds is `O.forEach(o => { if (+_ultimateParentOrg(o, O).id === +parentId) ids.add(+o.id); });` (14251) over `allData['organisations']`. loadTable's rowRenderer calls `col.render(val)` for every row (3606) on every _renderTable (initial, every sort, every filter). _ultimateParentOrg itself does `(orgs || []).find(x => +x.id === +cur.parent_org_id)` per parent hop (14214).
- **Mechanism:** M rows x M organisations per render = M^2 iterations (plus M x hops x M for orgs with parents). M = 2,000 organisations -> 4M _ultimateParentOrg calls per render; 5,000 -> 25M. The primary rows for these pages come from apiGetAll (3560), so the list itself is unpaginated. Repeated on every sort/filter click. Volume assumption: only matters once organisations is in the low thousands; at 300 orgs it is ~90k iterations (negligible).
- **Who feels it:** Manage Clients and Organisations pages (admin/sales management): initial render and every column sort/filter stalls the tab, growing quadratically with the client base — the page that 'used to be fine' gets slower as clients are added.

- **Fix:** Compute family sizes once per render, not per row: `const parentOf = new Map(orgs.map(o => [+o.id, o.parent_org_id ? +o.parent_org_id : null])); const topOf = new Map(); const top = id => { if (topOf.has(id)) return topOf.get(id); const seen = new Set(); let cur = id; while (parentOf.get(cur) && !seen.has(cur)) { seen.add(cur); cur = parentOf.get(cur); } topOf.set(id, cur); return cur; }; const familyCount = new Map(); orgs.forEach(o => { const t = top(+o.id); familyCount.set(t, (familyCount.get(t) || 0) + 1); });` then `_groupChipHtml(key, familyCount)` reads `familyCount.get(id) || 1`. Alternatively expose it from the DB so no client walk exists: `CREATE VIEW organisation_family AS WITH RECURSIVE up AS (SELECT id, id AS top, parent_org_id, 1 AS depth FROM organisations UNION ALL SELECT u.id, o.id, o.parent_org_id, u.depth+1 FROM up u JOIN organisations o ON o.id = u.parent_org_id WHERE u.depth < 10) SELECT DISTINCT ON (id) id, top FROM up ORDER BY id, depth DESC;` and a `family_size` aggregate view over it, then embed `family:organisation_family_size(size)` in the organisations select.

### CPU-4 — Revenue Pipeline paint() thrashes layout: rebuilds the full grid up to (FY count - 2) times per paint to find the fitting column count, recomputes deal values per cell, and repaints on every raw resize event

**Impact medium · effort M · dom render · reviewer (confidence 0.8)**

- **Where:** index.html:13525-13549 (paint), 13365-13455 (buildAndMeasure), 13232-13233 (fyValue/dealValue), 13268-13276 (visibleDeals sort), 13458-13492 (alignTabs), 13505-13512 (renderTotStrip), 13672 (resize listener), 13553-13558 and 13173 (control toggles)
- **Evidence:** `for (let n=visN; n<=total; n++){ buildAndMeasure(n, true, false); if (document.getElementById('rpp-grid').getBoundingClientRect().width <= avail) visN = n; else break; }` (13541-13544) then `buildAndMeasure(visN, false, true)` (13546). buildAndMeasure writes `rpp-thead`, `rpp-tbody` innerHTML for every visible deal (13451-13454) and per deal row calls `dealValue(d)` (13413: `FYS.reduce((s,f)=> s + fyValue(d, f.key), 0)`, where fyValue loops 12 months calling layers()) AND `fyValue(d,f.key)` again per window FY (13423). visibleDeals' sort uses `c.get` = `dealValue(d)` for the Value column, twice per comparison (13270-13271, 13239). renderTotStrip re-walks every deal x every FY x 12 months (13506-13508). `window.addEventListener('resize', ()=>{ if (document.getElementById('rpp-root')) paint(); });` (13672) is unthrottled.
- **Mechanism:** Write -> forced synchronous layout (getBoundingClientRect after innerHTML) -> write, k+1 times per paint where k = FYS.length - MIN_FY(3) + 1; each build is O(deals x FY x 12) layers() calls plus string building, and alignTabs then reads offsetWidth per header cell (13462-13481). A window resize fires dozens of events per drag, each running the entire loop. With D deals over Y financial years: per paint ~ (Y-1) x D x (2Y x 12) layers calls; D=500, Y=6 -> ~360k layers() calls + 5 full grid parses.
- **Who feels it:** Revenue Pipeline page (management): noticeable lag (hundreds of ms to seconds) on open, on every basis/metric/FY/detail toggle, on each lineage expand, and stutter while resizing the window. Scales with deal count and years of history.

- **Fix:** (1) Measure once: build the grid at n = total with the card `visibility:hidden`, read each FY header cell width from a single `getBoundingClientRect()` pass, then compute `visN` arithmetically (`while (fixedW + sum(fyWidths.slice(start, start+visN)) > avail) visN--`) and build the committed grid one time. Since non-open FY columns are fixed at `width:96px` (13380) the arithmetic can even skip the hidden build. (2) Memoise per paint: `const dv = new Map(); const dealValueM = d => dv.has(d.id) ? dv.get(d.id) : (dv.set(d.id, dealValue(d)), dv.get(d.id));` and cache `fyValue` per (deal, fy) — clear the maps when basis/metric change. Use the memoised value in the Value-column sort and in renderTotStrip. (3) Debounce resize: `let raf; window.addEventListener('resize', () => { if (!document.getElementById('rpp-root')) return; cancelAnimationFrame(raf); raf = requestAnimationFrame(paint); });` (or a 150 ms timer).

### CPU-5 — Undebounced per-keystroke fuzzy matching over every organisation / person / site on the lead, contact and promotion forms

**Impact medium · effort S · client cpu · reviewer (confidence 0.85)**

- **Where:** index.html:1251 & 19342-19362 (onLeadTargetOrgNameInput), 16167 & 16281-16293 (onCtCompanyInput), 1086 & 19668-19698 (onLeadSourcePersonNameInput), 21676-21682 & 21599-21601 (_onPromoteOrgNameInput), 18770-18780 & 18747-18766 (onLeadSiteInput/_leadSiteSearch), 16385-16399 (refreshCtContactSuggestions); scoring at 21497-21524, 21435-21447, 19593-19626, 19480-19516, 19517-19560
- **Evidence:** `<input ... id="lead-target-org-name" ... oninput="onLeadTargetOrgNameInput()">` (1251) -> `const { exact, shortlist } = _findOrgMatches(name, '', 5);` (19362) with no timer. _findOrgMatches maps every organisation through _orgMatchScore (21518), which runs `_normaliseOrgName` four times (21498-21501; each does 2 passes over the `_ORG_NAME_NOISE` regex list plus two more regexes and a split/filter, 21439-21446) and up to four `_stringSimilarity` calls (21503-21506), each = 2 Jaro-Winkler + 2 metaphone passes (19596-19597). onCtCompanyInput additionally calls `refreshCtContactSuggestions();` (16287) which scores affiliated people with `_personMatchScore` (16399: up to 7 _stringSimilarity calls each, 19613-19625) and then `_findOrgMatches(name, '', 5)` (16293). onLeadSourcePersonNameInput -> `_findPersonMatches(name)` (19698) over all people. _leadSiteSearch does `const orgNameOf = id => (orgs.find(o => +o.id === +id)?.name) || '';` per site (18753) plus two tokenSetRatio calls per site (18759). By contrast checkOrgSimilarity wraps the same matcher in a 400 ms `setTimeout` (9752-9771) and the person checkers at 9850, 10302, 10660, 4076, 16345 are all debounced.
- **Mechanism:** Synchronous main-thread CPU per keystroke: ~30 regex replaces + ~8 similarity passes per organisation; with M = 2,000 organisations that is ~60k regex operations and ~16k string-similarity passes per keystroke (roughly 30-150 ms), repeated for every character typed. _leadSiteSearch is O(sites x orgs) because of the per-site orgs.find. Normalised names and metaphone codes of the corpus are recomputed on every keystroke although they never change between edits. Volume assumption: below ~500 organisations this is under 10 ms and not noticeable.
- **Who feels it:** Lead form (organisation name, site, referrer name), contact form (company), promotion dialog (organisation): typing stutters/drops characters proportionally to the size of the organisation and people tables. Felt every time a lead or contact is captured.

- **Fix:** (1) Debounce all five handlers exactly like checkOrgSimilarity: `let _tgtOrgTimer; function onLeadTargetOrgNameInput(){ ...cheap sync bits (readiness)...; clearTimeout(_tgtOrgTimer); _tgtOrgTimer = setTimeout(_runTargetOrgMatch, 250); }`. (2) Precompute the corpus once alongside the existing in-memory `_org_idf` build (21453-21471): `allData['_org_norm'] = orgs.map(o => ({ o, on: _normaliseOrgName(o.name), oL: _normaliseOrgName(o.legal_name), mOn: _metaphone(on), mOL: _metaphone(oL) }))` (invalidate where `_org_idf` is invalidated) and have _orgMatchScore take the precomputed record so per-keystroke work is Jaro-Winkler only; normalise the query once outside the map. (3) Cheap prefilter before scoring: skip candidates whose normalised name shares no token prefix (first 2 chars) or metaphone with the query. (4) In _leadSiteSearch build `const orgNameById = new Map(orgs.map(o => [+o.id, o.name]))` once and use `orgNameById.get(+s.organisation_id)`.

### CPU-6 — Engagement History search box re-filters and fully re-renders up to 1,000 grouped rows on every keystroke

**Impact medium · effort S · dom render · reviewer (confidence 0.75)**

- **Where:** index.html:16665 (eh-search oninput), 16674-16697 (_engHistFilteredRows), 16800-16875 (_engHistApply), 16693-16694 (search string built per row per keystroke), 16874 (out.innerHTML)
- **Evidence:** `<input type="text" id="eh-search" ... oninput="_engHistApply()">` (16665). _engHistFilteredRows builds `(r.clientName + ' ' + r.parentLabel + ' ' + r.persons.join(' ') + ' ' + (r.e.notes || '') + ' ' + ... ).toLowerCase().includes(q)` for every row on every call (16693-16694). _engHistApply then regroups (16818-16828), sorts groups (16830-16831), builds ~1 KB of inline-styled HTML per row with 5-8 cEsc calls (16833-16863) and writes `out.innerHTML = ...` (16874). The loaded set is capped at 1,000 rows (capNote 16806), so the worst case is bounded but large.
- **Mechanism:** Per keystroke: 1,000 string concatenations + lowercasing of note bodies, regroup, and a ~1 MB innerHTML parse/layout — typically 50-150 ms of main-thread work, so typing a 10-character search costs ~1 s of blocked UI. No debounce.
- **Who feels it:** Engagement History pages (Outreach/Sales/Contract/Project): typing in Search lags when the date range holds many engagements. Felt by users who review history regularly; negligible for narrow date windows.

- **Fix:** Debounce the input (`oninput="_engHistSearchDebounced()"` with a 200 ms setTimeout), precompute `r.searchText` once in the load block at 26442-26520 (e.g. after persons are attached) so the filter is a single includes() per row, and render group bodies lazily (collapsed groups emit only their header until clicked). Optionally keep the 1,000 cap but render the first 200 rows with a 'Show more'.

### CPU-7 — Opportunities register repeats the O(rows x lookups) join pattern, walks all organisations per client band, and re-renders everything on each lineage/band toggle

**Impact medium · effort M · client cpu · reviewer (confidence 0.8)**

- **Where:** index.html:11824-11831 (columns), 11842-11853 (dealRow), 11836-11838 (col1Of), 11916-11933 (dealBandRow), 11935-11951 (groupRenderer), 14236-14242 (dealBandOf), 11737-11740 (toggleLineage), 11746-11751 (_orgSectorName)
- **Evidence:** Column getters: `get: d => (orgs.find(o => +o.id === +d.org_id)?.name) || ''` (11825), `get: d => _orgSectorName(d.org_id)` (11826, two more finds at 11748/11750), `get: d => (stages.find(...)?.name)` (11829). dealRow does `stages.find` (11843), col1Of -> `orgs.find`/`sites.find` (11836-11838, 11821), and `_orgSectorName(d.org_id)` (11848). groupRenderer calls `dealBandOf(d, orgs)` per deal (11939 -> 14238 `O.find` + _ultimateParentOrg) and dealBandRow does `[...members].sort(...)` (11918), `stages.find` (11922) and `_groupChipHtml(k)` (11926 -> _familyOrgIds full-orgs scan, 14251) per band. `toggleLineage` -> `_renderTable('opportunities')` (11739).
- **Mechanism:** Same as CPU-1/CPU-2 with n = deals (apiGetAll at 11768, filtered to open stage by default) and M = organisations: ~6 scans per row plus one full organisations pass per client band, re-run inside the sort comparator and on every toggle. Deal counts are probably lower than leads, so the absolute cost is smaller unless the 'All statuses' filter is used.
- **Who feels it:** Opportunities register (all sales users): slower first paint and a stall on each sort/filter/band/lineage click, worse with 'All statuses'.

- **Fix:** Apply the CPU-1 pattern: `orgById`/`stageById`/`siteById`/`sectorById` Maps built once per render, precomputed view records for the getters, memoised `topOf` for dealBandOf and a single `familyCount` map for the chips; toggle lineage/band rows via `hidden` on `tr[data-band]`/`tr[data-master]` instead of re-rendering. Server-side alternative: `deals?select=*,org:organisations(id,name,parent_org_id,sector:industry_sectors(name)),stage:stages(name,category_id),site:sites(name)&order=created_at.desc`, which also lets the open-stage filter run in the query (`stage.category_id=eq.<open cat id>` via `stages!inner`).

### CPU-10 — 60-second presence/broadcast poll makes two sequential proxied round trips and flashes the global busy indicator every minute, even when idle

**Impact low · effort S · polling · reviewer (confidence 0.85)**

- **Where:** index.html:1608-1640 (broadcastTick), 1642 (setInterval), 1644 (visibilitychange), 2009-2016 (_netBusy), CSS 240-249 (#net-bar / #busy-cursor animations)
- **Evidence:** `setInterval(broadcastTick, BCAST_POLL_MS);` (1642, 60 s). broadcastTick awaits `api('user_presence', 'PATCH', ...)` then possibly a POST, then `apiGet('broadcasts', ...)` (1613-1621) — sequential. Every api() call runs `_netBusy(true)` which does `bar.classList.add('on'); document.body.classList.add('net-busy');` (2013), turning on the red top progress bar (`#net-bar::before ... animation:net-bar-slide 1.05s ... infinite`, CSS 242) and the spinning `#busy-cursor` (CSS 249) for the duration of both round trips (~1.4 s each per the loadTable comment at 3552-3553).
- **Mechanism:** Two sequential proxied round trips (2-3 s of network) per user per minute, plus an infinite CSS animation with box-shadow running during that window. The animations are cheap, but the user sees the app 'working' for ~3 s out of every 60 while doing nothing, which reads as sluggishness. Also two extra proxied calls per minute per session on the Netlify function.
- **Who feels it:** Every logged-in user, continuously: periodic busy-bar/cursor flashes while idle; small extra function load.

- **Fix:** (1) Collapse into one call: `CREATE FUNCTION heartbeat(p_person_id bigint, p_app_version text) RETURNS SETOF broadcasts LANGUAGE sql SECURITY DEFINER AS $$ INSERT INTO user_presence(person_id,last_seen_at,app_version) VALUES (p_person_id, now(), p_app_version) ON CONFLICT (person_id) DO UPDATE SET last_seen_at = excluded.last_seen_at, app_version = excluded.app_version; SELECT * FROM broadcasts WHERE ended_at IS NULL AND expires_at > now() ORDER BY created_at DESC; $$;` and call `api('rpc/heartbeat','POST',{...})` (the sb.js proxy just forwards the path). (2) Add a `silent` option to api() that skips `_netBusy` for background calls: `async function api(table, method, body, params, opts={}) { if (!opts.silent) _netBusy(true); ... finally { if (!opts.silent) _netBusy(false); } }`. (3) Lengthen the interval to 120-180 s (BCAST_ACTIVE_MIN is 3 minutes, so a 90-120 s beat still counts as active).

### CPU-11 — Edit-grace countdown ticker is bounded and self-stopping, but a list chip expiring triggers a full renderLeadsPage() network reload

**Impact low · effort S · client cpu · reviewer (confidence 0.85)**

- **Where:** index.html:23593-23616 (startEditCountdownTicker/tickEditCountdowns), 23599 (offsetParent read), 23615 (renderLeadsPage on expiry), 15025-15028 (chip emitted per Working lead row)
- **Evidence:** `function startEditCountdownTicker() { if (!_editCdTimer) _editCdTimer = setInterval(tickEditCountdowns, 1000); }` (23593); each tick does `const els = [...document.querySelectorAll('.edit-cd')].filter(el => el.offsetParent !== null);` (23599) then writes textContent/style per chip (23605-23607); `if (!els.length) { stopEditCountdownTicker(); return; }` (23600) so it stops when no chip is visible. On expiry of a list chip: `else if (listExpired && currentPage === 'leads') renderLeadsPage();` (23615) which re-runs the full 9-GET load plus sweeps (14727-14746).
- **Mechanism:** Per tick: one forced layout (offsetParent reads are batched before writes, so no thrash) and a handful of DOM writes — negligible. The expiry path, however, refetches the whole register from the network and rebuilds it while the user may be mid-scroll/click; if several Working leads were created in the same window their chips expire seconds apart, causing repeated full reloads.
- **Who feels it:** Leads register while any Working lead is inside its edit grace: negligible per-second cost; an unexpected full-page reload (several seconds, list jumps) each time a grace window ends.

- **Fix:** On expiry, update in memory and re-render locally: mark the lead's grace as expired in the current `_tableState['leads-'+leadsViewTab].rows` (set a flag or working_at check) and call `_renderTable('leads-' + leadsViewTab)`; or simply swap the chip to its expired label (already done at 23605) and remove the row's red inset border via a class toggle, deferring the refetch to the next navigation. Keep the ticker as is.

### CPU-12 — Global mousemove handlers and the busy cursor are negligible; no change needed beyond an optional tweak

**Impact low · effort S · dom render · reviewer (confidence 0.9)**

- **Where:** index.html:2023-2027 (_positionBusyCursor + mousemove), 2254-2257 (second mousemove), 6333-6350 (_pbBindTip mousemove), CSS 248-249 (#busy-cursor)
- **Evidence:** `document.addEventListener('mousemove', (e) => _positionBusyCursor(e.clientX, e.clientY), { passive: true });` (2027) -> `el.style.left = x + 'px'; el.style.top = y + 'px';` (2025) on `#busy-cursor`, which is `position:fixed; ... opacity:0` (CSS 248) and only animated under `body.net-busy`/`body.click-busy` (249). The second listener only stores coordinates (2255-2256). _pbBindTip is bound once (`window._pbTipBound`, 6334-6335) and exits early unless the target is inside `.pb-allow-row[data-help]` (6337-6338).
- **Mechanism:** Per mouse move: one getElementById and two style writes on a 25 px out-of-flow element -> a layout of that element only, well under 0.1 ms; ~60-120 events/s while the mouse moves. Runs for the life of the tab but does not accumulate work or memory.
- **Who feels it:** None measurable.

- **Fix:** Optional: only position while busy (`if (!_netCount && !_clickCursorTimer) return;`) and use `el.style.transform = 'translate(' + x + 'px,' + y + 'px)'` to keep it compositor-only. Not worth prioritising.

### CPU-13 — `transition:all` on buttons/tabs/nav items (thousands of .btn instances in admin lists) is a minor style-recalc cost

**Impact low · effort S · dom render · reviewer (confidence 0.6)**

- **Where:** index.html CSS: 98 (.btn), 78 (.nav-item), 66 (.nav-subsection), 378 (.opp-tab), 422 (.rev-fy-tab), 23214 (inline transition:all on qualification buttons); button-heavy rows at 3613-3633
- **Evidence:** `.btn{...transition:all 0.15s;...}` (98). loadTable's rowRenderer emits 2-4 `.btn` elements per row (Contacts/Profile/Reset/Edit/Delete, 3613-3633), so a 2,000-row People/Clients list contains 4,000-8,000 elements with `transition:all`. No universal-selector transitions, no filter/backdrop-filter, and box-shadow is confined to cards/popups (77, 125-131, 282 etc.); sticky headers sit inside the `.content` scroll container by design (CSS 122-124, 328, 342).
- **Mechanism:** `transition:all` makes the engine track every animatable property on each of those elements at style-recalc time (hover, class flips, innerHTML replacement). Cost is small per element; only relevant on very large unpaginated admin lists, where CPU-3 dominates anyway.
- **Who feels it:** Negligible to low; slightly heavier style recalculation on large admin lists.

- **Fix:** `.btn{transition:background-color .15s,color .15s,border-color .15s}` (and the same explicit property lists for .nav-item/.opp-tab/.rev-fy-tab). Harmless, one-line, but do it after CPU-3.

### CPU-8 — agingDaysFor JSON.parses the lead_aging_overrides setting for every rendered lead row and band row

**Impact low · effort S · client cpu · reviewer (confidence 0.9)**

- **Where:** index.html:12120-12125 (_agingOverrides), 12127-12133 (agingDaysFor), callers 15020 (renderLeadRow) and 15116 (_leadBandRowHtml)
- **Evidence:** `const o = JSON.parse((typeof appSettings !== 'undefined' && appSettings['lead_aging_overrides']) || '{}');` (12122) is executed by `const ov = _agingOverrides()[String(personId)] || {};` (12128) which renderLeadRow calls per row via `const limit = kind ? agingDaysFor(l.owner_id, kind) : 0;` (15020) and _leadBandRowHtml per band (15116).
- **Mechanism:** One JSON.parse of the overrides string per row per render (and per sort/filter/band click). Small object, ~5-20 us each: 2,000 rows -> 10-40 ms. Real but secondary to CPU-1.
- **Who feels it:** Leads register: a few tens of ms per render; not individually noticeable but adds to the per-click stall.

- **Fix:** Memoise on the raw setting string: `let _agingCache = { src: null, obj: {} }; function _agingOverrides(){ const raw = (typeof appSettings !== 'undefined' && appSettings['lead_aging_overrides']) || '{}'; if (raw !== _agingCache.src) { let o = {}; try { o = JSON.parse(raw) || {}; } catch (e) {} _agingCache = { src: raw, obj: (o && typeof o === 'object') ? o : {} }; } return _agingCache.obj; }`.

### CPU-9 — Per-row `new Date(...).toLocaleDateString('en-ZA')` creates an Intl formatter per call in list renderers

**Impact low · effort S · client cpu · reviewer (confidence 0.8)**

- **Where:** index.html:14992, 15008 (renderLeadRow), 15093, 15108 (_leadBandRowHtml), 11857, 11929 (opportunities rows/bands), 2909 (generic 'Created' column), 14605, 15284, 16947, 25185, 9113, 9152
- **Evidence:** `const dateLabel = l.next_action_date ? new Date(l.next_action_date).toLocaleDateString('en-ZA') : '';` (14992) and `Promoted ${new Date(l.promoted_at).toLocaleDateString('en-ZA')}` (15008) run per lead row; `<td>${d.order_date ? new Date(d.order_date).toLocaleDateString('en-ZA') : '—'}</td>` (11857) per deal row; `render: v => v ? new Date(v).toLocaleDateString('en-ZA') : ''` (2909) per generic row.
- **Mechanism:** Each toLocaleDateString(locale) call constructs and resolves an Intl.DateTimeFormat (V8 caches partially but still costs ~20-60 us). 2,000 rows x 1-2 calls -> 40-200 ms per render, repeated on every sort/filter/band click.
- **Who feels it:** All registers: adds tens to low hundreds of ms per render; only noticeable in combination with CPU-1/CPU-3.

- **Fix:** One shared formatter: `const _fmtZA = new Intl.DateTimeFormat('en-ZA'); function fmtDateZA(v){ if (!v) return ''; const d = v instanceof Date ? v : new Date(v); return isNaN(d) ? '' : _fmtZA.format(d); }` and replace the per-row calls (about 10x faster).


## Page weight, proxy and infrastructure, polling

### INF-1 — Every data call makes two long-haul legs: South Africa -> US-hosted Lambda -> (cross-Atlantic) Supabase; the function region is unpinned

**Impact high · effort M · proxy infra · reviewer (confidence 0.75)**

- **Where:** /home/user/Focus/netlify.toml (no [functions] region; only build command and functions dir at :2-8); /home/user/Focus/netlify/functions/sb.js:5 (SUPABASE_HOST), :8 ('every proxied query opened a fresh cross-Atlantic TLS handshake'), :11 (keep-alive agent), :284-296 (upstream request); /home/user/Focus/index.html:1660 (FN_URL='/.netlify/functions/sb'), :3546 ('~1.4s proxied round-trip')
- **Evidence:** netlify.toml sets no functions region, so sb.js runs in Netlify's default AWS region (us-east-2 for sites created since 2023, us-east-1 earlier - visible under Site configuration -> Build & deploy -> Functions -> Region). The comment at sb.js:8 records that the function-to-Supabase leg is cross-Atlantic, which means the Supabase project is not co-located with the function (most likely an EU region; confirm in Supabase dashboard -> Project Settings -> General -> Region). Users are in South Africa (CLAUDE.md). So each of the 700+ proxied call sites pays ZA->US (~180-220 ms RTT) plus US->EU (~80-100 ms RTT) plus Lambda dispatch, and the app's own comments measure 0.6-1.4 s per call. Sequential chains of 5-9 such calls (login, page loads) are where the user-visible seconds come from.
- **Mechanism:** extra network hop / geography per request (one Lambda invocation per apiGet, two transcontinental legs) - the fixed per-call floor that every sequential round trip in every other finding is multiplied by
- **Who feels it:** Every user, every click that touches data: a ~0.6-1.4 s floor per call regardless of query cost; pages with 5-9 sequential calls feel like 5-10 s.

- **Fix:** Quick (S): read the Supabase project region from the dashboard and set Netlify's Functions region to the matching AWS region (Netlify UI, Site configuration -> Functions -> Region; not expressible in netlify.toml) so the function sits next to the database and the second long-haul leg disappears (~100-200 ms per call, plus cheaper cold TLS handshakes). Structural (L): remove the hop entirely by calling PostgREST directly from the browser with the anon key + RLS: enable RLS on every table, add policies keyed on a JWT claim (Supabase Auth, or keep the existing username/password by having the sb function mint a Supabase-signed JWT with `person_id` as a custom claim instead of the current v1 HMAC token), keep sb.js only for /auth and for the credential-scrubbing system_users read, and point api() at `https://kevrfdjqyuhmgziqxuvs.supabase.co/rest/v1/`. That gives HTTP/2 multiplexing to one host, gzip from Supabase's edge, no Lambda cold starts, no invocation cost, and PostgREST count headers for free; the audit trigger's actor comes from `request.jwt.claims` instead of `request.headers`. Netlify Edge Functions (Deno, nearest-edge) would shorten the browser->function leg for ZA users but keep the function->DB leg, so prefer region pinning or direct access.

### INF-2 — One Lambda invocation per apiGet turns parallel fan-outs into cold-start storms and forces the client to throttle its own parallelism

**Impact high · effort M · proxy infra · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/netlify/functions/sb.js:248-321 (one upstream request per invocation, agent at :11 is per-instance); /home/user/Focus/index.html:2188-2197 (preloadLookups CONCURRENCY=4 'to stay gentle on the proxy'), :27537 (saveSettings Promise.all of 16 calls), :17954 (initLeadForm 10), :14727 (renderLeadsPage 9), :15568 (renderResearchCampaignCockpit 9), :13562 (deleteMilestoneRow 9), :5499 (initOppForm 8); :1984-1990 (comment: 'under cold-start/concurrency it intermittently times out')
- **Evidence:** AWS Lambda serves one request per instance at a time, so a Promise.all of 9 apiGets (renderLeadsPage 14727) needs 9 warm instances or spawns cold ones; each cold instance has an empty sbAgent (sb.js:11) and must do a fresh TLS handshake to Supabase (sb.js:8). The app has already worked around this twice: preloadLookups (2190) caps parallelism at 4 so the 9 lookup tables take 3 sequential rounds instead of 1, and api() grew a 3-attempt retry (1984-1992) because parallel bursts 'intermittently time out'. 53 Promise.all sites exist.
- **Mechanism:** per-request Lambda invocation: parallel calls cost N cold starts + N TLS handshakes instead of one; client-side throttling converts parallel calls back into sequential rounds
- **Who feels it:** First user of the morning and anyone opening a page after a quiet spell: page loads that fan out 8-16 calls hit cold starts (hundreds of ms each) and occasional 502/timeouts that trigger 12 s waits and retries; login lookups take 3 rounds instead of 1.

- **Fix:** Add a batch route to sb.js: `POST /.netlify/functions/sb/batch` with body `{requests:[{table:'people',params:'select=*'},{table:'regions',params:'select=*'}]}`; the handler validates the token once, runs `Promise.all(requests.map(r => sbRest(KEY,'GET','/'+r.table+'?'+r.params, null, actorHeaders)))` over the single keep-alive agent and returns `[rows,...]` (with per-item status). Client: `async function apiBatch(reqs){ const out = await fetchJson(FN_URL+'/batch',{method:'POST',body:JSON.stringify({requests:reqs})}); return out; }` and rewrite preloadLookups + the big Promise.all fan-outs (renderLeadsPage, initLeadForm, initOppForm, saveSettings reads) to a single apiBatch call: one browser round trip, one Lambda invocation, 8-16 upstream requests in parallel over warm sockets. Also raise CONCURRENCY at 2190 or drop the chunking once batching exists. Longer term this is subsumed by INF-1's direct-PostgREST option (HTTP/2 to PostgREST handles parallel requests natively).

### PW-1 — Three base64 PNGs are 50% of every page download and are 7-8x larger than their rendered size

**Impact high · effort S · payload · spot-checked (confidence 0.95)**

- **Where:** /home/user/Focus/index.html:25 (--focus-wordmark, 325,139 B line), :26 (--focus-logo-white, 156,677 B line), :682 (<img> in .sidebar-logo, 87,437 B line); rendered at :635 (178x200), :695 (159px wide) and :55 (.sidebar-logo img{height:48px})
- **Evidence:** Decoded with python3: line 25 = 243,814 B, 1295x1467 px RGBA (colortype 6); line 26 = 117,468 B, 1295x1467 px palette; line 682 = 65,486 B, 763x192 px RGBA. Together 569 KB raw of a 2,218,069 B file, and because base64 does not compress they are 423,076 B of the 848,675 B gzip transfer (49.9%); the real CSS is only 56,235 B (12,840 B gz). Re-encoded with Pillow at 2x the rendered size: line 25 at 356x403 = 64,242 B PNG (15,494 B at 64 colours, 35,382 B lossless WebP); line 26 at 318x360 = 29,632 B (7,049 B / 20,164 B); line 682 at 382x96 = 24,924 B (3,922 B / 16,628 B). The wordmark/logo live inside CSS custom properties (line 25-26) in the render-blocking <style> (lines 16-625), so 481 KB must arrive and be tokenised before the login screen can paint, and the 1295x1467 bitmaps (~7.6 MB RGBA each) are decoded every load to draw a 178 px logo. icons/ already holds real files (favicon-48.png 1,365 B, icon-512.png 16,319 B); none of the three embedded PNGs exists as a file.
- **Mechanism:** over-fetch bytes on every load (incompressible base64 in the critical render-blocking <style>), plus decode of 3.9 Mpx of bitmap for ~0.1 Mpx of screen
- **Who feels it:** Every user, every cold load and every 'new version available' reload (41 version bumps in the 17-day git history = ~2.4 forced reloads/day): ~420 KB of the ~850 KB transfer and a delayed first paint of the login screen; worse on mobile/4G.

- **Fix:** Export the three images as files at 2x rendered size (e.g. icons/wordmark-356.png ~64 KB or ~15 KB at 64 colours, icons/logo-white-318.png ~30 KB, icons/sidebar-logo-382.png ~25 KB; WebP with PNG fallback if preferred) and reference them by URL: in CSS `--focus-wordmark:url(/icons/wordmark-356.png)`, `--focus-logo-white:url(/icons/logo-white-318.png)`, and `<img src="/icons/sidebar-logo-382.png" width="191" height="48" decoding="async">` at line 682. Also drop the 5.3 KB .xone-sprite data URI at line 214 and the 6.7 KB svg at line 634 to files. Result: index.html falls from 2.22 MB to ~1.65 MB raw and the gzip transfer from ~849 KB to ~430 KB; the images are fetched in parallel, off the critical path, with the browser decoding a 0.14-Mpx image instead of 1.9 Mpx. (Note: the fact that separate files would also be HTTP-cacheable is a browser-cache benefit and is OUTSIDE the user's constraint; the gain claimed here is purely per-load bytes and paint timing.)

### INF-3 — No compression on either hop of the proxy and the whole body is buffered as a string

**Impact medium · effort S · proxy infra · spot-checked (confidence 0.7)**

- **Where:** /home/user/Focus/netlify/functions/sb.js:284-296 (upstream request headers: no Accept-Encoding), :298 (`let d=''; res.on('data', c => d += c)`), :299-303 (response returned with only Content-Type + CORS, no Content-Encoding), :119-129 (scrubCredentials JSON.parse/stringify)
- **Evidence:** Node's https.request sends no Accept-Encoding unless told to, so PostgREST returns raw JSON to the function; the function returns that string verbatim with `headers: { 'Content-Type': 'application/json', ...CORS }`. Netlify does not compress Lambda function responses on the CDN (to my knowledge it only compresses static assets; functions must set Content-Encoding themselves) - verify with `curl -sS -o /dev/null -D - -H 'Accept-Encoding: gzip, br' -H 'X-Focus-Token: <token from localStorage focus_session>' 'https://storied-griffin-6eab6b.netlify.app/.netlify/functions/sb/people?select=*&limit=1000'` and look for a `content-encoding:` line (compare the same query with `curl -w '%{size_download}'`). apiGetAll (2122) pulls 1000-row pages with select=* for people/organisations/sites/leads/deals; JSON row arrays typically compress 5-10x, so a 500 KB page travels as 500 KB across two continents twice per hop instead of ~60-100 KB. Netlify sync functions also cap the response at 6 MB, which an uncompressed 1000-row select=* page of a wide table (leads has jsonb contacts and description threads) can approach.
- **Mechanism:** over-fetch bytes on both network legs of every proxied call; string concatenation and JSON re-serialisation per response
- **Who feels it:** Every list page and every login preload: transfer time proportional to raw JSON size on the slowest leg (ZA), roughly 0.2-0.5 s extra per 500 KB page on a 10-20 Mbps link; larger for the leads/engagements tables as they grow.

- **Fix:** In sb.js request upstream with `headers: {..., 'Accept-Encoding': 'gzip'}`, collect the body as Buffers (`const chunks=[]; res.on('data', c => chunks.push(c)); const buf = Buffer.concat(chunks)`), and if `res.headers['content-encoding']==='gzip'` return `{ statusCode, headers: { 'Content-Type':'application/json','Content-Encoding':'gzip', 'Vary':'Accept-Encoding', ...CORS }, body: buf.toString('base64'), isBase64Encoded: true }` (decompress with zlib.gunzipSync only for the system_users scrub path). This compresses both legs with no client change (fetch decodes gzip transparently). Pair with narrower select lists (other slices).

### INF-4 — Proxy discards PostgREST Content-Range/count headers and does not forward Range, so the client can never count server-side or bound a page cheaply

**Impact medium · effort S · proxy infra · spot-checked (confidence 0.85)**

- **Where:** /home/user/Focus/netlify/functions/sb.js:291-296 (only Content-Type, apikey, Authorization, Prefer, X-Actor-Id, X-Real-Actor-Id are forwarded upstream), :299-303 (response headers rebuilt as Content-Type + CORS only, `Access-Control-Expose-Headers` absent); /home/user/Focus/index.html:2122-2132 (apiGetAll pages blindly by limit/offset until a short page)
- **Evidence:** grep for `count=`, `Content-Range`, `Range` in index.html returns nothing: the app has no way to use `Prefer: count=exact` (the header would reach PostgREST via `prefer` but the resulting `Content-Range: 0-999/12345` is dropped at sb.js:301). Consequently every KPI/count in dashboards must fetch the rows, apiGetAll cannot know the total up front (and pays one extra empty round trip whenever a table has an exact multiple of 1000 rows), and `Range: 0-0` + `Prefer: count=exact` (a ~100-byte response that answers 'how many leads in status X') is unavailable.
- **Mechanism:** proxy strips metadata -> forces over-fetch (whole tables to count) and blind pagination
- **Who feels it:** Enabler for the dashboard/list slices: without it every count widget is a full-table download through the slow hop.

- **Fix:** In sb.js forward `range`, `range-unit` and `accept` from event.headers to the upstream request, and copy `content-range` (plus `content-encoding` per INF-3) from `res.headers` into the returned headers together with `'Access-Control-Expose-Headers': 'Content-Range'`. Client: `async function apiCount(table, params){ const r = await fetch(`${FN_URL}/${table}?${params}&limit=1`, {headers:{...tokenHeaders, 'Prefer':'count=exact', 'Range-Unit':'items','Range':'0-0'}}); return +r.headers.get('Content-Range').split('/')[1]; }` and let apiGetAll read the total from the first page's Content-Range to issue the remaining pages in parallel instead of serially.

### POLL-1 — Presence/broadcast heartbeat costs 120 proxied calls (60 DB writes) per user-hour, two sequential calls per tick, and fires again on every tab refocus

**Impact medium · effort S · polling · spot-checked (confidence 0.9)**

- **Where:** /home/user/Focus/index.html:1591 (BCAST_POLL_MS = 60*1000), :1607-1640 (broadcastTick), :1612 (PATCH user_presence with return=representation), :1613 (POST fallback), :1617-1618 (GET broadcasts awaited after the PATCH), :1642-1644 (setInterval + visibilitychange), :1580-1582 (checkAppVersion every 15 min + visibilitychange)
- **Evidence:** Each minute every open tab does `api('user_presence','PATCH', beat, 'person_id=eq.N&select=person_id')` (a Postgres UPDATE + representation response) and then, sequentially, `apiGet('broadcasts', 'ended_at=is.null&expires_at=gt.<now>&select=*&order=created_at.desc')`; both are separate Lambda invocations (INF-2) and both run whether or not the tab is visible (setInterval only, no document.hidden check), and again on every visibilitychange. user_presence is not in the audit list (sql/add_audit_log.sql:74-80) so no audit_log row per beat, but sql/add_broadcasts.sql is absent from the repo so a person_id index/PK cannot be confirmed. Assuming ~8 users x 8 h x 22 working days: ~170,000 invocations/month and ~85,000 UPDATEs/month purely for 'who is online', competing with real page loads for warm Lambda instances. checkAppVersion is a cheap static fetch (4/h) but also fires on every refocus.
- **Mechanism:** polling: 2 sequential Lambda invocations + 1 row write per minute per tab, plus refocus bursts
- **Who feels it:** Indirect but continuous: background invocations keep the per-site Lambda concurrency busy and contend with foreground page loads; each beat is a write on the same Postgres the pages are reading; on a tab refocus the user's first click competes with 3 background calls.

- **Fix:** Collapse the tick into ONE RPC and slow it down. SQL: `create or replace function heartbeat(p_person_id bigint, p_version text) returns setof broadcasts language sql security definer as $$ insert into user_presence(person_id,last_seen_at,app_version) values (p_person_id, now(), p_version) on conflict (person_id) do update set last_seen_at = excluded.last_seen_at, app_version = excluded.app_version; select * from broadcasts where ended_at is null and expires_at > now() order by created_at desc; $$;` (needs `unique (person_id)` on user_presence). Client: replace lines 1610-1618 with `const live = await api('rpc/heartbeat','POST',{p_person_id: currentUser.personId, p_version: _bcastAppVersion()})` (sb.js already proxies any /rest/v1 path, so /rpc/heartbeat needs no proxy change). Then set BCAST_POLL_MS to 5 min (and BCAST_ACTIVE_MIN to 15) and guard the tick with `if (document.hidden) return;` plus a `_lastBeat` timestamp so visibilitychange only re-fires when >60 s have passed. Net: 120 calls/h -> 12 calls/h per user, zero sequential depth.

### PW-2 — Unminified 1.52 MB inline script: minification alone removes 39% of the JS transfer; deploy churn forces ~2.4 full reloads per user per day

**Impact medium · effort M · payload · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:1494-28145 (single <script>); /home/user/Focus/netlify.toml:2-8 (build command is only a sed stamp + version.txt, no minify/bundle step); /home/user/Focus/index.html:1558-1582 (checkAppVersion banner)
- **Evidence:** JS section = 1,523,764 B raw, 391,841 B gzip. 247,885 B of that is `//` comment lines. Running `npx terser@5 --compress --mangle` on the extracted script produced 1,004,754 B (-34%), which gzips to 237,404 B (-39%, i.e. -154 KB per load). V8 compile measured with node 22 `new vm.Script`: 15 ms (lazy) and 47 ms with --no-lazy for the raw script vs 38 ms minified, so parse/compile is a ~100-200 ms cost on a typical laptop, not seconds; the bytes are the bigger cost. `git log -p` shows 41 distinct `FOCUS vX.Y.Z` stamps between 2026-08-23 and 2026-09-09 (51 commits in 17 days), and checkAppVersion (1558) shows the click-to-refresh banner within 15 min of every deploy, so each user re-downloads and re-parses the whole bundle ~2.4x/day and then re-runs the entire enterApp fetch cascade.
- **Mechanism:** over-fetch bytes (unminified source + comments) on every load, multiplied by deploy frequency
- **Who feels it:** Every user on every load and on every forced post-deploy reload: ~154 KB extra transfer and ~10-30% extra parse time; on the office/mobile links in South Africa that is roughly 0.3-1 s per reload.

- **Fix:** Add a real build step to netlify.toml that keeps the single-file dev workflow but ships a minified bundle: e.g. `command = "node build.js"` where build.js splits index.html at the <style>/<script> boundaries, runs esbuild (`npx esbuild app.js --minify --target=es2020 --outfile=dist/app.js`, esbuild handles 1.5 MB in <1 s) and csso on the CSS, writes dist/index.html with `<link rel=stylesheet href=/app.css>` and `<script src=/app.js defer>`, and sets `publish = "dist"`. Keep the sed stamp and version.txt. Batch releases (e.g. one deploy per day) so the version banner fires once a day instead of 2-3 times. (HTTP cache headers for /app.js would be a further win but rely on the browser cache, which is outside the constraint - not counted here.)

### PW-3 — ~470 KB of admin/quote-builder/wizard/help code (~130 KB gz, a third of the JS) is parsed on every load but rarely executed

**Impact medium · effort L · payload · reviewer (confidence 0.7)**

- **Where:** /home/user/Focus/index.html:5737-8769 (Proposal Builder + Statutory Salary grid + Allowances + HR admin), :12864-14197 (Dashboards/Broadcasts/Milestones/Deal-admin/Audit-log/Bug-reports admin), :27203-28128 (Settings/Merge/Roles/Regions/Party-type/Home-org managers), :21243-22951 (Promote wizard + revenue seeding), :4336-4500 and :15374-15741 (help drawer + Campaign Setup Guide text), :1692-1984 (mock mode)
- **Evidence:** Measured section sizes (raw / gzip): Proposal Builder + salary/allowance grids + HR admin 177,766 / 45,094 B; admin settings pages 82,919 / 23,302 B; Settings/Merge/Roles/... 52,370 / 12,191 B; Promote wizard 92,421 / 24,249 B; help text 52,340 / 17,866 B; mock mode 15,684 / 4,512 B. Total ~473 KB raw / ~127 KB gz of the 1,524 KB / 392 KB script. local_preview.js:32-37 already extracts the salary grid module from index.html by string markers, proving these sections are self-contained enough to split.
- **Mechanism:** bundle bytes and parse/compile work on every load for code most sessions never run (the admin pages are Admin-only, the Proposal Builder is a tab on one page, the wizard runs once per promotion)
- **Who feels it:** Every user on every load pays ~127 KB gz transfer and the parse of ~470 KB of source for features they may open once a week or never.

- **Fix:** Move each of those sections into its own file (quote-builder.js, admin.js, promote.js, help.js, mock.js) and load on demand with a tiny loader that injects a <script> and awaits its load before the first call, e.g. `const _mods={}; function needModule(name){ return _mods[name] ||= new Promise((res,rej)=>{ const s=document.createElement('script'); s.src='/'+name+'.js?v='+APP_BUILD; s.onload=res; s.onerror=rej; document.head.appendChild(s); }); }` and in showPage/loadTable: `if (cfg.module) await needModule(cfg.module)` (page config at 2583-3311 already has a per-page cfg object to hang the module name on). Because functions are globals referenced from onclick strings, plain script injection keeps that working. Combine with PW-2's build step so the split files are also minified.

### INF-5 — Client timeout (12 s) exceeds Netlify's 10 s function timeout, and 3 retries with no concurrency cap triple proxy load exactly when it is saturated

**Impact low · effort S · proxy infra · reviewer (confidence 0.7)**

- **Where:** /home/user/Focus/index.html:1991 (API_TIMEOUT_MS = 12000), :1992 (API_GET_RETRIES = 3), :1995-1998 (backoff 400/800 ms), :2063-2113 (attempt loop, retry on 502/503/504/AbortError); /home/user/Focus/netlify/functions/sb.js:305-315 (server-side GET retry once on stale socket)
- **Evidence:** Netlify synchronous functions time out at 10 s by default (26 s only if raised), so a slow upstream query returns a 502 from Netlify at 10 s; the client then backs off 400-800 ms and repeats up to 3 times, i.e. a single hung GET can hold the user for ~31 s and multiply the invocation count 3x. There is no in-flight cap in api(), so a page's Promise.all of 9-16 calls (INF-2) retrying together re-creates the same burst that caused the cold-start timeouts the retry was added for (comment at 1984-1990).
- **Mechanism:** retry amplification under proxy saturation; mismatched timeouts
- **Who feels it:** During cold-start bursts (first load of the day, after deploys - 2-3 per day): pages stall for tens of seconds instead of failing fast, and the retries keep the proxy saturated for everyone else.

- **Fix:** Set API_TIMEOUT_MS to 8000 (below Netlify's 10 s so the client aborts first), API_GET_RETRIES to 2, and add a small in-flight limiter in api() (e.g. `const _sem = { n: 0, q: [] }` allowing 6 concurrent fetches) so fan-outs queue instead of spawning 16 Lambdas; once INF-2's batch route exists the limiter is rarely hit. Consider raising the function timeout to 15 s in netlify.toml `[functions.sb] timeout` only if a specific query needs it.

### POLL-2 — 1-second countdown ticker forces a synchronous layout per chip every second while a leads or engagement list is open

**Impact low · effort S · client cpu · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/index.html:23593 (setInterval(tickEditCountdowns, 1000)), :23595-23617 (tickEditCountdowns: querySelectorAll('.edit-cd') then `el.offsetParent !== null` per chip, then text/style writes per chip, then renderLeadsPage() on any expiry), chips emitted per row at :15028 (leads list) and :9096 (engagement list)
- **Evidence:** `[...document.querySelectorAll('.edit-cd')].filter(el => el.offsetParent !== null)` reads layout for every chip and then writes textContent/style for every chip, interleaving reads and writes each second; with N chips in a list that is N forced reflows per second on a page whose table is rebuilt by innerHTML. The ticker runs for as long as any chip is visible, i.e. the entire time a Working lead sits in the list, and `if (listExpired && currentPage === 'leads') renderLeadsPage()` (23616) triggers a full page re-render (with its 9-call Promise.all at 14727) when one chip hits zero.
- **Mechanism:** client CPU / DOM: read-write layout thrash on a 1 s timer
- **Who feels it:** Anyone with the Leads page or an engagement list open: a steady main-thread tick that competes with typing and scrolling on larger lists, and a full page reload-from-server when a lead's grace expires.

- **Fix:** Do one visibility read, not one per chip: `const page = document.getElementById('leads-page'); if (!page || page.offsetParent === null) ...` (or track visibility via the existing currentPage/overlay state), and batch DOM writes: only rewrite a chip when its displayed value changes (remain > 60 s changes once a minute), which lets the interval run at 1000 ms but touch the DOM ~1/60th as often; on expiry update just that row's chip/lock state instead of calling renderLeadsPage().


## Database indexes

### IDX-00 — Summary: one ready-to-run index migration (sql/add_perf_indexes.sql) covering every finding above

**Impact medium · effort M · db index · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/sql/ (new file); applies to engagements, leads, deals, person_organisation_roles, organisations, audit_log, system_users, plus guarded blocks for out-of-repo tables
- **Evidence:** Full index inventory across sql/ (grep -i 'create (unique )?index'): ~55 indexes exist, but on the core business tables only PKs/UNIQUEs plus idx_engagements_lead, 5 leads indexes, 3 deals lineage indexes and 3 audit_log indexes. Postgres does not auto-index FK columns; fk_columns.txt lists 61 FK columns of which the ones on the hot paths (engagements.deal_id, leads.promoted_deal_id/target_org_id/site_id, person_organisation_roles.org_id, deals.org_id, engagements.related_interaction_id) are unindexed. Already-covered predicates that need NO new index: revenue_streams deal_id=eq/in (UNIQUE(deal_id,stream_type)), revenue_stream_months stream_id=eq/in and the PostgREST embed join (UNIQUE(stream_id,month)), engagement_people/deal_collaborators/deal_contacts deal_id/engagement_id (UNIQUE pairs), promotion_requests, lead_stage_events, lead_contacts, lead_description_log, campaign_targets, quote_* tables, system_user_regions/branches.
- **Mechanism:** Turns the sequential scans, top-N sorts and per-row FK cascade scans listed in IDX-01..IDX-11 into index probes; removes four indexes that only cost writes.
- **Who feels it:** All users: dashboard load, deal open, lead open, engagement save, Engagement History; admins: audit page, deletes/merges. Honest sizing: DB time is a small slice of each ~1.4 s proxied round trip while tables are in the low thousands of rows, so this migration is cheap insurance that prevents the DB from becoming the bottleneck as engagements/audit_log grow — it will not by itself remove the round-trip latency users feel.

- **Fix:**

```sql
-- sql/add_perf_indexes.sql  (Focus CRM, 2026-09)
-- RUN STATEMENT-BY-STATEMENT in the Supabase SQL editor or psql (NO BEGIN/COMMIT:
-- CREATE/DROP INDEX CONCURRENTLY cannot run inside a transaction block). Idempotent.
-- A statement that fails with 'column … does not exist' means that DB lacks the
-- out-of-repo migration for that column — skip it there.

-- ── engagements (largest business table) ─────────────────────────────────────
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_deal_date_idx
  ON public.engagements (deal_id, engagement_date DESC, id DESC)
  WHERE deal_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_lead_date_idx
  ON public.engagements (lead_id, engagement_date DESC, id DESC)
  WHERE lead_id IS NOT NULL;
DROP INDEX CONCURRENTLY IF EXISTS public.idx_engagements_lead;   -- superseded by the composite

CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_date_id_idx
  ON public.engagements (engagement_date, id);

CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_open_actions_idx
  ON public.engagements (next_action_date, id)
  WHERE next_action_done = false AND next_action_date IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_org_date_idx
  ON public.engagements (org_id, engagement_date DESC)
  WHERE org_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_work_project_idx
  ON public.engagements (work_project_id)
  WHERE work_project_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_related_interaction_idx
  ON public.engagements (related_interaction_id)
  WHERE related_interaction_id IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_stream_idx
  ON public.engagements (stream_id)
  WHERE stream_id IS NOT NULL;

-- ── leads ─────────────────────────────────────────────────────────────────────
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_promoted_deal_idx
  ON public.leads (promoted_deal_id) WHERE promoted_deal_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_target_org_idx
  ON public.leads (target_org_id) WHERE target_org_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_site_idx
  ON public.leads (site_id) WHERE site_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_source_org_idx
  ON public.leads (source_org_id) WHERE source_org_id IS NOT NULL;
-- orgs_link_freetext_leads trigger probe (fires on every organisation insert / rename)
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_unlinked_org_name_idx
  ON public.leads (lower(trim(target_org_name)))
  WHERE target_org_id IS NULL AND target_org_name IS NOT NULL;
-- Never used by a client predicate; next_action_date is rewritten by
-- refresh_lead_next_action on every engagement write.
DROP INDEX CONCURRENTLY IF EXISTS public.idx_leads_next_action_date;
DROP INDEX CONCURRENTLY IF EXISTS public.idx_leads_status;

-- ── deals / organisations ─────────────────────────────────────────────────────
CREATE INDEX CONCURRENTLY IF NOT EXISTS deals_org_idx ON public.deals (org_id);
DROP INDEX CONCURRENTLY IF EXISTS public.deals_opportunity_type_idx;   -- 3 values, only used with parent_deal_id
CREATE INDEX CONCURRENTLY IF NOT EXISTS organisations_parent_org_idx
  ON public.organisations (parent_org_id) WHERE parent_org_id IS NOT NULL;

-- ── person_organisation_roles ────────────────────────────────────────────────
CREATE INDEX CONCURRENTLY IF NOT EXISTS person_organisation_roles_org_idx
  ON public.person_organisation_roles (org_id, person_id);

-- ── audit_log (replace, do not add — every business write pays for these) ────
CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_log_at_id_idx
  ON public.audit_log (at DESC, id DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_log_table_at_idx
  ON public.audit_log (table_name, at DESC, id DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_log_actor_at_idx
  ON public.audit_log (actor_id, at DESC, id DESC);
DROP INDEX CONCURRENTLY IF EXISTS public.audit_log_at_idx;
DROP INDEX CONCURRENTLY IF EXISTS public.audit_log_actor_idx;
-- keep audit_log_row_idx (table_name, row_id)

-- ── system_users: case-insensitive uniqueness for the ilike login lookup ─────
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS system_users_username_lower_uidx
  ON public.system_users (lower(username));

-- ── Tables from migrations not in this repo — guarded, non-concurrent (small) ─
DO $$ BEGIN
  IF to_regclass('public.sites') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS sites_organisation_idx ON public.sites (organisation_id);
  END IF;
  IF to_regclass('public.engagement_milestones') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS engagement_milestones_engagement_idx ON public.engagement_milestones (engagement_id);
    CREATE INDEX IF NOT EXISTS engagement_milestones_status_idx     ON public.engagement_milestones (status, proposed_at);
  END IF;
  IF to_regclass('public.lead_stage_requests') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS lead_stage_requests_lead_idx    ON public.lead_stage_requests (lead_id, requested_at DESC);
    CREATE INDEX IF NOT EXISTS lead_stage_requests_pending_idx ON public.lead_stage_requests (request_type) WHERE status = 'pending';
  END IF;
  IF to_regclass('public.sales_campaign_organisations') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS sales_campaign_organisations_org_idx ON public.sales_campaign_organisations (organisation_id);
  END IF;
END $$;

-- ── refresh planner statistics ───────────────────────────────────────────────
ANALYZE public.engagements;
ANALYZE public.leads;
ANALYZE public.deals;
ANALYZE public.organisations;
ANALYZE public.person_organisation_roles;
ANALYZE public.audit_log;

-- Verify: select tablename, indexname, indexdef from pg_indexes
--         where schemaname='public' and tablename in ('engagements','leads','deals','audit_log','person_organisation_roles') order by 1,2;
-- After a week: select relname, indexrelname, idx_scan from pg_stat_user_indexes where schemaname='public' order by idx_scan;
--   (idx_scan = 0 on a business table after normal use -> candidate to drop.)
```

### IDX-01 — engagements.deal_id — FK with no index; scanned on every deal open, every deal-side engagement save and every cascade delete

**Impact medium · effort S · db index · spot-checked (confidence 0.9)**

- **Where:** /home/user/Focus/sql/schema.sql:434-450 (engagements DDL, no index), :2412 (engagements_deal_id_fkey ON DELETE CASCADE); queries at /home/user/Focus/index.html:9184, 25976-25978, 26189, 14472, 13790
- **Evidence:** Only index on engagements is idx_engagements_lead (sql/unify_engagements.sql:48). Client queries: 9184 `engagements?deal_id=eq.${dealId}&select=*&order=engagement_date.desc,created_at.desc` (deal Engagements tab); 25977 `${filter}&select=id,stream_id,stream_label,…&order=engagement_date.desc,id.desc&limit=1000` with filter `deal_id=eq.${parent.id}` (stream picker in the log modal); 26189 `${parentFilter}&engagement_date=eq.${date}&…&limit=5` (duplicate check before every save); 14472 `deal_id=in.(…)`; 13790 `DELETE engagements?deal_id=eq.${id}`; sql/reimport_contracts_march2026.sql:8 `delete from deals; -- cascades … engagements`.
- **Mechanism:** DB sequential scan of the largest business table for every deal-scoped read/delete; the FK cascade from deals runs the same unindexed `WHERE deal_id = $1` once per deleted deal.
- **Who feels it:** Every user opening a deal's Engagements tab (9184) and every engagement logged against a deal (26189 + 25977) — several times per session. Admin deal deletes and bulk re-imports scale O(deals x engagements).

- **Fix:**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_deal_date_idx
  ON public.engagements (deal_id, engagement_date DESC, id DESC)
  WHERE deal_id IS NOT NULL;
-- Leading column serves deal_id=eq / deal_id=in / deal_id=not.is.null and the FK cascade; the trailing columns return the per-deal history already in the order 9184/25977 ask for. Partial keeps lead-only rows out.
```

### IDX-02 — engagements has no (engagement_date, id) index — Engagement History, dashboard Interactions and the Activity report sort the whole table every load

**Impact medium · effort S · db index · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/index.html:16536-16541 (_engHistLoad), 12500-12501 (_dashInteractions), 24442-24451 (activity report), 26440-26443 (_intActLoad)
- **Evidence:** 16541 `engagements?${base}${fromQ}${toQ}&select=*&order=engagement_date.desc,id.desc&limit=1000` where base defaults to `id=gt.0` (All); 12501 apiGetAll('engagements','engagement_date=gte.'+fromIso+'&select=…') which apiGetAll (2160-2170) pages with `order=id.asc&limit=1000&offset=N`; 24443 `engagement_date=gte.${winFrom}&engagement_date=lte.${st.to}` (apiGetAll); 24451 `engagement_date=gt.${st.to}&…&limit=500`; 26443 `work_project_id=not.is.null${fromQ}${toQ}&…&order=engagement_date.desc,id.desc`. index_inventory: no index on engagement_date.
- **Mechanism:** Without an index PostgREST's `ORDER BY engagement_date DESC, id DESC LIMIT 1000` is a full scan + top-N heapsort of every engagement row, and each date-range query is a full scan; with the index the top-1000 becomes a backward index walk that stops after 1000 rows and ranges become index range scans. Cost grows linearly with table size (assumption: engagements is the fastest-growing business table — every lead/deal/org/project touch plus promotion copies).
- **Who feels it:** Engagement History page (every visit, all users), dashboard Interactions card (every login for roles that have it), Activity report, Internal Activity page.

- **Fix:**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_date_id_idx
  ON public.engagements (engagement_date, id);
-- btree is walked backwards for the DESC,DESC order; apiGetAll's appended ',id.asc' after 'engagement_date.desc,id.desc' is a redundant third key (id is unique) and does not defeat it.
```

### IDX-03 — Open next-actions query (dashboard Outstanding Actions / Attention Workbench) full-scans engagements — needs a partial index on the constant predicate

**Impact medium · effort S · db index · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/index.html:12376-12377 and 12390-12391 (_attentionActionRows); trigger sql/unify_engagements.sql:59-67 (refresh_lead_next_action)
- **Evidence:** 12377 `engagements?next_action_done=eq.false&next_action_date=not.is.null&select=id,lead_id,deal_id,next_action,next_action_date,engagement_type,stream_id,engagement_date` — no lead/deal filter, every dashboard load. No index exists on next_action_done or next_action_date (index_inventory). The DB trigger runs `WHERE lead_id=$1 AND next_action_done=false AND next_action IS NOT NULL AND next_action_date IS NOT NULL ORDER BY next_action_date ASC, id DESC LIMIT 1` on every engagement insert/update/delete.
- **Mechanism:** Full sequential scan of engagements to return the (small, shrinking-fraction) set of still-open actions; a partial index over exactly `next_action_done = false AND next_action_date IS NOT NULL` is tiny (only open rows) and is scanned in due-date order.
- **Who feels it:** Every user, every dashboard load (the card is in most role layouts) and every Attention Workbench visit.

- **Fix:**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_open_actions_idx
  ON public.engagements (next_action_date, id)
  WHERE next_action_done = false AND next_action_date IS NOT NULL;
-- PostgREST renders next_action_done=eq.false as `next_action_done = false`, matching the partial predicate exactly.
```

### IDX-04 — engagements.org_id and work_project_id (sparse, out-of-repo columns) have no index — org-touch lookup full-scans engagements on every dashboard load and every lead open

**Impact medium · effort S · db index · reviewer (confidence 0.7)**

- **Where:** /home/user/Focus/index.html:14290 (_loadOrgTouches), 14474 (group family engagements), 25149 (loadLeadInteractions org chain), 26189 (work_project_id=eq twin check), 26443 (_intActLoad)
- **Evidence:** 14290 `engagements?org_id=not.is.null&select=org_id,engagement_date,work_mode` is called from _attentionLeadItems (12146) which renderDashboard awaits at 12233 on every load; 25149 `engagements?org_id=in.(${chain})&select=*&order=engagement_date.desc` runs inside loadLeadInteractions (every lead open); 14474 `org_id=in.(…)`; 26443 `work_project_id=not.is.null…`. These columns are not in sql/schema.sql or any sql/*.sql (added by sql/add_engagement_time.sql and the sites/streams migrations referenced at index.html:25273/2772 but absent from the repo) — assumption: they were added with no index.
- **Mechanism:** Full scan of engagements to find the small subset of rows carrying an org_id / work_project_id; a partial index over `col IS NOT NULL` contains only those rows and matches `=not.is.null`, `=eq`, `=in` predicates.
- **Who feels it:** Every dashboard load (all users), every lead open with a linked organisation, Internal Activity page, every engagement save on a work project.

- **Fix:**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_org_date_idx
  ON public.engagements (org_id, engagement_date DESC)
  WHERE org_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_work_project_idx
  ON public.engagements (work_project_id)
  WHERE work_project_id IS NOT NULL;
-- If either statement fails with 'column does not exist', that DB has not had the out-of-repo migration; skip it there.
```

### IDX-05 — person_organisation_roles.org_id — the most-issued filtered lookup in the app (17 query sites) and a CASCADE FK, with no index

**Impact medium · effort S · db index · reviewer (confidence 0.85)**

- **Where:** /home/user/Focus/sql/schema.sql:942-950 (DDL), :1969 (UNIQUE (person_id, org_id) — leading column is person_id), :2644 (org_id FK ON DELETE CASCADE); queries at /home/user/Focus/index.html:3926-3927, 3997-3998, 10038, 10106, 10503, 16361, 18216, 21736, 22607, 22730
- **Evidence:** Examples: 3927 `person_organisation_roles?org_id=eq.${orgId}&end_date=is.null&select=person_id,job_title,is_primary&order=is_primary.desc` (client contacts modal); 3998 same on the Contacts page; 10038/10106/18216 `org_id=eq.…&end_date=is.null&select=person_id,job_title` (deal/lead contact pickers); 22607 `org_id=eq.${orgId}&is_primary=eq.true`. predicates.txt: org_id=eq x17. The UNIQUE(person_id, org_id) btree only serves person_id-leading lookups.
- **Mechanism:** Sequential scan of the affiliations table on every org-scoped contact lookup; the ON DELETE CASCADE from organisations (org merge, 27497) also scans it. Table grows with people x affiliations; today likely low thousands, so per-call cost is a few ms — cheap insurance.
- **Who feels it:** Anyone opening a client's contacts, adding a contact to a deal/lead, or promoting a lead (22730 loop runs it once per contact).

- **Fix:**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS person_organisation_roles_org_idx
  ON public.person_organisation_roles (org_id, person_id);
-- Not partial on end_date: 10503, 16361, 21736, 22607 and the FK cascade filter on org_id alone.
```

### IDX-06 — leads.promoted_deal_id, target_org_id, site_id, source_org_id — FK columns with no index; promoted_deal_id is probed on every deal open

**Impact low · effort S · db index · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/sql/schema.sql:634-680 (leads DDL), :2216-2251 (existing leads indexes: next_action_date, owner_id, research_campaign_id, source_id, status), :2532/2580/2596 (FKs); queries at /home/user/Focus/index.html:9016, 15207, 13792, 14343, 14389-14393, 14462-14468, 27438-27447
- **Evidence:** 9016 `leads?promoted_deal_id=eq.${dealId}&select=id,target_org_name,site_id,site_name,description,promoted_at,sites(name)` runs from _dealLeadHistoryHtml on every deal Engagements tab render (9185); 15207 `promoted_deal_id=eq.${dealId}&select=id&limit=1`; 13792 `PATCH leads?promoted_deal_id=eq.${id}`; 14343 `leads?target_org_id=eq.${orgId}`; 14393/14468 `or=(target_org_id.in.(…),site_id.in.(…))` (group-member leads for the org/lead group chips); ORG_MERGE_REFS PATCHes `target_org_id=eq` and `source_org_id=eq`. None of these columns is indexed.
- **Mechanism:** Seq scan of leads per call; the OR of two IN-lists (14393) needs BOTH target_org_id and site_id indexed for a BitmapOr, otherwise it is always a full scan. FK actions (deals delete SET NULL, organisations delete SET NULL) scan too.
- **Who feels it:** Every deal open (promoted_deal_id); group chips on the Leads/Clients lists and lead form (target_org_id/site_id); admin org merge and deal delete.

- **Fix:**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_promoted_deal_idx ON public.leads (promoted_deal_id) WHERE promoted_deal_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_target_org_idx    ON public.leads (target_org_id)    WHERE target_org_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_site_idx          ON public.leads (site_id)          WHERE site_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_source_org_idx    ON public.leads (source_org_id)    WHERE source_org_id IS NOT NULL;
```

### IDX-07 — audit_log paging: replace (at) and (actor_id) with (at,id) / (table_name,at,id) / (actor_id,at,id) so the admin viewer walks an index instead of sorting; do not add net indexes to the hottest-write table

**Impact low · effort S · db index · reviewer (confidence 0.7)**

- **Where:** /home/user/Focus/sql/add_audit_log.sql:25-27 (audit_log_at_idx (at desc), audit_log_row_idx (table_name,row_id), audit_log_actor_idx (actor_id)); query builder /home/user/Focus/index.html:13857-13871; AUDIT_PAGE_SIZE=200 at 13822
- **Evidence:** 13857 parts = ['select=*','order=at.desc,id.desc','limit=200','offset=N'] plus optional `at=gte/lte`, `table_name=eq`, `op=eq`, `row_id=eq`, `actor_id=eq|is.null`. audit_row_change (add_audit_log.sql:30-66) inserts one audit_log row per business row change on 17 tables (13813-13816 AUDIT_TABLES), including every revenue_stream_months bulk POST (9594, 22781) and every lead autosave PATCH, so audit_log is the fastest-growing table. sql/add_lead_stage_events.sql:9 already shows it being mined ('27 entries into Qualified').
- **Mechanism:** ORDER BY at DESC, id DESC over an index on (at) alone needs an Incremental Sort; with `table_name=eq.leads` the planner uses (table_name,row_id), pulls every audit row for that table and sorts it for each 200-row page; offset paging repeats that per page. Matching composite indexes make each page a bounded index walk. Each extra index costs every business write ~tens of µs, hence replace rather than add.
- **Who feels it:** Admin Audit Log page (few users) — but the write-side cost of the audit indexes is paid by every user on every save, so keeping the index set lean matters app-wide.

- **Fix:**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_log_at_id_idx     ON public.audit_log (at DESC, id DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_log_table_at_idx  ON public.audit_log (table_name, at DESC, id DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_log_actor_at_idx  ON public.audit_log (actor_id, at DESC, id DESC);
DROP INDEX CONCURRENTLY IF EXISTS public.audit_log_at_idx;
DROP INDEX CONCURRENTLY IF EXISTS public.audit_log_actor_idx;
-- keep audit_log_row_idx (table_name,row_id) for row-history lookups (row_id=eq).
```

### IDX-08 — Self-referencing FKs on engagements (related_interaction_id, and stream_id if declared as FK) are unindexed — every engagement delete triggers a full-table scan, making cascades O(N x M)

**Impact low · effort S · db index · reviewer (confidence 0.75)**

- **Where:** /home/user/Focus/sql/unify_engagements.sql:35-38 (engagements_related_interaction_id_fkey … ON DELETE SET NULL); delete paths /home/user/Focus/index.html:13790, 17493-17503 (_revertChildAdditions / _deleteLeadCascade), sql/reimport_contracts_march2026.sql:8, sql/wipe_prod_business_data.sql
- **Evidence:** `ALTER TABLE public.engagements ADD CONSTRAINT engagements_related_interaction_id_fkey FOREIGN KEY (related_interaction_id) REFERENCES public.engagements(id) ON DELETE SET NULL;` with no accompanying index. Postgres enforces ON DELETE SET NULL with `UPDATE engagements SET related_interaction_id = NULL WHERE related_interaction_id = $1` per deleted row. stream_id (root-of-stream pointer, used at 25977/16563) was added by an out-of-repo migration; if it is also a FK the same applies.
- **Mechanism:** For a deal/lead with k engagements, deleting it runs k sequential scans of the whole engagements table (plus the unindexed deal_id scan from IDX-01). Bulk scripts that `delete from deals` become quadratic.
- **Who feels it:** Admin deal delete (13772), lead delete / promotion revert (17493-17503), data re-imports. Rare, but the one place a growing table turns a click into a timeout (proxy 12 s x 3 retries).

- **Fix:**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_related_interaction_idx
  ON public.engagements (related_interaction_id) WHERE related_interaction_id IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS engagements_stream_idx
  ON public.engagements (stream_id) WHERE stream_id IS NOT NULL;  -- skip if stream_id is not a FK / column absent
```

### IDX-09 — Tables created by migrations missing from the repo (sites, engagement_milestones, lead_stage_requests, sales_campaign_organisations.organisation_id) — index state unverifiable; add guarded indexes for the predicates the dashboard and lead form send

**Impact low · effort S · db index · reviewer (confidence 0.5)**

- **Where:** /home/user/Focus/index.html:2772 (sql/add_sites.sql), 2716 (sql/add_engagement_milestones.sql) — both absent from /home/user/Focus/sql/; queries at 12316, 12815, 24017, 25060, 20243-20244, 20400-20401, 12302, 14389, 14462, 22626, 27463, 27488-27489
- **Evidence:** 12316 `engagement_milestones?status=eq.pending&select=*&order=proposed_at.asc&limit=100` and 12815 `status=eq.approved&…&order=decided_at.desc.nullslast&limit=80` (dashboard, every load for managers); 24017 `engagement_id=in.(…)` in 150-chunks (Engagement History, lead form, reports); 20244 `lead_stage_requests?lead_id=eq.${leadId}&status=eq.pending&request_type=in.(hold,nurture)&…&order=requested_at.desc&limit=1` (every lead open via 19918); 12302 `status=eq.pending&request_type=eq.dead`; 14389/14462 `sites?organisation_id=in.(…)`, 22626 `organisation_id=eq`; sales_campaign_organisations UNIQUE(sales_campaign_id, organisation_id) (sql/research_study_fields.sql:16) does not serve `organisation_id=eq` (27463/27488).
- **Mechanism:** If these tables were created without secondary indexes (as most repo migrations were), each of these predicates is a seq scan; volumes are small today (assumption: < a few thousand rows each) so cost is ms-level, but they sit on the dashboard and lead-open critical paths.
- **Who feels it:** Dashboard (approvals/milestone widgets), every lead open (stage request), group chips (sites), org merge.

- **Fix:**

```sql
DO $$ BEGIN
  IF to_regclass('public.sites') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS sites_organisation_idx ON public.sites (organisation_id);
  END IF;
  IF to_regclass('public.engagement_milestones') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS engagement_milestones_engagement_idx ON public.engagement_milestones (engagement_id);
    CREATE INDEX IF NOT EXISTS engagement_milestones_status_idx ON public.engagement_milestones (status, proposed_at);
  END IF;
  IF to_regclass('public.lead_stage_requests') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS lead_stage_requests_lead_idx ON public.lead_stage_requests (lead_id, requested_at DESC);
    CREATE INDEX IF NOT EXISTS lead_stage_requests_pending_idx ON public.lead_stage_requests (request_type) WHERE status = 'pending';
  END IF;
  IF to_regclass('public.sales_campaign_organisations') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS sales_campaign_organisations_org_idx ON public.sales_campaign_organisations (organisation_id);
  END IF;
END $$;
-- Plain CREATE INDEX inside DO (CONCURRENTLY is not allowed in a transaction block); these tables are small so the brief write lock is acceptable. First run `select indexname, indexdef from pg_indexes where tablename in ('sites','engagement_milestones','lead_stage_requests')` to confirm what exists.
```

### IDX-10 — deals.org_id (FK ON DELETE RESTRICT) and organisations.parent_org_id are unindexed — org-scoped deal lookups and org-merge FK checks scan deals/organisations

**Impact low · effort S · db index · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/sql/schema.sql:2332 (deals_org_id_fkey … ON DELETE RESTRICT), sql/add_org_detail_fields.sql:43 (parent_org_id REFERENCES organisations(id), no index); queries /home/user/Focus/index.html:14344, 14469, 27438-27447, 27497
- **Evidence:** 14344 `deals?org_id=eq.${orgId}&or=(opportunity_type.is.null,opportunity_type.eq.new_business)&select=id,notes,created_at` (collective-birth check when a lead/deal is saved for an org); 14469 `deals?org_id=in.(${idList})` (group view); ORG_MERGE_REFS `deals org_id=eq.dup`, `organisations parent_org_id=eq.dup`; DELETE organisations (27497) runs the RESTRICT check `SELECT 1 FROM deals WHERE org_id=$1` and the parent_org_id NO ACTION check.
- **Mechanism:** Seq scan of deals (and organisations) per call. Deals is a few hundred to low thousands of rows (assumption), so each scan is ~1 ms — low absolute cost, but the FK checks are hidden inside the DELETE and cannot be avoided any other way.
- **Who feels it:** Group/collective views for clients, org merge (admin). Infrequent.

- **Fix:**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS deals_org_idx ON public.deals (org_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS organisations_parent_org_idx ON public.organisations (parent_org_id) WHERE parent_org_id IS NOT NULL;
```

### IDX-11 — orgs_link_freetext_leads trigger scans leads with an expression predicate on every organisation insert/rename — add the matching partial expression index

**Impact low · effort S · db index · reviewer (confidence 0.8)**

- **Where:** /home/user/Focus/sql/schema.sql:224-246 (trg_orgs_link_freetext_leads), :2293 (CREATE TRIGGER orgs_link_freetext_leads AFTER INSERT OR UPDATE OF name, legal_name ON organisations); never dropped in any sql/*.sql
- **Evidence:** Trigger body: `UPDATE leads SET target_org_id = NEW.id … WHERE target_org_id IS NULL AND target_org_name IS NOT NULL AND (lower(trim(target_org_name)) = lower(trim(NEW.name)) OR (NEW.legal_name IS NOT NULL AND lower(trim(target_org_name)) = lower(trim(NEW.legal_name))))`. No expression index exists on leads.
- **Mechanism:** Every organisation INSERT (lead capture creates orgs inline; the 08-25 backfill created many) and every rename evaluates lower(trim()) over every lead row. A partial expression index over exactly `WHERE target_org_id IS NULL AND target_org_name IS NOT NULL` holds only unlinked free-text leads (a small set) and answers the equality by probe.
- **Who feels it:** Saving a new organisation or renaming one (org form, lead capture with a new org). Adds tens of ms per save today; grows with leads.

- **Fix:**

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS leads_unlinked_org_name_idx
  ON public.leads (lower(trim(target_org_name)))
  WHERE target_org_id IS NULL AND target_org_name IS NOT NULL;
```

### IDX-12 — Existing indexes no client predicate ever uses (write churn only): idx_leads_next_action_date, idx_leads_status, idx_leads_source_id, deals_opportunity_type_idx

**Impact low · effort S · db index · reviewer (confidence 0.7)**

- **Where:** /home/user/Focus/sql/schema.sql:2223 (idx_leads_next_action_date), :2251 (idx_leads_status), :2244 (idx_leads_source_id); sql/add_extensions_variations.sql:69 (deals_opportunity_type_idx); predicates.txt 'leads' and 'deals' sections
- **Evidence:** predicates.txt lists every server-side filter on leads: id, promoted_deal_id, research_campaign_id, target_org_id, sales_campaign_id — never status, next_action_date or source_id (status/overdue are computed client-side, e.g. 12621-12625 _dashLeads filters in JS). leads.next_action_date is rewritten by refresh_lead_next_action (sql/unify_engagements.sql:59-67) on every engagement insert/update/delete, so that index is re-entered on every activity write and blocks HOT updates on leads. deals.opportunity_type has 3 values and is only ever used together with parent_deal_id (9528), which has its own selective index.
- **Mechanism:** Each unused index adds index-maintenance work and WAL to every UPDATE of the row (and an audit_log write already accompanies those). No read benefits.
- **Who feels it:** Every engagement save and lead autosave pays a little extra; no page is faster because of them. Low absolute cost — drop only if nobody queries leads by status/next_action_date outside the app (psql/reporting).

- **Fix:**

```sql
DROP INDEX CONCURRENTLY IF EXISTS public.idx_leads_next_action_date;
DROP INDEX CONCURRENTLY IF EXISTS public.idx_leads_status;
DROP INDEX CONCURRENTLY IF EXISTS public.deals_opportunity_type_idx;
-- idx_leads_source_id: keep (cheap) unless lead_sources rows are never deleted; it only serves the RESTRICT FK check.
```

### IDX-13 — Login username lookup uses ILIKE, which the UNIQUE(username) btree cannot serve — but system_users is tiny, so this is a uniqueness fix, not a speed fix

**Impact low · effort S · db index · reviewer (confidence 0.9)**

- **Where:** /home/user/Focus/netlify/functions/sb.js:162-166; /home/user/Focus/sql/schema.sql:2193 (system_users_username_key UNIQUE (username))
- **Evidence:** sb.js:166 `rows = await sbRest(key, 'GET', `/system_users?username=ilike.${encodeURIComponent(uname)}&${SELECT}`);` with the comment 'ilike without wildcards = case-insensitive equality'. index.html:11462 also orders by username. system_users holds one row per staff member (<100).
- **Mechanism:** ILIKE forces a seq scan; on <100 rows that is microseconds, invisible next to the ~1.4 s proxy hop. A unique index on lower(username) makes the lookup an index probe AND guarantees that 'richard' and 'Richard' cannot both exist (which would make the ILIKE match ambiguous — rows[0] would be arbitrary).
- **Who feels it:** Login only; no measurable latency change. Included because the task asked for the ilike case explicitly.

- **Fix:**

```sql
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS system_users_username_lower_uidx
  ON public.system_users (lower(username));
-- Optionally change sb.js:166 to `username=eq.${uname.toLowerCase()}` once usernames are stored lower-case, so the equality hits the index directly.
```


## Database triggers and server-side data shapes

### SRV-1 — View deal_financials (TCV / margin / weighted / first-last month per deal and stream type) replaces shipping every revenue_stream_months row to the browser to be summed in JS; add the missing revenue_streams.deal_id FK so it can also be embedded from deals

**Impact high · effort S · db view or rpc · reviewer (confidence 0.85)**

- **Where:** Consumers: index.html:11803-11812 (renderOpportunitiesPage: apiGetAll('revenue_streams','stream_type=eq.opportunity&select=deal_id,revenue_stream_months(opportunity_revenue)') on every register render just to sum a TCV per client band), 12664 (_dashPipeline), 12706-12707 (_dashSectorValue), 13710 (renderDealAdminPage locked flag), 9454-9457 & 9538-9540 (secure/extension: streams then months). Constraint gap: sql/schema.sql:2029-2033 (UNIQUE deal_id,stream_type) but no FOREIGN KEY on revenue_streams.deal_id (absent from fk_columns.txt)
- **Evidence:** index.html:11805 `apiGetAll('revenue_streams','stream_type=eq.opportunity&select=deal_id,revenue_stream_months(opportunity_revenue)')` then 11808-11809 sums in a nested loop; 12664 and 12707 repeat the same pattern with deal_id=in.(all open deal ids). Payload = one JSON object per month row for every deal (a 36-month deal = 36 rows), built by PostgREST, buffered whole in the Lambda (sb.js:299-300 `let d=''; res.on('data', c => d += c)`), parsed in the browser — while the page needs one number per deal. UNIQUE(stream_id,month) (schema.sql:2025) and UNIQUE(deal_id,stream_type) (2033) already give the view its join indexes.
- **Mechanism:** over-fetch bytes + client CPU: O(deals x months) rows transferred and summed for each render, versus O(deals) rows from a server-side aggregate; plus one extra sequential hop on the register (the streams fetch at 11805 runs after the deals fetch).
- **Who feels it:** Opportunities register (every render, every tab/scope click), dashboard Pipeline and Value-by-Sector cards, Deal Admin. All sales users.

- **Fix:**

```sql
create or replace view deal_financials as
select s.deal_id, s.stream_type, s.id as stream_id, s.locked,
       count(m.id) as months, min(m.month) as first_month, max(m.month) as last_month,
       coalesce(sum(m.opportunity_revenue),0) as opportunity_revenue,
       coalesce(sum(m.opportunity_margin),0)  as opportunity_margin,
       coalesce(sum(m.secured_revenue),0)     as secured_revenue,
       coalesce(sum(m.secured_margin),0)      as secured_margin,
       coalesce(sum(m.actual_revenue) filter (where m.is_actual_revenue),0) as actual_revenue,
       coalesce(sum(m.opportunity_revenue),0) * coalesce(d.probability,0) / 100.0 as weighted
from revenue_streams s
join deals d on d.id = s.deal_id
left join revenue_stream_months m on m.stream_id = s.id
group by s.deal_id, s.stream_type, s.id, s.locked, d.probability;
grant select on deal_financials to anon, authenticated, service_role;

-- FK so PostgREST can embed (check orphans first: select count(*) from revenue_streams s where not exists (select 1 from deals d where d.id = s.deal_id))
alter table revenue_streams add constraint revenue_streams_deal_id_fkey foreign key (deal_id) references deals(id) on delete cascade;

Client (existing proxy, no changes): register 11805 -> `apiGetAll('deal_financials','stream_type=eq.opportunity&select=deal_id,opportunity_revenue,weighted,locked')` (one ~60-byte row per deal); dashboard 12664 -> `apiGet('deal_financials', 'stream_type=eq.opportunity&deal_id=in.(...)&select=deal_id,opportunity_revenue,weighted')`; sector card 12707 -> same with both stream types. With the FK in place, `deals?select=id,name,deal_financials(opportunity_revenue,weighted)` should also embed (PostgREST traces view columns to the FK column; verify with one GET, otherwise query the view by deal_id=in). Column names secured_revenue/secured_margin follow sql/rename_fulfilment_to_secured.sql — confirm on the live DB.
```

### SRV-2 — View opportunities_register (org, sector, site, stage + category, owner name, TCV, lock flag pre-joined) makes the register one narrow, server-filtered round trip instead of 7-9 GETs plus Array.find joins

**Impact high · effort M · db view or rpc · reviewer (confidence 0.8)**

- **Where:** index.html:11758-11812 (renderOpportunitiesPage: Promise.all of deals select=* paged + organisations/stages/people/stage_categories/sites/industry_sectors, then filterDealsByView 11715-11734 with an extra deal_collaborators GET for 'collab', then the streams fetch 11805), 13691-13712 (renderDealAdminPage, same shape)
- **Evidence:** index.html:11768 `apiGetAll('deals', 'select=*&order=created_at.desc')` pulls every column of every deal for every user, then 11783 `deals = await filterDealsByView(deals, oppsOwnerView)` throws most of them away client-side (default view is 'own', 11602). 11791-11795 filters to the Opportunity-Open stage category in JS. Sector/org/site/stage/owner are resolved per row with `.find` over allData (e.g. 11833 `sites.find(x => +x.id === +d.site_id)`, and `_orgSectorName` 11738-11743). FKs exist for the joins: deals_org_id_fkey (schema.sql:2332), deals_stage_id_fkey (2372), deals_owner_id_fkey (2340), stages_category_id_fkey (2724).
- **Mechanism:** extra sequential round trips (deals -> view filter -> streams) + over-fetch (select=* on deals and 6 lookup tables) + O(deals x lookups) client joins per render.
- **Who feels it:** Opportunities register on every open, every Own/All/Collab/Team click and every status toggle; Deal Administration. All sales users and managers.

- **Fix:**

```sql
create or replace view opportunities_register as
select d.id, d.name, d.org_id, o.name as org_name, o.legal_name, sec.name as sector,
       d.site_id, si.name as site_name,
       d.stage_id, st.name as stage, sc.name as stage_category, st.sort_order as stage_order,
       d.probability, d.order_date, d.start_date, d.owner_id,
       trim(concat_ws(' ', p.first_name, p.last_name)) as owner_name,
       d.region_id, d.branch_id, d.service_major_id, d.service_sub_id,
       d.opportunity_type, d.master_deal_id, d.parent_deal_id, d.created_at, d.updated_at,
       f.opportunity_revenue as tcv, f.weighted, coalesce(f.locked,false) as forecast_locked, f.first_month, f.last_month,
       (select coalesce(array_agg(dc.person_id),'{}') from deal_collaborators dc where dc.deal_id = d.id) as collaborator_ids
from deals d
left join organisations o on o.id = d.org_id
left join industry_sectors sec on sec.id = o.sector_id
left join sites si on si.id = d.site_id
left join stages st on st.id = d.stage_id
left join stage_categories sc on sc.id = st.category_id
left join people p on p.id = d.owner_id
left join deal_financials f on f.deal_id = d.id and f.stream_type = 'opportunity';
grant select on opportunities_register to anon, authenticated, service_role;
create index if not exists deals_owner_idx on deals (owner_id);
create index if not exists deals_stage_idx on deals (stage_id);

Client: Own view -> `apiGetAll('opportunities_register', 'owner_id=eq.' + me + '&stage_category=eq.Opportunity-Open&order=created_at.desc')`; Collab -> `&or=(owner_id.eq.5,collaborator_ids.cs.{5})`; Team -> `&or=(owner_id.eq.5,branch_id.in.(...),region_id.in.(...))`; All statuses -> drop the category filter. One hop, ~25 columns, only the user's rows; the row renderer reads org_name/sector/stage/owner_name directly (no .find). openOpportunity (5148) is unchanged.
```

### SRV-3 — RPC dashboard_summary(p_person_id, p_scope) returning jsonb: one GET replaces ~30 calls / 9-10 sequential levels, 4 leads scans, 5 deals scans and 3 milestone scans per dashboard render

**Impact high · effort L · db view or rpc · reviewer (confidence 0.8)**

- **Where:** index.html:12219-12271 (renderDashboard) and its loaders: 12139-12150 (_attentionLeadItems), 12278-12360 (_dashApprovals), 12373-12405 (_attentionActionRows), 12619-12621 (_dashLeads), 12642-12668 (_dashOpps/_dashPipeline), 12683-12712 (_dashSectorValue), 12767-12769 (_dashContracts), 12809-12830 (_dashMilestones), 24968-24990 (_dashMilestonePulse), 12480-12530 (_dashInteractions), 14286-14299 (_loadOrgTouches)
- **Evidence:** Whole-table GETs of leads at 12140, 12291, 12393, 12621; of deals at 12394, 12645, 12658, 12694, 12769; of engagements at 12376 (open actions) and 14290 (org touches, no date bound); engagement_milestones at 12317, 12817 and 24974 (`apiGetAll('engagement_milestones','select=*')` — the entire table), each followed by sequential `for (let i = 0; i < engIds.length; i += 150)` chunk loops (12322-12327, 12823-12826, 24981-24984). The reminder gate at 12234 awaits _attentionLeadItems (leads -> sweep PATCHes -> engagements -> orgs) before any widget starts. Scope rule is simple (12056-12061 `_dashInScope`: all | owner_id = me | team = own OR branch/region in the user's system_user_branches/regions, 11283-11290) and is applied in JS after download. Every number on the page is a count/sum Postgres can compute in one statement.
- **Mechanism:** extra sequential round trips (depth 9-10 at ~1.4 s = ~13 s before the last card fills) + over-fetch (the same leads/deals rows downloaded 4-5 times) + DB sequential scans of engagements/engagement_milestones with no supporting indexes.
- **Who feels it:** Every user, on every login (first page) and on every dashboard revisit or scope switch; the reminder gate means the page is blank for the first 3+ hops.

- **Fix:**

```sql
create or replace function dashboard_summary(p_person_id bigint, p_scope text default 'own')
returns jsonb language sql stable security definer as $$
with me as (
  select coalesce(array(select region_id from system_user_regions r join system_users su on su.id = r.system_user_id where su.person_id = p_person_id),'{}') regions,
         coalesce(array(select branch_id from system_user_branches b join system_users su on su.id = b.system_user_id where su.person_id = p_person_id),'{}') branches),
sl as (select l.* from leads l, me where p_scope = 'all' or l.owner_id = p_person_id
        or (p_scope = 'team' and (l.branch_id = any(me.branches) or l.region_id = any(me.regions)))),
sd as (select d.* from deals d, me where p_scope = 'all' or d.owner_id = p_person_id
        or (p_scope = 'team' and (d.branch_id = any(me.branches) or d.region_id = any(me.regions)))),
open_stage as (select id from stages where name in ('Prospect','Proposal','Negotiation')),
open_actions as (
  select distinct on (coalesce(e.stream_id, e.id)) e.id, e.lead_id, e.deal_id, e.next_action, e.next_action_date, e.engagement_type
  from engagements e where e.next_action_done = false and e.next_action_date is not null
  order by coalesce(e.stream_id, e.id), e.engagement_date desc, e.id desc),
acts as (select a.*, coalesce(l.description, d.name) label, case when l.id is not null then 'lead' else 'deal' end kind
         from open_actions a left join sl l on l.id = a.lead_id left join sd d on d.id = a.deal_id
         where l.id is not null or d.id is not null)
select jsonb_build_object(
  'leads_by_status', (select coalesce(jsonb_object_agg(status, n),'{}') from (select status, count(*) n from sl group by 1) x),
  'leads_overdue', (select count(*) from sl where status in ('New','Working','Nurture','Qualified') and next_action_date < current_date),
  'opps_open_by_stage', (select coalesce(jsonb_object_agg(st.name, n),'{}') from (select d.stage_id, count(*) n from sd d where d.stage_id in (select id from open_stage) group by 1) x join stages st on st.id = x.stage_id),
  'pipeline', (select jsonb_build_object('n', count(*), 'total', coalesce(sum(f.opportunity_revenue),0), 'weighted', coalesce(sum(f.weighted),0))
               from sd d join deal_financials f on f.deal_id = d.id and f.stream_type = 'opportunity' where d.stage_id in (select id from open_stage)),
  'secured_count', (select count(*) from sd d join stages s on s.id = d.stage_id where s.name = 'Secured'),
  'actions', (select jsonb_build_object('overdue', count(*) filter (where next_action_date < current_date),
                 'due_soon', count(*) filter (where next_action_date between current_date and current_date + 7), 'total', count(*),
                 'top', (select coalesce(jsonb_agg(to_jsonb(t)),'[]') from (select * from acts order by next_action_date limit 5) t)) from acts),
  'approvals', jsonb_build_object(
     'promotions', (select count(*) from promotion_requests where status = 'pending'),
     'dead_reviews', (select count(*) from lead_stage_requests where status = 'pending' and request_type = 'dead'),
     'milestones', (select count(*) from engagement_milestones where status = 'pending'),
     'red_flags', (select count(*) from lead_red_flags where review_status = 'pending' and cleared = false)),
  'attention', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'label', l.description, 'status', l.status, 'owner_id', l.owner_id,
                  'woke_at', l.woke_at, 'next_action_date', l.next_action_date,
                  'days_untouched', current_date - coalesce(greatest(l.last_touch_date, t.last_touch), l.created_at::date))),'[]')
                from sl l left join org_last_touch t on t.org_id = l.target_org_id
                where l.woke_at is not null or l.status in ('New','Working')),
  'milestone_pulse', (select jsonb_build_object(
       'this_month', count(*) filter (where m.status = 'approved' and date_trunc('month', e.engagement_date) = date_trunc('month', current_date)),
       'last_month', count(*) filter (where m.status = 'approved' and date_trunc('month', e.engagement_date) = date_trunc('month', current_date - interval '1 month')),
       'pending', count(*) filter (where m.status = 'pending'))
     from engagement_milestones m join engagements e on e.id = m.engagement_id
     left join sl l on l.id = e.lead_id left join sd d on d.id = e.deal_id where l.id is not null or d.id is not null)
) $$;

Client: `apiGet('rpc/dashboard_summary', 'p_person_id=' + me + '&p_scope=' + scope)` — a GET (PostgREST allows GET for STABLE functions), so it passes the api() read-only gate at index.html:2040-2044, gets the 3-attempt retry at 1991-1992, and rides the existing proxy rewrite (sb.js:253). Aging thresholds/overrides (agingDaysFor 12127) stay in JS applied to days_untouched. Run sweep_leads() (TRG-A3) first or via pg_cron. Supporting indexes: create index engagements_open_actions_idx on engagements (next_action_date) where next_action_done = false and next_action_date is not null; create index engagements_org_idx on engagements (org_id, engagement_date desc) where org_id is not null; create index engagement_milestones_eng_idx on engagement_milestones (engagement_id); create index engagement_milestones_status_idx on engagement_milestones (status).
```

### SRV-4 — RPC lead_bundle(p_lead_id) and deal_bundle(p_deal_id) (or one embedded GET each on the FKs that already exist) collapse the 12-16 sequential id-keyed GETs of opening a lead or a deal into one

**Impact high · effort M · db view or rpc · reviewer (confidence 0.8)**

- **Where:** index.html:17013-17060 (openLeadForm sequence: 17015, 17021, 17032, 17045, 17046, 17047, 17050, 17051, 17052, 17054, 21055) and 5148-5185 (openOpportunity: 5152, 5160, 5162, 5176, 5181-5184 -> 10435, 10023, 9178, 9013)
- **Evidence:** Every call is keyed by the lead/deal id and awaited in series: openLeadForm 17046 `await loadLeadDescriptionLog(id); await loadLeadContacts(id); ... await loadLeadServiceEstimates(id); await loadLeadInteractions(id); await loadLeadCadence(); ... await loadLeadQualificationSelections(id);` — loadLeadContacts 18063 even re-GETs `leads?id=eq&select=contacts` although 17015 already fetched select=*. loadLeadInteractions 25128-25149 does engagements by lead_id, then engagements by org chain, then milestone chunks. openOpportunity 5160-5162 GET streams then GET months; loadCollaborators 10455-10503 GET collabs -> people -> affiliations; loadOppContacts 10027-10039 contacts -> people -> dmu_roles -> affiliations; loadEngagements 9184 -> _dealLeadHistoryHtml 9016-9024 leads by promoted_deal_id -> engagements by lead. FKs available for embedding: engagements_lead_id_fkey (unify_engagements.sql:31-33), engagements_deal_id_fkey (schema.sql:2412), lead_red_flags_lead_id_fkey (2484), lead_strategic_decisions_lead_id_fkey (2500), lead_description_log (lead_lifecycle_A_foundations.sql:116), leads.site_id->sites (embedding already used at 12141), deal_collaborators_deal_id/person_id (2308/2316), opportunity_contacts_deal_id/person_id (2612/2628 — the table is now deal_contacts; constraints survive a rename), engagement_people (2380/2388). Not embeddable yet: revenue_streams from deals (no FK — SRV-1), lead_service_estimates / engagement_milestones (DDL not in repo — verify FKs).
- **Mechanism:** extra sequential round trips: 12-16 hops of ~1.4 s each on a single-row workload that Postgres answers in one query.
- **Who feels it:** Every lead open and every deal open, all users, many times a day (~17-20 s each today).

- **Fix:**

```sql
Option A (no new DB objects): one embedded GET each.
Lead: `apiGet('leads', 'id=eq.' + id + '&select=*,sites(name,organisation_id),lead_description_log(*),lead_red_flags(*),lead_strategic_decisions(*),lead_service_estimates(*),engagements(*,engagement_milestones(*))')` and a second, parallel GET for the org-chain engagements (25139-25149) and cadence steps.
Deal: `apiGet('deals', 'id=eq.' + id + '&select=*,engagements(*,engagement_people(person_id),engagement_milestones(*)),deal_contacts(*,people(*)),deal_collaborators(*,people(*))')` (+ `revenue_streams(id,locked,revenue_stream_months(*))` once SRV-1's FK exists). Depth 13 -> 2.

Option B (one hop, everything incl. org chain and job titles):
create or replace function deal_bundle(p_deal_id bigint) returns jsonb language sql stable security definer as $$
select jsonb_build_object(
  'deal', to_jsonb(d),
  'streams', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'stream_type', s.stream_type, 'locked', s.locked,
                'months', (select coalesce(jsonb_agg(to_jsonb(m) order by m.month),'[]') from revenue_stream_months m where m.stream_id = s.id))),'[]')
              from revenue_streams s where s.deal_id = d.id),
  'contacts', (select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('person', to_jsonb(p), 'job_title', r.job_title)),'[]')
               from deal_contacts c join people p on p.id = c.person_id
               left join lateral (select job_title from person_organisation_roles r where r.person_id = c.person_id and r.org_id = d.org_id and r.end_date is null limit 1) r on true
               where c.deal_id = d.id),
  'collaborators', (select coalesce(jsonb_agg(to_jsonb(dc) || jsonb_build_object('person', to_jsonb(p))),'[]') from deal_collaborators dc join people p on p.id = dc.person_id where dc.deal_id = d.id),
  'engagements', (select coalesce(jsonb_agg(to_jsonb(e) || jsonb_build_object(
                    'people', (select coalesce(jsonb_agg(ep.person_id),'[]') from engagement_people ep where ep.engagement_id = e.id),
                    'milestones', (select coalesce(jsonb_agg(to_jsonb(m)),'[]') from engagement_milestones m where m.engagement_id = e.id))
                    order by e.engagement_date desc, e.created_at desc),'[]') from engagements e where e.deal_id = d.id),
  'source_lead', (select jsonb_build_object('lead', to_jsonb(l), 'engagements', (select coalesce(jsonb_agg(to_jsonb(e) order by e.engagement_date desc),'[]') from engagements e where e.lead_id = l.id))
                  from leads l where l.promoted_deal_id = d.id limit 1))
from deals d where d.id = p_deal_id $$;

lead_bundle(p_lead_id) is the same shape with: lead row, description_log, service_estimates, red_flags, strategic_decisions, engagements(+milestones), cadence steps (join research_campaigns), promotion_requests, and group engagements via `with recursive chain as (select id, parent_org_id from organisations where id = l.target_org_id union all select o.id, o.parent_org_id from organisations o join chain c on o.id = c.parent_org_id) select ... from engagements where org_id in (select id from chain)`.
Client: `apiGet('rpc/deal_bundle', 'p_deal_id=' + id)` (GET, stable) then populate from the object; initOppForm/initLeadForm lookups stay as they are. Indexes needed for the sub-selects: engagements (deal_id), engagements (org_id), deal_contacts (deal_id), deal_collaborators (deal_id), person_organisation_roles (person_id, org_id), leads (promoted_deal_id), engagement_milestones (engagement_id).
```

### SRV-5 — RPC promote_lead(p_lead_id, p_package jsonb): one transactional call replaces the 20-40 sequential, non-atomic writes of commitPromotion and removes its K-fold trigger fan-out

**Impact high · effort L · db view or rpc · reviewer (confidence 0.8)**

- **Where:** index.html:22564-22935 (commitPromotion) — writes at 22574/22589, 22599, 22608, 22634/22645, 22681, 22688, 22700, 22723-22750 (per-contact loop), 22758, 22781, 22808, 22821, 22828 (per-copy PATCH loop), 22834, 22860, 22876, 22891, 22905, 22920; reads at 22613, 22617, 22623, 22637, 22671-22672, 22808, 22858; reused by _doAcceptPromotionRequest 21154
- **Evidence:** Strictly sequential `await api(...)` chain with no transaction; comment at 27500-27502 for the sibling merge flow documents the consequence ('re-run the same merge to finish'). The per-copy loop 22828 `for (let ci ...) await api('engagements','PATCH',{stream_id: cId, stream_label: 'Sales #'...})` is one hop per carried-forward engagement; the close PATCH 22834 on K lead rows fires refresh_lead_next_action K times (unify_engagements.sql:74-96) -> K rewrites of the same leads row and K audit_leads diffs; the org PATCH 22589 fires trg_orgs_link_freetext_leads (schema.sql:2293) -> leads seq scan. Per-contact loop 22723-22750 is 3-6 hops per extra contact. Total DB-side per promote: ~15 + 3K + N audit rows and K+1 lead rewrites, all in separate transactions.
- **Mechanism:** extra sequential round trips (20-40 x 1.4 s = 28-56 s) + trigger amplification + lack of atomicity (partial promotes on any transient failure — the proxy does not retry writes, sb.js:311-318).
- **Who feels it:** Every promotion (managers) and every accepted promotion request; the busiest single action in the lead lifecycle.

- **Fix:**

```sql
create or replace function promote_lead(p_lead_id bigint, p_pkg jsonb) returns jsonb language plpgsql security definer as $$
declare l leads%rowtype; v_org bigint; v_person bigint; v_site bigint; v_deal bigint; v_stream bigint; v_stage bigint; v_actor bigint; c jsonb; i int;
begin
  select * into l from leads where id = p_lead_id for update;
  if l.promoted_at is not null then raise exception 'already promoted'; end if;
  v_actor := nullif(nullif(current_setting('request.headers', true),'')::json->>'x-actor-id','')::bigint;
  -- 1 org
  if (p_pkg->>'isNew')::boolean then
    insert into organisations(name, legal_name, website, physical_line1) values (p_pkg->>'colloquial', p_pkg->>'legal', p_pkg->>'website', p_pkg->>'address') returning id into v_org;
  else v_org := (p_pkg->>'selectedOrgId')::bigint;
    update organisations set name = coalesce(nullif(p_pkg->>'colloquial',''), name), legal_name = coalesce(nullif(p_pkg->>'legal',''), legal_name),
           website = coalesce(nullif(p_pkg->>'website',''), website), physical_line1 = coalesce(nullif(p_pkg->>'address',''), physical_line1)
     where id = v_org and (name is distinct from p_pkg->>'colloquial' or legal_name is distinct from p_pkg->>'legal' or website is distinct from p_pkg->>'website' or physical_line1 is distinct from p_pkg->>'address');
  end if;
  -- 2-3 primary person + affiliation
  if p_pkg->>'contactMode' = 'new' then insert into people select * from jsonb_populate_record(null::people, p_pkg->'newPerson') returning id into v_person;
  else v_person := (p_pkg->>'existingPersonId')::bigint; end if;
  insert into person_organisation_roles(person_id, org_id, role_type, is_primary, job_title, start_date, created_by)
  select v_person, v_org, 'Contact', not exists (select 1 from person_organisation_roles where org_id = v_org and is_primary), nullif(trim(l.target_person_title),''), current_date, v_actor
  where not exists (select 1 from person_organisation_roles where person_id = v_person and org_id = v_org);
  -- 3.5 site (same ladder as 22637-22665)
  select id into v_site from sites where organisation_id = v_org and id = l.site_id;
  if v_site is null and nullif(trim(l.site_name),'') is not null then
    select id into v_site from sites where organisation_id = v_org and lower(trim(name)) = lower(trim(l.site_name));
    if v_site is null then insert into sites(organisation_id, name, created_by) values (v_org, trim(l.site_name), v_actor) returning id into v_site; end if;
  end if;
  if v_site is null then select id into v_site from sites where organisation_id = v_org order by is_primary desc nulls last, id limit 1; end if;
  if v_site is null then insert into sites(organisation_id, name, is_primary, created_by) select v_org, name, true, v_actor from organisations where id = v_org returning id into v_site; end if;
  -- 4 deal
  select s.id into v_stage from stages s join stage_categories c on c.id = s.category_id where c.name = 'Opportunity-Open' and s.active order by s.sort_order limit 1;
  insert into deals(name, org_id, site_id, region_id, branch_id, stage_id, service_major_id, service_sub_id, margin_pct, order_date, start_date, notes, owner_id, created_by)
  values (p_pkg#>>'{q4,dealName}', v_org, v_site, l.region_id, l.branch_id, v_stage, l.service_major_id, (p_pkg#>>'{q4,serviceSubId}')::bigint, coalesce((p_pkg#>>'{q4,marginPct}')::numeric,25), (p_pkg#>>'{q4,orderDate}')::date, (p_pkg#>>'{q4,startDate}')::date, l.description, l.owner_id, v_actor)
  returning id into v_deal;
  insert into deal_collaborators(deal_id, person_id, role, is_owner) select v_deal, l.owner_id, 'Owner', true where l.owner_id is not null;
  insert into deal_contacts(deal_id, person_id, note) values (v_deal, v_person, '');
  -- 6.5 non-primary contacts: loop over jsonb_array_elements(l.contacts) where not is_primary (same rules as 22718-22755, set-based inserts)
  -- 7 stream + months in one INSERT ... SELECT with generate_series over q4.monthValues
  insert into revenue_streams(deal_id, stream_type, locked) values (v_deal, 'opportunity', false) returning id into v_stream;
  insert into revenue_stream_months(stream_id, month, opportunity_revenue, opportunity_margin)
  select v_stream, to_char((p_pkg#>>'{q4,startDate}')::date + make_interval(months => (ord-1)::int), 'YYYY-MM'), v::numeric, round(v::numeric * coalesce((p_pkg#>>'{q4,marginPct}')::numeric,25) / 100, 2)
  from jsonb_array_elements_text(p_pkg#>'{q4,monthValues}') with ordinality t(v, ord);
  -- 7.5 carry open engagements: one INSERT...SELECT (stream_id defaults to id via TRG-A2's BEFORE trigger, label set with row_number()), one UPDATE closing originals
  -- 8 promotion engagement, 8.5 referrer, then:
  update leads set promoted_at = now(), promoted_deal_id = v_deal, status = 'Promoted', updated_at = now() where id = p_lead_id;
  return jsonb_build_object('deal_id', v_deal, 'org_id', v_org, 'person_id', v_person);
end $$;

Client: `const r = await api('rpc/promote_lead', 'POST', { p_lead_id: leadData.id, p_pkg: s }, ''); const dealId = r.deal_id;` — one hop, atomic (any failure rolls everything back), audit actor preserved because the same request headers are visible to the triggers. Keep the JS commitPromotion only as a fallback until the RPC is verified against the promote wizard's Q4 shapes.
```

### SRV-6 — RPC user_context(p_user_id) (or one embedded GET on the existing FKs) folds buildUserContext's 5 sequential rounds plus settings and home-org members into a single login call

**Impact high · effort S · db view or rpc · reviewer (confidence 0.85)**

- **Where:** index.html:11060-11122 (buildUserContext: rounds at 11064-11069, 11076-11080, 11088, 11095, 11097), 11584-11588 (enterApp Promise.all with loadAppSettings 27206-27211 and ensureHomeOrgMembers 11209-11215); sb.js:253 (rewrite), 263-266 (system_users credential scrub)
- **Evidence:** 11074 `const roleIds = userRoles.map(r => r.role_id);` gates round 2 on round 1; 11087-11090 gates permissions on role_permissions; 11095-11097 two more hops for overrides. All of it is one join tree with FKs already in place: system_users_person_id_fkey (schema.sql:2756), user_roles_user_id_fkey/role_id_fkey (2788/2780), role_permissions_role_id_fkey/permission_id_fkey (2708/2700), system_user_regions_system_user_id_fkey (2748), system_user_branches (prod_sync_v7_6_98.sql:160), user_permission_overrides_user_id_fkey/permission_id_fkey (2772/2764). settings and home_organisation_members are two tiny whole-table reads that every login needs. Round-1 finding F2 already proposes the embedded GET; this adds the RPC that also returns settings + home members so the login tail is one hop.
- **Mechanism:** extra sequential round trips: 5 + 1 (settings/members wave) = 6 hops (~8.4 s) of sub-kilobyte lookups before buildNav.
- **Who feels it:** Every login and every session resume, every user.

- **Fix:**

```sql
create or replace function user_context(p_user_id bigint) returns jsonb language sql stable security definer as $$
select jsonb_build_object(
  'user', (select jsonb_build_object('id', id, 'person_id', person_id, 'username', username, 'active', active, 'must_set_password', must_set_password) from system_users where id = p_user_id),
  'person', (select to_jsonb(p) from people p join system_users su on su.person_id = p.id where su.id = p_user_id),
  'roles', (select coalesce(jsonb_agg(to_jsonb(r)),'[]') from user_roles ur join roles r on r.id = ur.role_id where ur.user_id = p_user_id),
  'permissions', (select coalesce(jsonb_agg(distinct name),'[]') from (
       select pm.name from user_roles ur join role_permissions rp on rp.role_id = ur.role_id join permissions pm on pm.id = rp.permission_id where ur.user_id = p_user_id
       union select pm.name from user_permission_overrides o join permissions pm on pm.id = o.permission_id where o.user_id = p_user_id and o.granted
       except select pm.name from user_permission_overrides o join permissions pm on pm.id = o.permission_id where o.user_id = p_user_id and not o.granted) x),
  'regions', (select coalesce(jsonb_agg(region_id),'[]') from system_user_regions where system_user_id = p_user_id),
  'branches', (select coalesce(jsonb_agg(branch_id),'[]') from system_user_branches where system_user_id = p_user_id),
  'settings', (select coalesce(jsonb_object_agg(key, value),'{}') from settings),
  'home_org_member_ids', (select coalesce(jsonb_agg(distinct person_id),'[]') from home_organisation_members)) $$;

Client: `const ctx = await apiGet('rpc/user_context', 'p_user_id=' + userId);` replaces 11064-11097 and, in enterApp, loadAppSettings/ensureHomeOrgMembers (keep preloadLookups as is — the constraint forbids touching the lookup cache). The path /sb/rpc/user_context does not match the system_users scrub regex (sb.js:265) and returns no credential columns anyway. Note: revoke the anon grant on the function if the anon key is ever exposed — today only the proxy calls PostgREST. Equivalent single embedded GET (no DB change): `system_users?id=eq.X&select=id,person_id,username,active,must_set_password,people!system_users_person_id_fkey(*),user_roles(roles(*,role_permissions(permissions(name)))),system_user_regions(region_id),system_user_branches(branch_id),user_permission_overrides(granted,permissions(name))`.
```

### SRV-7 — Views engagements_labelled (engagement + lead/deal/org/site/owner labels, category, stream label, people, milestones) and org_last_touch: server-side scope and joins for Engagement History, Attention, Internal Activity, Milestones, Reports and the org-touch aging rule

**Impact high · effort M · db view or rpc · reviewer (confidence 0.8)**

- **Where:** index.html:16536-16620 (_engHistLoad), 16674-16688 (client-side Own/All scope after download), 12373-12405 (_attentionActionRows), 26443-26457 (Internal Activity), 24794-24803 (milestones register), 24430-24452 (activity report), 14286-14299 (_loadOrgTouches, whole engagements table), 25139-25149 (lead group engagements), 16461-16466 (_engHistCat category rule)
- **Evidence:** 16544 `apiGet('engagements', base+fromQ+toQ+'&select=*&order=...&limit=1000')` then 16688 `if (scope === 'mine' && me) rows = rows.filter(r => String(r.ownerId) === String(me) || String(r.e.created_by) === String(me))` — the 1000-row cap is spent on everyone's rows before the user's own are kept. Parent/org/owner/people/milestone/stream-label joins are 4 + ceil(N/150) + ceil(M/150) + 2 further hops (16548-16588). 14290 `apiGet('engagements','org_id=not.is.null&select=org_id,engagement_date,work_mode')` downloads every org-linked engagement ever, on every leads-register render (14748) and dashboard render (12146), to compute a max() per org. Category rule at 16461-16466 is a pure function of deals.stage_id and service_sub.is_recurring. FKs for the joins exist (engagements_lead_id_fkey, engagements_deal_id_fkey, engagement_people_*_fkey, deals_org_id_fkey, leads_target_org_id_fkey schema.sql:2596).
- **Mechanism:** extra sequential round trips (6-18) + over-fetch (1000 select=* rows regardless of scope; whole engagements table for org touches) + O(rows x lookups) Array.find joins.
- **Who feels it:** Engagement History (4 nav entries) on every open and every date/category change; Attention Workbench; Internal Activity; Milestones; Reports; and the org-touch scan on every Leads register and dashboard load.

- **Fix:**

```sql
create or replace view engagements_labelled as
select e.*,
  case when e.lead_id is not null then 'lead' when e.deal_id is not null then 'deal' else 'project' end as parent_kind,
  coalesce(e.lead_id, e.deal_id, e.work_project_id) as parent_id,
  coalesce(d.name, l.description) as parent_label,
  coalesce(l.owner_id, d.owner_id) as owner_id,
  coalesce(o_d.id, o_l.id, s_l.organisation_id) as client_org_id,
  coalesce(o_d.name, o_l.name, l.target_org_name) as client_name,
  l.site_name as lead_site_name, s_l.name as lead_site, d.stage_id, d.service_sub_id,
  case when e.lead_id is not null then 'Outreach'
       when d.stage_id = 6 then 'Sales'
       when d.stage_id in (5,7,8) then case when ss.is_recurring = false then 'Project' else 'Contract' end
       else 'Sales' end as category,
  (e.lead_id is null and d.stage_id = 6) as lost,
  coalesce(root.stream_label, 'Stream #' || coalesce(e.stream_id, e.id)) as stream_label_resolved,
  (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', trim(concat_ws(' ', p.first_name, p.last_name)))),'[]')
     from engagement_people ep join people p on p.id = ep.person_id where ep.engagement_id = e.id) as persons,
  (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'type_id', m.milestone_type_id, 'status', m.status)),'[]')
     from engagement_milestones m where m.engagement_id = e.id) as milestones
from engagements e
left join leads l on l.id = e.lead_id
left join sites s_l on s_l.id = l.site_id
left join organisations o_l on o_l.id = l.target_org_id
left join deals d on d.id = e.deal_id
left join organisations o_d on o_d.id = d.org_id
left join service_sub ss on ss.id = d.service_sub_id
left join engagements root on root.id = coalesce(e.stream_id, e.id);

create or replace view org_last_touch as
select org_id, max(engagement_date) as last_touch from engagements
where org_id is not null and work_mode is distinct from 'internal' group by org_id;
grant select on engagements_labelled, org_last_touch to anon, authenticated, service_role;

Client: history 16544-16588 -> ONE call `apiGet('engagements_labelled', 'category=eq.Outreach&engagement_date=gte.' + from + '&or=(owner_id.eq.' + me + ',created_by.eq.' + me + ')&select=id,engagement_date,engagement_type,notes,next_action,next_action_date,next_action_done,duration_minutes,work_mode,parent_kind,parent_id,parent_label,owner_id,client_name,category,lost,stream_id,stream_label_resolved,persons,milestones&order=engagement_date.desc,id.desc&limit=1000')`; _loadOrgTouches 14290 -> `apiGet('org_last_touch', 'select=*')` (one row per org). Attention/Internal Activity/Milestones/Reports use the same view with their own filters. Indexes: create index engagements_deal_idx on engagements (deal_id); create index engagements_date_idx on engagements (engagement_date desc, id desc); create index engagements_org_idx on engagements (org_id, engagement_date desc) where org_id is not null; create index engagement_people_eng_idx on engagement_people (engagement_id); create index engagement_milestones_eng_idx on engagement_milestones (engagement_id).
```

### SRV-9 — saveRevenueStream can be ONE upsert today: the UNIQUE(stream_id, month) and UNIQUE(deal_id, stream_type) constraints already exist, so PostgREST on_conflict + Prefer: resolution=merge-duplicates replaces the 2N+1 sequential hops and N trigger passes

**Impact high · effort S · query shape · reviewer (confidence 0.9)**

- **Where:** index.html:9378-9410 (saveRevenueStream: 9385 GET stream, 9390 POST stream, 9395-9409 per-month GET then PATCH/POST); constraints sql/schema.sql:2021-2025 (revenue_stream_months_stream_id_month_key UNIQUE (stream_id, month)) and 2029-2033 (revenue_streams_deal_id_stream_type_key UNIQUE (deal_id, stream_type)); api() Prefer header index.html:2051; proxy forwards Prefer verbatim sb.js:293
- **Evidence:** 9395-9409: `for (const [month, vals] of monthEntries) { const existing = await apiGet('revenue_stream_months', `stream_id=eq.${streamId}&month=eq.${month}&select=id`); ... if (existing.length) await api('revenue_stream_months','PATCH', ...) else await api('revenue_stream_months','POST', ...) }` — 2 hops per month, every Save, even for unchanged months (the PATCH still runs the audit diff trigger per row). Contrast commitPromotion 22781 which already bulk-POSTs the same table in one array body. Round-1 OPP-01 reports the loop; the specific enabler (existing unique keys + on_conflict) is what makes the fix a one-liner.
- **Mechanism:** extra sequential round trips: 2N+1 (N=36 -> 73 hops, ~100 s) + N row-level audit executions; the DB already has the key needed for a single set-based upsert.
- **Who feels it:** Every deal Save on the Opportunity form (all sales users), scaling with contract length.

- **Fix:**

```sql
Client only (DB unchanged):
1) api(): accept an optional extra Prefer, e.g. `async function api(table, method, body, params, prefer)` and `'Prefer': prefer || (method === 'POST' || method === 'PATCH' ? 'return=representation' : '')`.
2) saveRevenueStream:
  const st = await api('revenue_streams', 'POST', { deal_id: dealId, stream_type: 'opportunity', locked: false }, 'on_conflict=deal_id,stream_type&select=id', 'resolution=merge-duplicates,return=representation');   // get-or-create in 1 hop
  const rows = monthEntries.map(([month, v]) => ({ stream_id: st[0].id, month, opportunity_revenue: +v.revenue, opportunity_margin: Math.round(v.revenue * marginPct) / 100 }));
  if (rows.length) await api('revenue_stream_months', 'POST', rows, 'on_conflict=stream_id,month', 'resolution=merge-duplicates,return=minimal');
  // optional: delete months the grid no longer has
  await api('revenue_stream_months', 'DELETE', null, `stream_id=eq.${st[0].id}&month=not.in.(${rows.map(r => r.month).join(',')})`);
73 hops -> 2-3. Careful: merge-duplicates on revenue_streams must not clobber `locked` — send only deal_id/stream_type in the upsert body when the stream may exist (PostgREST updates the columns present in the body), or use `resolution=ignore-duplicates` and read back with select=id. With TRG-A1 the single statement fires one audit call instead of N.
```

### TRG-A3 — Lead status derivation was moved out of the DB into per-row client sweeps that PATCH one lead per round trip on every register/dashboard load; put it back as one set-based sweep_leads() RPC (or pg_cron) that mirrors computeLeadStatus

**Impact high · effort M · db view or rpc · reviewer (confidence 0.75)**

- **Where:** sql/lead_lifecycle_B_retire_status_triggers.sql:18-27 and sql/prod_drop_stale_lead_status_triggers.sql:21-27 (why: the old refresh_lead_status rules were obsolete and threw 42P01 after lead_interactions was dropped); replacements index.html:23492-23515 (sweepHoldWake), 23517-23533 (sweepNewToWorking); called from 14752-14753 (leads register) and 12142 (dashboard reminder gate, before anything paints)
- **Evidence:** index.html:23507 `await api('leads', 'PATCH', patch, 'id=eq.' + l.id);` inside `for (const l of due)`; 23526 same inside `for (const l of toFlip)`; each PATCH fires audit_leads (jsonb diff) and leads_log_stage_event (add_lead_stage_events.sql:118-122, INSERT because status changes) plus applyGroupStageCohesion (14395) per flipped lead (2 GETs + a PATCH per sibling). The predicate is fully expressible in SQL: computeLeadStatus 23431-23461, LEAD_GREEN 23341, leadSourceComplete 23360-23372 (depends only on lead_sources.name and lead columns), leadDetailsComplete 23375, leadTargetComplete 23388-23402 (sweeps pass primaryContact=null so only lead columns are used), leadHasNextStep 23407, leadWaitingMinutes 23354 (settings.new_lead_waiting_minutes). prod_drop_stale_lead_status_triggers.sql:9-13 documents the failure mode that motivated the retirement (status trigger referencing a dropped table); a set-based RPC avoids that class of bug because it has no per-row trigger coupling.
- **Mechanism:** extra sequential round trips: n+m PATCHes (1.4 s each) on the critical path of the leads register and of the dashboard reminder gate (12142 runs before renderDashboard paints); plus n+m trigger executions and stage-event inserts, plus the group-cohesion fan-out.
- **Who feels it:** Every user opening the Leads register or the dashboard on a day when any lead is due to wake or flip — the page stalls 1.4 s per affected lead before rendering; managers with many leads feel it most.

- **Fix:**

```sql
create or replace function lead_source_complete(l leads) returns boolean language sql stable as $$
  select case s.name
    when 'Referral' then l.source_person_id is not null or (l.source_person_name ~ '\S+\s+\S+' and (nullif(trim(l.source_person_email),'') is not null or length(regexp_replace(coalesce(l.source_person_phone,''),'\D','','g')) >= 10))
    when 'Client Expansion' then l.source_org_id is not null
    when 'Marketing Campaign' then l.research_campaign_id is not null
    when 'Research Campaign' then l.research_campaign_id is not null
    when 'Research' then l.research_campaign_id is not null
    when 'Research Study' then l.sales_campaign_id is not null
    when 'Sales Campaign' then l.sales_campaign_id is not null
    else nullif(trim(l.source_detail),'') is not null end
  from lead_sources s where s.id = l.source_id $$;

create or replace function lead_working_prereqs(l leads) returns boolean language sql stable as $$
  select lead_source_complete(l) and nullif(trim(l.description),'') is not null
     and (l.target_person_id is not null or (l.target_person_name ~ '\S+\s+\S+'
          and (nullif(trim(l.target_person_email),'') is not null or length(regexp_replace(coalesce(l.target_person_phone,''),'\D','','g')) >= 10))) $$;

create or replace function sweep_leads() returns jsonb language plpgsql security definer as $$
declare v_grace int; v_working bigint[]; v_woke bigint[];
begin
  select coalesce(nullif(value,'')::int,0) into v_grace from settings where key = 'new_lead_waiting_minutes';
  with f as (update leads l set status = 'Working', working_at = coalesce(l.working_at, now()), updated_at = now()
             where l.status = 'New' and l.dead_reason is null and l.wake_date is null and l.promoted_at is null
               and l.first_engaged_at is not null and l.next_action is not null and l.next_action_date is not null
               and lead_working_prereqs(l) returning l.id)
  select coalesce(array_agg(id),'{}') into v_working from f;
  with w as (update leads l set wake_date = null, woke_at = now(), working_at = coalesce(l.working_at, now()), updated_at = now(),
             status = case
               when l.fit = 2 and l.trigger_score = 2 and l.access = 2 and l.capacity = 2 and l.service_major_id is not null
                    and (l.target_org_id is not null or nullif(trim(l.target_org_name),'') is not null)
                    and coalesce(l.qualification_demoted, false) = false then 'Qualified'
               when l.working_at is not null and now() - l.working_at >= make_interval(mins => v_grace) then 'Working'
               when lead_working_prereqs(l) and l.next_action is not null and l.next_action_date is not null and l.first_engaged_at is not null then 'Working'
               else 'New' end
             where l.status = 'Hold' and l.wake_date <= current_date and l.promoted_at is null and l.dead_reason is null returning l.id)
  select coalesce(array_agg(id),'{}') into v_woke from w;
  return jsonb_build_object('working', to_jsonb(v_working), 'woke', to_jsonb(v_woke));
end $$;

Client: replace lines 14752-14753 and 12142 with one `await api('rpc/sweep_leads','POST',{},'')` (proxy path rewrite sb.js:253 maps /sb/rpc/sweep_leads -> /rest/v1/rpc/sweep_leads; add 'rpc/sweep_leads' to READ_ONLY_WRITE_ALLOW at 11188 or skip it for read-only users) and run applyGroupStageCohesion for the returned ids. Or schedule it and drop the client call entirely: `select cron.schedule('focus_sweep_leads','*/10 * * * *',$$select sweep_leads()$$);` (pg_cron is available on Supabase). Keep the JS computeLeadStatus and this SQL in step — or expose the SQL rule as a `derived_status` column on a leads view so there is one source of truth.
```

### SRV-8 — RPC ownership_scope(p_person_id) replaces _ensureOwnershipScope's three whole-table downloads (leads incl. the contacts jsonb, deals, deal_contacts) on every Clients / Contacts page load

**Impact medium · effort S · db view or rpc · reviewer (confidence 0.8)**

- **Where:** index.html:3468-3489 (_ensureOwnershipScope), called at 3597-3604 inside loadTable for pages 'clients' (non view-all users) and 'contacts' (all users)
- **Evidence:** 3473-3475 `Promise.all([apiGet('leads','select=owner_id,target_org_id,contacts'), apiGet('deals','select=id,owner_id,org_id'), apiGet('deal_contacts','select=deal_id,person_id')])` then JS set-building at 3478-3486. leads.contacts is a jsonb array per lead (see _persistLeadContacts 18120 and jsonb_array_elements use), so the leads payload carries every contact of every lead just to extract person_ids. Result needed by the page is three small id sets.
- **Mechanism:** over-fetch bytes (three full tables, one with jsonb per row, each page load) + client CPU; and these GETs are unpaged (silent 1000-row truncation risk noted at 2104-2107).
- **Who feels it:** Clients and Contacts pages for every user; also the 'Contacts' button on a client row.

- **Fix:**

```sql
create or replace function ownership_scope(p_person_id bigint) returns jsonb language sql stable security definer as $$
select jsonb_build_object(
  'owned_orgs', (select coalesce(jsonb_agg(distinct x.org_id),'[]') from (
      select org_id from deals where owner_id = p_person_id and org_id is not null
      union select target_org_id from leads where owner_id = p_person_id and target_org_id is not null) x),
  'owned_persons', (select coalesce(jsonb_agg(distinct x.pid),'[]') from (
      select dc.person_id pid from deal_contacts dc join deals d on d.id = dc.deal_id where d.owner_id = p_person_id
      union select (c->>'person_id')::bigint from leads l cross join lateral jsonb_array_elements(coalesce(l.contacts,'[]'::jsonb)) c
            where l.owner_id = p_person_id and (c->>'person_id') is not null) x),
  'contact_persons', (select coalesce(jsonb_agg(distinct x.pid),'[]') from (
      select person_id pid from deal_contacts
      union select (c->>'person_id')::bigint from leads l cross join lateral jsonb_array_elements(coalesce(l.contacts,'[]'::jsonb)) c
            where (c->>'person_id') is not null) x)) $$;

Client: `const s = await apiGet('rpc/ownership_scope', 'p_person_id=' + me); ownedOrgs = new Set(s.owned_orgs); ...` — one hop returning a few hundred integers. Indexes: leads (owner_id) exists; add deals (owner_id) (SRV-2) and deal_contacts (deal_id).
```

### TRG-A1 — audit_row_change is a per-row plpgsql diff that re-parses the request headers and builds two full jsonb documents for every row of every bulk statement; make it statement-level with transition tables

**Impact medium · effort M · db trigger · reviewer (confidence 0.65)**

- **Where:** sql/add_audit_log.sql:29-66 (function), 72-84 (attached FOR EACH ROW to 17 tables); bulk statements that pay it: index.html:16789-16791 (applyEngShift PATCH id=in.(<=150)), 22781 (POST N revenue_stream_months), 22808 (POST K engagement copies), 22834 (PATCH close K originals), 9395-9409 (saveRevenueStream one row per hop)
- **Evidence:** add_audit_log.sql:38-40 parses current_setting('request.headers')::json PER ROW; 44-48: `from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o on o.key = n.key where n.value is distinct from o.value and n.key <> 'updated_at'` — two to_jsonb() of a 60-column leads row plus a hash join of ~60 keys, then jsonb_object_agg, then an INSERT maintaining 3 b-tree indexes (audit_log_at_idx, audit_log_row_idx, audit_log_actor_idx, lines 25-27). Trigger is `after insert or update or delete ... for each row` (line 82). A 150-row applyEngShift PATCH therefore runs the function 150 times; a 36-month forecast save runs it 36 times (72 with the GET-then-write pattern). The trigger runs on leads/organisations/people whose rows carry long text (description, notes) and jsonb (leads.contacts), so to_jsonb(old)/to_jsonb(new) copy those every time.
- **Mechanism:** trigger work: O(rows x columns) jsonb construction + per-row header JSON parse + per-row INSERT with 3 index maintenances, executed inside the same transaction as the user's write, so it adds directly to the latency of every PATCH/POST (estimate 0.2-0.6 ms per row on Supabase small compute; 150-row statements add ~50-100 ms; the per-row leads diff also runs 3x per engagement log via TRG-A2). Second-order to the 1.4 s proxied hop today, first-order once bulk statements replace the per-row loops (SRV-5, SRV-9).
- **Who feels it:** Every write in the app (deal save, engagement log, promote, bulk shift, org merge, sweeps) — felt as extra tens of ms per statement now, and as WAL/disk growth (TRG-A4). Anyone saving a forecast or promoting a lead.

- **Fix:**

```sql
Replace the row trigger with ONE statement-level trigger per event using transition tables (actor resolved once per statement, diff done set-wise):

create or replace function audit_stmt() returns trigger language plpgsql security definer as $$
declare v_actor bigint;
begin
  begin v_actor := nullif(nullif(current_setting('request.headers', true),'')::json->>'x-actor-id','')::bigint;
  exception when others then v_actor := null; end;
  if tg_op = 'INSERT' then
    insert into audit_log(actor_id, table_name, row_id, op, row_data)
    select v_actor, tg_table_name, (to_jsonb(n)->>'id')::bigint, 'INSERT', to_jsonb(n) from new_rows n;
  elsif tg_op = 'DELETE' then
    insert into audit_log(actor_id, table_name, row_id, op, row_data)
    select v_actor, tg_table_name, (to_jsonb(o)->>'id')::bigint, 'DELETE', to_jsonb(o) from old_rows o;
  else
    insert into audit_log(actor_id, table_name, row_id, op, changes)
    select v_actor, tg_table_name, (nj->>'id')::bigint, 'UPDATE', d.changes
    from (select to_jsonb(n) nj, to_jsonb(o) oj from new_rows n join old_rows o on o.id = n.id) x
    cross join lateral (
      select jsonb_object_agg(k, jsonb_build_object('o', oj->k, 'n', nj->k)) changes
      from jsonb_object_keys(nj) k
      where k not in ('updated_at','last_seen_at') and nj->k is distinct from oj->k) d
    where d.changes is not null;
  end if;
  return null;
end $$;

-- per table (loop as add_audit_log.sql does): three triggers because REFERENCING is per event
execute format('create trigger audit_ins_%1$I after insert on %1$I referencing new table as new_rows for each statement execute function audit_stmt()', t);
execute format('create trigger audit_upd_%1$I after update on %1$I referencing old table as old_rows new table as new_rows for each statement execute function audit_stmt()', t);
execute format('create trigger audit_del_%1$I after delete on %1$I referencing old table as old_rows for each statement execute function audit_stmt()', t);

Same audit_log rows and same x-actor-id semantics (sb.js:290-296 still forwards the header), one function call per PostgREST statement instead of one per row. Keep the row-level version only for tables without an id column (none in the current list).
```

### TRG-A2 — engagements_refresh_next_action fires on every engagement write (including the two extra PATCHes the client makes per log) and unconditionally rewrites the leads row, cascading into the leads audit diff and stage-event trigger

**Impact medium · effort S · db trigger · spot-checked (confidence 0.75)**

- **Where:** sql/unify_engagements.sql:52-72 (refresh_lead_next_action: unconditional UPDATE leads ... updated_at = now()), 74-96 (row trigger AFTER INSERT OR DELETE OR UPDATE with no column list); callers: index.html:26257 (POST), 26284 (PATCH stream_id/label), 26309 (PATCH contacts), 16789-16791 (bulk shift), 22834 (promote close PATCH), 22828 (per-copy PATCH)
- **Evidence:** unify_engagements.sql:69-71: `UPDATE public.leads SET next_action = v_next_action, next_action_date = v_next_action_date, updated_at = now() WHERE id = p_lead_id;` — no IS DISTINCT FROM guard, so every engagement write produces a new leads tuple version even when nothing changed. That UPDATE fires audit_leads (add_audit_log.sql:44-48: jsonb diff over the full leads row; skipped only after the diff finds nothing but updated_at) and leads_log_stage_event (add_lead_stage_events.sql:118-122, no-op unless status changed) plus the un-versioned first_engaged_at/last_touch trigger (index.html:23515 comment: 'first_engaged_at is stamped by a DB trigger on engagements'). index.html:26284 `api('engagements','PATCH',{stream_id: engId, stream_label: ...})` and 26309 `api('engagements','PATCH',{contacts: refs})` write the same new row twice more, so one 'Log engagement' = 3 engagement writes -> 3 leads rewrites -> 3 leads diffs. Trigger has no WHEN clause and no UPDATE OF column list (line 95), so a stream_label rename or contacts change re-runs the whole refresh.
- **Mechanism:** trigger work + write amplification: per engagement write = 1 index lookup on engagements (idx_engagements_lead ok) + 1 heap UPDATE of leads (new tuple, ~6 leads b-tree index entries maintained: pkey, idx_leads_owner_id, idx_leads_status, idx_leads_next_action_date, idx_leads_source_id, idx_leads_research_campaign) + full-row jsonb diff. For bulk statements this multiplies: applyEngShift 150 rows -> 150 leads rewrites; promote close-PATCH K rows -> K rewrites of the same lead.
- **Who feels it:** Everyone logging engagements (the most frequent write in the app), bulk due-date shifts, promotions. Also inflates audit_log and WAL, and makes the client's extra PATCHes cost a leads write each.

- **Fix:**

```sql
1) Narrow the event and guard the UPDATE:

create or replace function refresh_lead_next_action(p_lead_id bigint) returns void language plpgsql as $$
declare v_na text; v_nad date;
begin
  if p_lead_id is null then return; end if;
  select next_action, next_action_date into v_na, v_nad from engagements
   where lead_id = p_lead_id and next_action_done = false and next_action is not null and next_action_date is not null
   order by next_action_date asc, id desc limit 1;
  update leads set next_action = v_na, next_action_date = v_nad, updated_at = now()
   where id = p_lead_id and (next_action is distinct from v_na or next_action_date is distinct from v_nad);
end $$;

drop trigger if exists engagements_refresh_next_action on engagements;
create trigger engagements_refresh_next_action
  after insert or delete or update of lead_id, next_action, next_action_date, next_action_done on engagements
  for each row execute function trg_engagements_refresh_next_action();

2) Let the DB default the stream so the client's second PATCH (index.html:26284, 22828, 22876) disappears — identity/serial defaults are applied before BEFORE ROW triggers, so NEW.id is available:

create or replace function engagements_default_stream() returns trigger language plpgsql as $$
begin
  if new.stream_id is null then new.stream_id := new.id; end if;
  return new;
end $$;
create trigger engagements_default_stream before insert on engagements for each row execute function engagements_default_stream();

Client then sends stream_label (and contacts, index.html:26309) in the single POST at 26257: 3 writes -> 1, 3 lead rewrites -> 1.

3) For the bulk paths, a statement-level variant that refreshes each distinct lead once:
create or replace function trg_engagements_refresh_next_action_stmt() returns trigger language plpgsql as $$
begin
  perform refresh_lead_next_action(x.lead_id) from (select distinct lead_id from new_rows where lead_id is not null) x;
  return null;
end $$;
(attach with REFERENCING NEW TABLE AS new_rows for insert/update, OLD TABLE for delete, as in TRG-A1). Supporting index for the refresh SELECT: create index engagements_open_action_idx on engagements (lead_id, next_action_date, id desc) where next_action_done = false and next_action is not null and next_action_date is not null;
```

### SRV-10 — RPC merge_organisations(p_dup, p_keep): the org merge is 13+ sequential hops of unindexed repoint UPDATEs with no transaction

**Impact low · effort S · db view or rpc · reviewer (confidence 0.8)**

- **Where:** index.html:27472-27510 (runOrgMerge: 27488-27489 two GETs, 27490-27493 per-row DELETE/PATCH on sales_campaign_organisations, 27494-27496 `for (const [t, c] of ORG_MERGE_REFS) await api(t,'PATCH',{[c]: keepId}, `${c}=eq.${dupId}`)`, 27497 DELETE), ORG_MERGE_REFS 27438-27448
- **Evidence:** Nine sequential PATCHes `col=eq.dup` on leads.target_org_id, leads.source_org_id, sites.organisation_id, deals.org_id, person_organisation_roles.org_id, campaign_targets.organisation_id, quote_sites.organisation_id, work_projects.organisation_id, organisations.parent_org_id — of these only quote_sites (organisation_id) and campaign_targets have an index (index_inventory.txt / prod_sync:91,838), so 6-7 are sequential scans; each repointed row fires audit (leads/deals/sites/person_organisation_roles are audited) and the comment at 27500-27502 admits the flow can stop midway. previewOrgMerge 27461-27463 issues the same 10 GETs in parallel just to count.
- **Mechanism:** extra sequential round trips (13+) + DB sequential scans + non-atomic multi-table write.
- **Who feels it:** Admins only, occasional — low frequency, but 20+ s per merge and a half-merged state on failure.

- **Fix:**

```sql
create or replace function merge_organisations(p_dup bigint, p_keep bigint) returns jsonb language plpgsql security definer as $$
declare n jsonb := '{}';
begin
  if p_dup = p_keep then raise exception 'same organisation'; end if;
  if exists (select 1 from organisations where id = p_dup and home_organisation) then raise exception 'home organisation'; end if;
  delete from sales_campaign_organisations s where s.organisation_id = p_dup and exists (select 1 from sales_campaign_organisations k where k.organisation_id = p_keep and k.sales_campaign_id = s.sales_campaign_id);
  update sales_campaign_organisations set organisation_id = p_keep where organisation_id = p_dup;
  update leads set target_org_id = p_keep where target_org_id = p_dup;
  update leads set source_org_id = p_keep where source_org_id = p_dup;
  update sites set organisation_id = p_keep where organisation_id = p_dup;
  update deals set org_id = p_keep where org_id = p_dup;
  update person_organisation_roles set org_id = p_keep where org_id = p_dup;
  update campaign_targets set organisation_id = p_keep where organisation_id = p_dup;
  update quote_sites set organisation_id = p_keep where organisation_id = p_dup;
  update work_projects set organisation_id = p_keep where organisation_id = p_dup;
  update organisations set parent_org_id = p_keep where parent_org_id = p_dup;
  delete from organisations where id = p_dup;
  return jsonb_build_object('ok', true);
end $$;
Client: `await api('rpc/merge_organisations', 'POST', { p_dup: dupId, p_keep: keepId }, '')` — one atomic hop. Indexes that make the repoints and previews index scans: leads (target_org_id), leads (source_org_id), sites (organisation_id), deals (org_id), person_organisation_roles (org_id), work_projects (organisation_id), organisations (parent_org_id).
```

### TRG-A4 — audit_log grows without bound (17 tables, full-row snapshots, 3-6 rows per engagement log, 36-72 per forecast save, ~15+3K per promote) with no retention, no partitioning and an index shape that does not serve the per-record history lookup

**Impact low · effort S · db trigger · reviewer (confidence 0.6)**

- **Where:** sql/add_audit_log.sql:14-27 (table + 3 indexes; no partitioning, no retention); volume sources: index.html:26257/26284/26309 (3 engagement writes per log), 9395-9409 & 22781 (per-month rows), 22808-22848 (2K engagement rows + K lead diffs per promote), 16789-16791 (150 rows per shift chunk); reader: index.html:13861-13867 (renderAuditLogPage, order=at.desc,id.desc with optional table_name/row_id/actor/op filters), sql/add_lead_stage_events.sql:45-66 (backfill scans audit_log)
- **Evidence:** add_audit_log.sql:53 stores `to_jsonb(new)` for every INSERT (a leads row is ~60 columns incl. description text and contacts jsonb; people/organisations similar). No `delete from audit_log`, no partition, no pg_cron job anywhere in sql/. Indexes: (at desc), (table_name,row_id), (actor_id) — the admin page filters by table_name+row_id then orders by at desc, which the (table_name,row_id) index cannot satisfy without a sort; filtering by op alone (13863) is a sequential scan. Volume is an assumption (cannot query prod): at ~10 users x ~30 audited writes/day x ~2 rows each -> ~1k rows/day, ~0.5-1 KB each with jsonb -> ~0.3-0.5 GB/year including 3 indexes; every trigger INSERT maintains those indexes inside the user's transaction.
- **Mechanism:** trigger work + DB growth: each audited write appends 1-3 rows and 3 index entries; the table and its indexes grow monotonically, making VACUUM, backups and the audit page slower over time; the audit page's non-covering index forces sorts as it grows.
- **Who feels it:** Slow creep on every write (index maintenance) and on the Admin > Audit Log page; disk on the Supabase project. Low today, compounding.

- **Fix:** 1) Retention with pg_cron (Supabase): `create extension if not exists pg_cron; select cron.schedule('focus_audit_retention','15 2 * * *', $$delete from audit_log where at < now() - interval '18 months'$$);` — or monthly range partitioning so old months drop instantly: `create table audit_log_p (like audit_log including all) partition by range (at);` + pg_partman (`select partman.create_parent('public.audit_log_p','at','native','monthly')`) and a one-off copy. 2) Serve the admin page's real predicate: `create index audit_log_rec_idx on audit_log (table_name, row_id, at desc, id desc); drop index audit_log_row_idx;` and add `create index audit_log_table_at_idx on audit_log (table_name, at desc)` for table-only filters. 3) Stop snapshotting high-churn child rows: drop revenue_stream_months, engagement_people and deal_collaborators from the trigger list at add_audit_log.sql:76-80 and audit the parent (revenue_streams / engagements / deals) instead — a forecast save then costs 1 audit row, not 36-72. 4) With TRG-A1 the diff excludes updated_at/last_seen_at set-wise, so no-op rows never reach the log.

### TRG-A5 — trg_orgs_link_freetext_leads sequential-scans leads with lower(trim(target_org_name)) on every organisations INSERT and every name/legal_name UPDATE, inside the user's write

**Impact low · effort S · db index · reviewer (confidence 0.8)**

- **Where:** sql/schema.sql:224-244 (function), 2293 (trigger: AFTER INSERT OR UPDATE OF name, legal_name ON organisations FOR EACH ROW); fired by index.html:22574 and 22589 (promote org create/patch), findOrCreateProspectOrg (23755 via saveLead), org edits in the admin table and confirmSecureLegalName 9503
- **Evidence:** schema.sql:227-240: `UPDATE leads SET target_org_id = NEW.id ... WHERE target_org_id IS NULL AND target_org_name IS NOT NULL AND (lower(trim(target_org_name)) = lower(trim(NEW.name)) OR (...legal_name...))`. No index on leads.target_org_id (fk_columns.txt has the FK, index_inventory.txt has none) and no expression index on lower(trim(target_org_name)), so the planner has nothing to use: a full scan of leads evaluating lower(trim()) twice per row, per organisation write. If any lead matches, that UPDATE then fires audit_leads (jsonb diff) per matched row.
- **Mechanism:** DB sequential scan inside a trigger on the write path; cost scales with the leads table (assumption: a few thousand leads -> 2-10 ms today; grows linearly). Also runs on every promote because 22589 PATCHes the org name/legal_name.
- **Who feels it:** Anyone creating or renaming an organisation (lead capture, promote, securing legal-name prompt). Small today; listed because the prompt asked and because it is a free fix.

- **Fix:**

```sql
create index if not exists leads_freetext_org_idx on leads (lower(trim(target_org_name))) where target_org_id is null and target_org_name is not null;
-- and stop firing when neither name actually changed:
drop trigger if exists orgs_link_freetext_leads on organisations;
create trigger orgs_link_freetext_leads after insert or update of name, legal_name on organisations
  for each row when (tg_op = 'INSERT' or new.name is distinct from old.name or new.legal_name is distinct from old.legal_name)
  execute function trg_orgs_link_freetext_leads();
(Note: a WHEN clause cannot reference OLD on INSERT, so split into two triggers if Postgres rejects the combined form.)
```


## Refuted during verification

- **D9** (dashboard) — Interactions widget: date-range scan of engagements over 3-12 months with no index, then chunked second passes over leads/deals for scope and category: Code confirmed (12500-12524, 12541 toISOString per engagement per period). But the substantive fix — one embedded engagements fetch dropping all three chunk loops — is exactly D3's Interactions fix, and the engagements(engagement_date) index is listed in D13. Unique remainder (hoisting iso(p.s)/iso(p.e) out of the loop; `leads?owner_id=eq.me&select=id` beating id-chunks) is trivial. Correction to the trace: own-scope depth is 4 (engs -> lead chunks -> deal chunks -> deal chunks), not 2.
