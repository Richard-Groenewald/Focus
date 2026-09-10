# Focus CRM — Proposal Generator — Design Brief

Status: **Increment 1 built in v7.9.41** (2026-09-10): Accessories / Training admin pages and per-post checklists, proposal tables and default template (`sql/proposal_generator_inc1.sql`), the Proposal tab with section list, live A4 preview, per-proposal section edits on a draft row, and Print / Save PDF. **Increment 2 built in v7.9.42**: `issue_proposal()` / `withdraw_proposal()` RPCs (`sql/proposal_generator_inc2.sql`), numbering, immutable versions with a history panel, the Proposal engagement and the offered stage move, and the Proposal column on the quote list. Increment 3 (Word export, support-item sections) remains design only. Written 2026-09-10 against Focus v7.9.40. This brief is meant to be handed to a Claude Code session (or read by Richard) and implemented against the real schema. Column names quoted here were verified in `sql/quote_tool_phase_b.sql`, `sql/quote_tool_phase_b3.sql` and `sql/add_sandbox_quotes.sql`; anything marked *assumed* must be checked on Dev first.

---

## 1. What it is, in one paragraph

The Proposal Builder already captures *what we would deliver and at what price* (a `quote_quotes` row with its posts, shifts, allowances and, once the support-item tabs land, its contract and mobility lines). The **Proposal Generator** turns one saved quote into the **client-facing proposal document** for the deal's Proposal stage (stage 3): a branded, numbered, versioned document that sales previews in Focus, prints or saves as PDF, optionally exports to Word for hand-editing, and *issues* — at which point Focus records the fact (quote status, an engagement, the deal stage) so the pipeline knows a proposal is out.

It is a **renderer plus a ledger**. It never prices anything itself.

## 2. Principles (the ones that constrain everything below)

1. **All money on the page comes from the quote's calculation snapshot.** The generator reads a frozen calc result and lays it out. It does not re-derive prices from posts, rates or margins — the same rule as "TCV comes from revenue streams only". A proposal issued today must print the same numbers in six months, so the snapshot, not the live rate cards, is the source.
2. **One quote, many proposal versions; each issued version is immutable.** Re-issuing after a client conversation creates version N+1. Version N stays readable exactly as it went out.
3. **Templates are data, not code.** Standard headings, boilerplate, terms and the section order live in tables an admin edits under Admin → Proposal Builder, the same way Standard Posts and Standard Headings already do. Deploying Focus should never be required to change proposal wording.
4. **Client-side rendering, no new infrastructure.** Focus is a single HTML file on Netlify plus one proxy function. Netlify functions cannot run a browser, so PDF generation is the user's browser (print-to-PDF over print CSS). Word export is a client-side library from an allowed CDN. No storage bucket is needed for v1 because the rendered HTML is small and lives in a column.
5. **One round trip to open a proposal.** Follow the Tier 2 pattern: an RPC returns the whole bundle, with a per-table fallback when the RPC is absent (404 / PGRST202), so SQL and client can ship independently.
6. **Sandbox quotes can be previewed, never issued.** The preview carries a SANDBOX watermark and gets no proposal number.

## 3. Where it lives in the UI

### 3.1 Inside the quote editor
A seventh editor tab, after Site Mobility, in `PB_EDITOR_TABS`:

```
{ id: 'proposal', label: 'Proposal' }
```

The tab shows:

- **Header strip:** template selector (default = template marked `is_default`), language of the document (v1: English only, field reserved), the proposal reference once one exists, current version and status.
- **Section list (left, ~280px):** the ordered sections from the template, each with a toggle (include / exclude) and a "customised" dot when the user has overridden the section text for this proposal.
- **Preview (right):** the rendered document at A4 width, live. Editing a section opens a plain textarea (or the existing rich-note editor if Focus has one) for that section only; merge fields stay as `{{tokens}}` in the editor and render resolved in the preview.
- **Action bar:** `Preview full screen`, `Print / Save PDF`, `Export Word`, `Issue v1` (or `Issue v2…`), `Discard draft`. Issue is disabled when: the quote has no calc snapshot, the quote is a sandbox, the user lacks `issue_proposal`, or a mandatory section is empty.

### 3.2 On the Opportunity page
The existing Proposal Builder list gains a column **Proposal** showing `—`, `draft`, or `P-2026-0042 v2 · issued 3 Sep`. Clicking it opens the quote on the Proposal tab.

### 3.3 Admin
Under Admin → Proposal Builder, a new page **Proposal Templates** (permission `administer_quote_rates`, same as the other builder admin pages). Today's `pb_system_settings` placeholder is the natural home for the two global settings (numbering prefix, default validity days) once that page is built; until then they are seeded rows in the existing `settings` table (*assumed name — verify*).

## 4. The document

### 4.1 Default section set (seeded, editable)
| # | Section key | Source of content | Mandatory |
|---|---|---|---|
| 1 | `cover` | Merge fields: client, site, contract name, proposal ref, date, validity, prepared by | yes |
| 2 | `intro_letter` | Template boilerplate + merge fields | yes |
| 3 | `about_xone` | Template boilerplate | no |
| 4 | `understanding` | Template prompt text; sales writes per proposal (deal `notes` / lead `description` pre-filled as a starting point) | yes |
| 5 | `scope_posts` | **Generated table**: heading → post, uniform, shift pattern, officers per shift, days covered, then two bullet lists per post: **Required Accessories** and **Training** (see 4.4). From `quote_posts`, `quote_post_shifts`, `quote_post_accessories`, `quote_post_training` | yes (auto) |
| 6 | `scope_support` | Generated from support-item lines when those tabs exist; hidden while they are placeholders | no |
| 7 | `pricing` | **Generated table** from the snapshot: per post monthly price, sub-totals per heading, monthly total, contract total over `contract_duration_months`, VAT line | yes (auto) |
| 8 | `assumptions` | Template boilerplate + auto-bullets (public-holiday handling, replacement pool, annual escalation wording) | yes |
| 9 | `terms` | Template boilerplate (validity, payment terms, escalation, termination) | yes |
| 10 | `acceptance` | Signature block, merge fields | yes |

Section keys are fixed identifiers; titles, order and boilerplate are template data. A template may add free sections (`custom_1`…) with arbitrary keys.

### 4.2 Merge fields
Resolved in one place, `pgFields(bundle)`, and documented on the admin page so template authors see the list:

`{{client.name}}` `{{client.legal_name}}` `{{client.address}}` `{{contact.name}}` `{{contact.title}}` `{{site.name}}` `{{site.address}}` `{{quote.contract_name}}` `{{quote.start_date}}` `{{quote.duration_months}}` `{{quote.valid_until}}` `{{proposal.ref}}` `{{proposal.version}}` `{{proposal.date}}` `{{pricing.monthly_total}}` `{{pricing.contract_total}}` `{{pricing.monthly_total_incl_vat}}` `{{owner.name}}` `{{owner.title}}` `{{owner.email}}` `{{owner.phone}}` `{{xone.legal_name}}` `{{xone.reg_no}}` `{{xone.psira_no}}` `{{xone.vat_no}}`

Unknown tokens render as a red `{{token?}}` in preview and block Issue.

Contact = the deal's primary contact from `deal_contacts` (*assumed a primary flag exists — verify; otherwise the first contact, with a picker in the header strip*). Site = `quote_sites` via `quote_quotes.site_id`, falling back to the organisation's address.

### 4.4 Per-post Accessories and Training (dynamic lists)

The current Xone tool shows, under each post, two checklists — **Required Accessories** (pocket book, restraints, baton, torch, body-worn camera, site gun safe, … ) and **Training** (induction, control room operators, Regulation 21, fire fighting, first aid 1-3, …). Both lists are **dynamic**: site admin maintains them under Proposal Builder, and a post simply ticks the ones that apply.

Focus already has the schema for this (`sql/quote_tool_phase_b2.sql`): the catalogues `quote_accessories` and `quote_training_courses` (`code`, `name`, `display_order`, `active`) and the toggle tables `quote_post_accessories` and `quote_post_training` (presence of a row = ticked). **Nothing in `index.html` reads them yet, and there is no admin page**, so the generator design includes the three missing pieces:

1. **Admin catalogues.** Two pages under Admin → Proposal Builder, `pb_accessories` ("Accessories") and `pb_training_courses` ("Training Courses"), permission `administer_quote_rates`, built on the same simple list editor as Standard Posts / Standard Headings: name, display order, active toggle, drag or number to reorder. Deactivating an item hides it from new ticks but keeps it on posts that already have it (and on issued proposals, which are frozen anyway).
2. **Posts tab checklists.** Each post's expanded detail gains two columns, *Required Accessories* and *Training*, rendered as checkboxes from the active catalogue in `display_order`, exactly as in the current tool. A tick inserts a row, an untick deletes it (`Prefer: return=minimal`); no re-download. The catalogues load in `openQuote` round 1 alongside grades and areas; the two per-post toggle tables join the existing round-2 `Promise.all` keyed on the post ids (six child tables instead of four, still one round trip).
3. **In the document.** `scope_posts` prints, under each post, "Accessories: …" and "Training: …" as comma-separated names in catalogue order, or omits the line when nothing is ticked. Both are captured into `content_json` at issue so a later catalogue rename cannot alter an issued proposal. Whether accessories carry a price on the proposal is a Contract Support Items question (the schema comment says cost lives there later); until then they are descriptive only and the pricing section does not mention them.

The reference seed for both lists is already in `quote_tool_phase_b2.sql`; compare it with the current tool's lists (the screenshot from Richard, 2026-09-10, includes items such as *Torch/Spotlight - Zartek hand held*, *9mm Parabellum*, *Snake Handling*, *Regulation 21*) and top up the seed on Dev before Increment 1.

### 4.3 Print and Word
- **Print / PDF:** a `@media print` stylesheet scoped to `#pg-doc` hides Focus chrome, sets A4 with 18 mm margins, repeats a running header (Xone logo, proposal ref, page x of y via CSS counters where supported) and forces page breaks before `pricing` and `acceptance`. Arial throughout, brand colours: navy `#003057` headings, red `#FA0A11` rules only. The user uses the browser's Save as PDF. This is the zero-dependency path and is what v1 ships.
- **Word export (v1.1):** `docx` (UMD build from cdnjs, pinned version) walks the same section model and emits paragraphs and tables. Load it lazily on first click so the main bundle does not grow. The `.docx` is downloaded in the browser; nothing is stored server-side.
- Both paths render from the **stored `content_json`**, not from the live DOM, so print and Word cannot diverge from what was issued.

## 5. Data model (additive, house style: BEGIN/COMMIT, IF NOT EXISTS, verification SELECTs)

```sql
-- Templates -----------------------------------------------------------
CREATE TABLE proposal_templates (
  id            BIGSERIAL PRIMARY KEY,
  name          TEXT NOT NULL UNIQUE,            -- 'Manpower — On-Site Guarding (standard)'
  service_scope TEXT,                            -- optional hint: which service type this suits
  is_default    BOOLEAN NOT NULL DEFAULT false,
  active        BOOLEAN NOT NULL DEFAULT true,
  created_by    BIGINT REFERENCES people(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_proposal_templates_default ON proposal_templates (is_default) WHERE is_default;

CREATE TABLE proposal_template_sections (
  id            BIGSERIAL PRIMARY KEY,
  template_id   BIGINT NOT NULL REFERENCES proposal_templates(id) ON DELETE CASCADE,
  section_key   TEXT NOT NULL,                   -- 'cover', 'pricing', 'custom_1' …
  title         TEXT NOT NULL,
  display_order SMALLINT NOT NULL DEFAULT 0,
  kind          TEXT NOT NULL CHECK (kind IN ('boilerplate','prompt','generated')),
  body          TEXT,                            -- boilerplate / prompt text with {{tokens}}
  mandatory     BOOLEAN NOT NULL DEFAULT false,
  page_break_before BOOLEAN NOT NULL DEFAULT false,
  UNIQUE (template_id, section_key)
);

-- Documents ----------------------------------------------------------
CREATE SEQUENCE proposal_ref_seq;                -- one number per ISSUED proposal, never per draft

CREATE TABLE proposal_documents (
  id               BIGSERIAL PRIMARY KEY,
  quote_id         BIGINT NOT NULL REFERENCES quote_quotes(id) ON DELETE CASCADE,
  template_id      BIGINT NOT NULL REFERENCES proposal_templates(id),
  snapshot_id      BIGINT REFERENCES quote_snapshots(id),   -- the calc result the figures came from; NOT NULL once issued (enforced by trigger)
  version          SMALLINT NOT NULL DEFAULT 1,
  status           TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','issued','superseded','withdrawn')),
  proposal_ref     TEXT,                                     -- 'P-2026-0042', assigned at issue
  issued_at        TIMESTAMPTZ,
  issued_by        BIGINT REFERENCES people(id),
  valid_until      DATE,
  content_json     JSONB NOT NULL DEFAULT '{}'::jsonb,       -- resolved sections + merge values + pricing rows at issue time
  rendered_html    TEXT,                                     -- frozen HTML of the issued version (print + read-back without re-rendering)
  owner_id         BIGINT REFERENCES people(id),
  created_by       BIGINT REFERENCES people(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (quote_id, version)
);
CREATE UNIQUE INDEX ux_proposal_documents_one_draft ON proposal_documents (quote_id) WHERE status = 'draft';
CREATE UNIQUE INDEX ux_proposal_documents_ref ON proposal_documents (proposal_ref) WHERE proposal_ref IS NOT NULL;

-- Per-proposal overrides of template sections (drafts only; folded into content_json at issue)
CREATE TABLE proposal_document_sections (
  document_id   BIGINT NOT NULL REFERENCES proposal_documents(id) ON DELETE CASCADE,
  section_key   TEXT NOT NULL,
  included      BOOLEAN NOT NULL DEFAULT true,
  body_override TEXT,
  PRIMARY KEY (document_id, section_key)
);

INSERT INTO permissions (name, description) VALUES
  ('issue_proposal', 'Issue (number and freeze) a proposal document to a client')
ON CONFLICT (name) DO NOTHING;
```

Notes:
- `quote_snapshots` already exists and is the right anchor; the generator requires the latest snapshot to be newer than `quote_quotes.updated_at`, otherwise it asks the user to recalculate first. (Today `pbCostPerOfficer` is a stub with hard-coded grade prices, and no snapshot is written; **the calc engine landing is a hard dependency for the pricing section**. Everything else in this brief can be built and tested against a hand-inserted snapshot row.)
- `rendered_html` is bounded (a proposal is tens of KB). If it ever needs the Supabase storage bucket, only the column's home changes.
- Numbering: `P-<year>-<zero-padded seq>` assigned inside the `issue_proposal()` RPC in one transaction with the status flip, so two users cannot take the same number.

### 5.1 RPCs
- `proposal_bundle(p_quote_id)` → one jsonb: quote (via `v_quote_quotes_full`), organisation, primary contact, site, posts with shifts, latest snapshot, the active template with sections, the current draft document with its overrides, and the issued history list. Client fallback: the same data in two `Promise.all` rounds, mirroring `openQuote`.
- `issue_proposal(p_document_id, p_content jsonb, p_html text)` → assigns the number, freezes content, sets `issued`, marks the previous issued version `superseded`, sets `quote_quotes.status = 'sent'` and `valid_until`, and returns the row. Runs `SECURITY DEFINER`; checks the caller's `issue_proposal` permission through the same `system_users` join Focus uses elsewhere (*verify how existing RPCs read the caller — the proxy passes the service key, so the caller id must arrive as a parameter, as `sweep_leads()` does*).

## 6. Side effects of Issue (the ledger half)

On a successful issue, the client (not the RPC, to keep it in step with existing app-side flows):

1. Inserts an **engagement** on the deal: client-facing, type Proposal (*verify the category/type ids in `engagement_types`*), subject `Proposal P-2026-0042 v1 issued`, linked contact = the proposal's contact. This moves Last Touch, which is correct: a proposal *is* contact.
2. Offers, via the existing `confirmDialog`, to move the deal to **stage 3 Proposal** if it is currently at stage 2. Never forces it, never moves a deal backwards.
3. Sets the quote's `status` to `sent` (done in the RPC) and refreshes the in-memory quote row, per the "a write returns the row, splice it in" convention.
4. Optionally proposes the *Proposal issued* milestone if such a type exists for the area; otherwise nothing.

Withdrawing an issued proposal sets `withdrawn`, keeps the number, and logs an internal engagement ("Our own work").

## 7. Permissions and visibility

| Action | Permission |
|---|---|
| Open the Proposal tab, edit a draft, preview, print, export | `create_quote` (existing) |
| Issue / withdraw | `issue_proposal` (new; grant to sales management and, at Richard's call, senior sales) |
| See proposals on quotes you do not own | `view_all_quotes` (existing) |
| Edit templates | `administer_quote_rates` (existing) |

## 8. Mock mode and tests

- `_mockStore()` gains the four tables plus a seeded default template so the tab works offline. The bundle RPC is served in mock mode by assembling the same shape in JS.
- `tests/perf/` harness: extend with `equiv_proposal.js` that renders the fallback path and the RPC path over a Dev snapshot and diffs the HTML, the same way the dashboard and engagement history were proved.
- A unit-style check for the merge resolver: every token in the seeded templates resolves against a fixture bundle, and the unknown-token guard blocks Issue.

## 9. Increments

**Increment 1 — Preview and print (no issuing).** Accessories and Training admin pages plus the per-post checklists (4.4) — they are needed for the scope section and are useful on their own. Then the proposal tables, seeded default template, the Proposal tab with section list and A4 preview, print CSS, merge fields, generated Scope and Pricing tables reading a snapshot. Admin Proposal Templates page (list, edit sections, reorder). Ships behind the presence of `proposal_templates` (absent table → tab hidden), so it can go to Dev first.

**Increment 2 — Issue, number, version, ledger.** `issue_proposal()` RPC, proposal numbering, immutable versions, history on the quote, the engagement and stage-3 offer, `issue_proposal` permission, Proposal column on the quote list.

**Increment 3 — Word export and support sections.** Lazy-loaded `docx` export; `scope_support` and the pricing sub-tables for Workforce / Contract / Service / Mobility items once those builder tabs exist.

**Later, not designed here:** e-signature / acceptance capture writing back to `accepted`; emailing the PDF from Focus (needs an outbound mail path Focus does not have); multi-language templates; a per-client cover-letter library.

## 10. Open decisions for Richard

1. **Who may issue?** Sales management only, or every quote creator? (Design assumes a separate permission so it can be either.)
2. **Numbering format.** `P-2026-0042` is proposed. Should it embed the deal id or the quote id instead of a global sequence?
3. **VAT on the page.** Show monthly and contract totals *excluding* VAT with a VAT line, or both incl. and excl.? The pricing section supports both; the default needs a ruling.
4. **Stage move on issue.** Offer (proposed) versus automatic. Automatic is one line to change.
5. **Where the Xone legal details live** (registration, PSIRA, VAT numbers, signatory titles). Proposed: three rows in the settings table, editable on the future System Settings page. Alternative: columns on the home organisation row (`organisations.home_organisation = true` already exists).
6. **Word export priority.** If sales routinely edit proposals in Word before sending, Increment 3's export should move into Increment 1 and the in-app section editor can stay minimal.

---

## Verification queries to run on Dev before building

```sql
-- Does deal_contacts carry a primary flag?
SELECT column_name FROM information_schema.columns WHERE table_name = 'deal_contacts';
-- Settings table name and shape
SELECT table_name FROM information_schema.tables WHERE table_name IN ('settings','app_settings','system_settings');
-- Engagement types available for the Proposal engagement
SELECT id, name FROM engagement_types ORDER BY id;
-- Any snapshot rows yet?
SELECT count(*) FROM quote_snapshots;
```
