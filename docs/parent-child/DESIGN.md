# Parent and child organisations — design

Richard, 1 November 2026: "we need to rethink parent/child relationships. 1. Parents will mostly be an actual organisation and not just a grouping. grouping should still be allowed by request. 2. If parent is actual company, it should be listed first when displaying."

Status: DESIGN, not built. A 50-agent critique against the code and production data (1 November) confirmed 43 corrections, all folded in. Decisions for Richard are marked **Decide** and collected in section 8.

## 1. Where we are

The v7.9.07–v7.9.11 "collective world" treats a parent as a container: a family is *born* when an organisation gains a second concurrent pursuit, it gets a GROUP or HISTORY badge, a group description seeded from the first pursuit, a group window and group engagements that belong to no lead or deal. The parent row is a real `organisations` row, but nothing in the app treats it as a company you sell to, which is why Lesley-Anne invented the HQ "PARENT" lead.

Production, 1 November 2026:

| Family | Parent kind in practice | Children | Parent's own leads / deals / sites / contacts | Pastel |
|---|---|---|---|---|
| Access World SA (4001) | a company — linked to **itself** as parent | Access World Durban | 0 / 2 / 1 / 1 | XC0205 |
| Leopard Creek Share Block (4084) | a company — linked to **itself** as parent | Country Club, Malelane Airport | 0 / 0 / 0 / 1 | XC0004 |
| Pan African Resources PLC (4153) | a pure holding | Barberton, Evander, Mogale | 0 / 0 / 0 / 0 | — |
| 26 single-organisation "collectives" (SAB, Milco, Premier, Sasol, Exxaro, Sibanye …) | one company with several sites | sites, not organisations | the HQ "PARENT" lead carries the company-level contact | varies |

Facts the design rests on: the family is one level deep everywhere (no grandchildren); `is_parent` has never been set and nothing reads it; University of the Western Cape (4138) is linked to itself with no children; the parent sorts before its child in only 1 of 6 parent/child pairs on a plain alphabetical list; **sites are mostly free text** — the HQ leads and their site siblings carry the site in `leads.site_name` with `site_id` NULL, and three of the four PARENT families (Sasol, Milco, Premier) own no `sites` rows at all; group engagements (`engagements.org_id`) have been used once since v7.10.24 shipped.

## 2. Principles

1. **A parent is a company unless declared otherwise.** It has leads, deals, sites, contacts and a Pastel account like any organisation, and in addition it bands its children.
2. **A grouping is declared, by request.** It is a label with children: it may carry family notes, contacts (**Decide 7**: a holding has a Group Risk Manager) and a family-level engagement, but it can never be the client of a lead, a deal, a site or a quote, is never a client (`is_client` false), and no client picker offers it.
3. **The parent is listed first**: within a family the root comes first, then its children by name. On every list this is a pre-sort inside the family; the user's column sort decides everything else (section 4).
4. **Nothing is born.** A company with two leads is a company with two leads. The family page exists for every organisation. This REVERSES v7.9.09 (born at the second pursuit, one-pursuit organisations inkless, birth a ratchet): the ratchet's purpose — history reachable after the last lead goes — is met by universality instead.
5. **One home per rule.** The family's two settings (notes, "acts as one") live on the family root whatever its kind. Membership is one walk, `_ultimateParentOrg` + descendants (`_familyOrgIds`), already shared by banding, cohesion and Last Contact.

## 3. Data model

### 3.1 `organisations.org_kind`

`org_kind TEXT NOT NULL DEFAULT 'company' CHECK (org_kind IN ('company', 'grouping'))`. Every existing row is a company. A grouping is set on the Organisation form's **Admin** tab (Admin → Organisations only — the field is not in `ORG_DETAIL_FIELDS`, so Manage Clients never shows it) by a holder of `manage_organisations` (**Decide 6**: Admin only?), and `saveRecord` confirms: "A grouping is a label for its member companies. It can hold no leads, opportunities, sites or quotes of its own." A grouping always has `is_client = false`.

**The guard**, one function `org_kind_guard()` (pinned `search_path`) behind BEFORE INSERT OR UPDATE OF &lt;column&gt; triggers. It REFUSES, with a plain message the client shows as-is: `leads.target_org_id`, `deals.org_id`, `sites.organisation_id`, `quote_sites.organisation_id` pointing at a grouping; `organisations.is_client = true` on a grouping; `org_kind` → grouping while the organisation owns any lead, deal, site or quote, or is the home organisation; `parent_org_id = id` (also a CHECK constraint) and any cycle (walk up with a visited set). It ALLOWS a grouping as `organisations.parent_org_id` (its purpose), `engagements.org_id` (the family-level engagement), `leads.source_org_id` (a holding can refer), `campaign_targets` and `sales_campaign_organisations` (a holding can be studied), and `person_organisation_roles` unless Decide 7 says no. `work_projects` and `home_organisation_members` are not reachable for a grouping.

The client never relies on the guard alone — every writer that can reach an organisation filters groupings out first (section 5, Pickers), and the generic error path prints the guard's message rather than the raw 400.

### 3.2 `leads.is_hq`

The company-level lead cannot be derived from `sites` rows (section 1): `is_hq BOOLEAN NOT NULL DEFAULT false`, a tick "Company-level lead (head office)" on the lead form beside the site field, shown as an **HQ** tag on the register and the family page. An HQ lead keeps no site (the form's primary-site defaults are skipped), and promoting one lands the deal on the organisation's primary site rather than materialising "… - PARENT" as a `sites` row. One-off seed: `UPDATE leads SET is_hq = true WHERE site_name ~* 'parent|\\bhq\\b|head ?office' OR id IN (4064)` — SAB 4064, Milco 4067, Premier 4188, Sasol 4059, Exxaro 4156. **Decide 4**: the tag's wording, and whether a one-lead organisation's only lead (Premier-style, ~40 on prod) is HQ by default.

### 3.3 Retired

- `is_parent` — dropped (no view, index, policy, function or SQL file depends on it).
- `maybeBirthCollective` and its four calls (deal save, lead save, promote, lead capture) — removed. `collective_since` stays as history and is no longer read: its two readers, the HISTORY chip (gone, section 4) and the cohesion gate (section 6), are rewritten. Birth also seeded `group_description` from the first pursuit; that seeding stops and existing text stands (**Decide 8**: 15 of the 23 seeded descriptions are backfill text, not family notes — clear them?).
- The self-parent links on 4001, 4084 and 4138 are cleared, then the CHECK makes them impossible. (Those three organisations cannot be saved through the form at all today: the form's own guard refuses the self-link it finds.)

### 3.4 Kept, relabelled

- `parent_org_id` — the one link. The Organisation form's lookup becomes **Parent organisation** with a `lookupFilter`: active, not the home organisation, not the organisation itself, not one of its own descendants; options in family order; a grouping labelled "· grouping". A child may hang under a company or a grouping.
- `group_description` → **Family notes**, typed by hand on the family page. `group_touch_soothes` → **Family acts as one — contact, aging & stage moves**; it gates Last Contact sharing, the aging nag and stage cohesion, between parent and subsidiaries AND between an organisation's own HQ lead and its site leads (Milco's 13, SAB's 10). Today it is on for all 262 rows (**Decide 2**).

### 3.5 Migration — `sql/org_kind.sql`, re-runnable, one transaction

1. The house attribution (`set_config` x-actor-id 4128 / x-real-actor-id 1) and `focus.system = 'migration'` (steps 3, 5 and 6 are audited data changes).
2. `ADD COLUMN IF NOT EXISTS org_kind`, the CHECK, `leads.is_hq`.
3. `UPDATE organisations SET parent_org_id = NULL WHERE parent_org_id = id` (3 rows).
4. `ADD CONSTRAINT organisations_not_own_parent CHECK (parent_org_id IS NULL OR parent_org_id <> id)` — after step 3, never before.
5. **Decide 1**: `org_kind = 'grouping'`, `is_client = false` on Pan African Resources PLC 4153 (it owns nothing in any of the twelve referencing tables).
6. The `is_hq` seed (3.2).
7. `org_kind_guard()` and its triggers; `trg_orgs_link_freetext_leads` re-created with `IF NEW.org_kind = 'grouping' THEN RETURN NEW` first (same body, the v7.10.24 system mark kept), so creating or renaming a grouping never re-points a typed-name lead onto it.
8. `DROP COLUMN is_parent`.
9. Nothing else: `lead_open_bundle`'s `org` key is `to_jsonb(o)` and carries the column at once (`org_chain` is an id list the client does not read); `dashboard_summary` is untouched unless a dashboard surface is later made to draw the kind (if it is ever re-run, pin its `search_path` first — it is the one SECURITY DEFINER bundle without one). No NOTIFY needed: the DDL watch reloads the schema cache.

## 4. The family: one definition, one order, one key

- **Root** = `_ultimateParentOrg(org)`. **Members** = root + descendants. **Kind of the family** = the root's `org_kind`. Unchanged, cycle-safe.
- **`familyOrder(members)`** — the root first, then children by `organisations.name`. (The band label is `organisations.name`, the colloquial name, not `trading_name`, which 9 of 262 rows carry; the stale comments saying otherwise are corrected in the build.)
- **`familySortKey(orgId)`** — one string per organisation, root name · depth (0 root, 1 child) · own name, so any "sort by client" column orders a family together with its parent first. The table engine gains an optional per-column `sortGet`, honoured by `_tblVisibleRows`, so the Client column keeps showing the name while sorting on the key.
- **Family order is a pre-sort inside a band or group; the user's sort rules the rest.** Band ORDER among plain rows is unchanged (first appearance under the user's or the Sort Defaults sort). INSIDE a band the root's own rows are pinned to the top — on the Leads register its HQ leads, on the Opportunities register its deals (lineage masters ordered by their organisation) — and every other row keeps the table's sort. There is no per-organisation re-sort: a Last Contact sort still shows the family's newest contact first among the non-pinned rows (**Decide 5**). The band heading's summary cells (Source, Region, Branch, Owner, Sector) read the ROOT organisation, not the earliest-created member (on prod every multi-org family's earliest row is a child's).
- **Marks** (`_orgFamilyRole` + `_orgFamilyTagText`, HTML and plain-text twins): a company root with children reads **PARENT · n orgs** ("· parent of n" in a select); a grouping reads **GROUP** whatever its member count ("· group of n"), drawn as a heading, never as a client; a child reads **↳ parent**; a company with no children carries no mark. The HISTORY chip is gone. The register row hook on a root's own plain row prints its PARENT mark (today `_childHookHtml` prints only the child's ↳).
- **Doorway to the family page**, for every organisation: a chip on every band label (the label click still toggles the band, the chip opens the page, as the GROUP chip does today), a chip in the Group column of Manage Clients / Admin → Organisations / Deal Administration on standalone rows too, and an **Open family page** button on every saved Organisation form (today only parent/child forms get the banner).

## 5. Surface by surface

| Surface | Today | Change |
|---|---|---|
| Leads register bands | band = family root (`leadBandOf`), label = root's name, GROUP/HISTORY chip; rows inside in the table's sort | label gains PARENT / GROUP mark and the page chip; the root's HQ leads pinned first (HQ tag), all other rows in the user's sort; heading cells from the root; a lone HQ lead rendered as a plain row carries the mark |
| Opportunities register | `_childHookHtml` under child rows; lineage bands | the root's deals (lineage masters) pinned first; same marks; sector cell from the root |
| Manage Clients | `is_client = true` only, `order=id.asc` (alphabetical by accident of the import), Group column render-only (sorts by raw id) | stays clients only, so groupings never appear here; Group column gains a `get()` = family root name and a **Kind** column, so the engine's own sort and filter work; children listed under their parent through `familySortKey` as the default order (**Decide 9**) |
| Admin → Organisations | as Manage Clients | hierarchical default order (parent, ↳ children) via `familySortKey`; groupings drawn with the GROUP mark; Kind column with the filter popup giving "Groupings only"; the Kind select on the Admin tab |
| Organisation form | Parent / Group lookup, family banner | **Parent organisation** lookup with the filter in 3.4; **Kind** on the Admin tab with the confirm; client-only fields (`account_no`, `client_status`, `client_since`, `payment_terms`, `credit_limit`) hidden for a grouping through a per-field `hideWhen` the tabbed form honours and re-evaluates when Kind changes; banner "Parent of …" / "Part of … (via …)"; Open family page button for every saved organisation |
| Family page (`openParentHistory`) | "Group" window: members strip (multi-org only, counts), description, switch, "+ Log group engagement", history | titled "&lt;name&gt; — family"; the strip draws for EVERY family including one organisation, each card LISTING its open leads (HQ first, then by site), opportunities and contracts as rows that open the record, and its sites with no lead as plain rows; Family notes with empty state "No family notes yet"; the switch relabelled; the history table's organisation-level rows wear the family's mark and its Client column sorts by `familySortKey`; the engagement button per section 6 |
| Pickers where a CLIENT is chosen — lead target (`#lead-target-org-id`), new-opportunity client, the lead-capture match strip (`_findOrgMatches`), the promote match strip (`promoteOrgPickExisting`), save-time `findOrCreateProspectOrg`, the campaign-target company strip (`useCtOrgMatch`), the Sites admin organisation lookup, the chosen-org chip | flat alphabetical `<option>` list with a text suffix; strips and find-or-create match any organisation | groupings excluded everywhere a client is needed (a typed name equal to a grouping's name offers "&lt;name&gt; is a grouping — pick one of its members" instead of creating a duplicate Prospect company); selects stay a flat alphabetical list of roots and standalones with each root's children inserted directly after it, the mark kept as a SUFFIX after the name so type-to-select still works; suffixes "· parent of n" / "· group of n" / "↳ parent" |
| Pickers where a PARENT or REFERRER is chosen — Organisation form parent, lead source organisation, person–organisation roles (per Decide 7) | plain lookups | groupings offered; family order |
| Contracts list and its Excel export | Client (+ ↳), sorted by the deal's client name; the export hand-builds the Group text | Client column sorts on `familySortKey` (parent's contracts first); the export's Group column reads `_orgFamilyTagText` |
| Deal Administration | Group column = root name (blank for standalone), `_orgFamilyCellHtml` | Group column sorts on `familySortKey` so parent + children tie-break correctly and standalones sort as their own root; PARENT / GROUP / ↳ marks |
| Revenue Pipeline | Group by Client = the deal's organisation | **Decide 3**: a second GROUPS entry **Client family** keyed on the root's name (the existing "—" fallback, blank last, groups ordered by subtotal), the root's deals first inside the group; deal rows carry `org_id` and root |
| Engagement History | groups by the record's own organisation, ordered by most-recent engagement; client filter alphabetical | group keys unchanged (per organisation); the client filter list and any client sort use `familySortKey`; a child's group heading shows "↳ parent" |
| Admin → Settings → Merge organisations | repoints every FK in sequence, no kind check; `engagements.org_id` missing from `ORG_MERGE_REFS` | refuses keep = grouping unless the duplicate is an empty grouping; refuses a keep inside the duplicate's subtree, and when keep's parent is the duplicate, keep inherits the duplicate's parent before the repoint; `engagements.org_id` added to the refs (preview counts them); the duplicate's family notes and switch folded in when keep has none |
| Lead form | chosen-org chip, org-aware match strip | the HQ tick; the chip and strip show the family mark; a grouping is never a selectable target |
| Dashboard, Attention Workbench, Reports, Milestones page, Job Numbers, Timesheet Approvals, Work Labour Report, Billing Schedules, time.html job picker | list or group by organisation name | unchanged (no family display; they name the record's own organisation) |

## 6. Engagements, Last Contact and cohesion

- **Company family.** Contact belongs on the company's own lead or deal. The family page's button reads "+ Log an engagement with &lt;name&gt;" and opens the ordinary engagement modal on a record through a new standalone opener `_phLogWith(kind, id)` modelled on the cockpit quick-log: the root's HQ lead when it has one, else a pick among its open leads and deals, else the organisation-level engagement (the existing `engagements.org_id` row). All three already count as the family's Last Contact.
- **Grouping family.** The organisation-level engagement is the only option. The organisation-level form gains the People Involved picker (`engagement_people`, candidates = the family's affiliates), so an engagement with a holding can name the person it was with.
- **Last Contact** (`_familyContactFor`, `v_org_contact`) — unchanged: the family walk and the switch.
- **Stage cohesion** — the gate today is "born OR multi-organisation", which retiring birth would silently switch off for the 26 single-organisation families. New gate = the switch alone, exactly as Last Contact's: `_cohesionRootFor` returns the root whenever `group_touch_soothes` is not false. A one-lead family has nothing to pull, so no size test is needed; to spare the two member reads on every stage move of a lone lead, `_groupMemberLeads` first looks for siblings in the register's cached rows and reads from the server only when the cache is absent or shows one. `applyGroupJoinStage` (a newborn joins its family's stage) follows the same gate. `LEAD_LIFECYCLE_RULES.md` gains a cohesion paragraph (it has none).

## 7. Lesley-Anne on day one

- Her HQ "PARENT" leads become tagged HQ leads (3.2) and pin to the top of their bands. Her site leads stay where they are.
- Her 32 pointer engagements ("See PARENT" / "See all engagement under SAB - HQ": Clover 4379–4393, Premier 4831–4842, Sasol 4795–4797 and 4843–4847, SAB 4260–4269) are Notes with `work_mode` client, so each counts as that site lead's own contact; the family switch masks them today, and they would resurface as stale contact if Decide 2 lands on off. **Decide 10**: after she confirms, retype them to `work_mode` internal (a touch, never a contact) and recompute `last_touch_date` on those leads in one attributed, system-marked transaction.
- Group engagements she never used become "an engagement with &lt;organisation&gt;" and stop being the only way to engage the company.

## 8. Decisions for Richard

1. **Pan African Resources PLC** becomes a grouping (it owns nothing), or stays a company you might one day sell to?
2. **"Family acts as one" default** for a company parent with subsidiaries. The switch gates three things at once — a subsidiary's or sister site's contact counting as every member's Last Contact and quieting its aging nag, and one member entering Working or Nurture pulling the others. On today, for every family. Off would be a per-row write on 4001 and 4084 plus a rule for parents created later.
3. **Revenue Pipeline "Client family"** grouping — wanted?
4. **HQ**: tag wording ("HQ", "Head office", "PARENT"), and is a one-lead organisation's only lead HQ by default?
5. **Inside a band**: pin the root's rows first and leave the rest in the user's sort (recommended), or re-sort per organisation (parent's rows, then each child's)?
6. **Who may declare a grouping** — `manage_organisations` (Admin and Sales Manager) or Admin only?
7. **May a grouping carry contacts** (a Group Risk Manager, group procurement)? Recommended yes.
8. **Seeded family notes**: clear the 15 of 23 that are backfill text?
9. **Manage Clients default order**: hierarchical (parent, ↳ children) or keep the current order?
10. **The 32 pointer engagements**: retype to internal after Lesley-Anne confirms?
11. Out of scope but to state: no single-organisation family's sites become child organisations; that stays a hand decision.

## 9. Release shape

1. `sql/org_kind.sql` on DEV; code on test; verified in mock mode: a company family and a grouping family drawn and ordered on every surface in section 5, the guard refusing a lead on a grouping with a readable message, a grouping named like a free-text lead saving with the lead left alone, the merge refusals, the HQ tick and seed, cohesion still pulling Milco-style siblings.
2. Prod: the SQL first (safe before the code: the kind is company everywhere, the guard refuses nothing that exists), then the release, then Decide 10's data step.

## 10. Not in scope

Converting sites into child organisations; a separate grouping table; changes to `v_org_contact`, the Last Touch triggers or the Last Contact rule.
