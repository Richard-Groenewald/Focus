# Proposal tool by deal type — scope

Richard, 19 November 2026: "deal types should drive the proposal tool, scope it". The question first
surfaced on 14 November (v7.10.39): manpower deals (guarding, control rooms) use the proposal tool;
other deal types will not; and the Revenue Stream Generator and the Proposal Builder tab should
follow the type.

This is a scope, not a build. Section 6 lists the decisions it needs from Richard.

## 1. What "deal type" means here

A deal carries two kinds of type. `opportunity_type` (new business / extension / variation) is about
the deal's origin and does not change what is sold. The **service type** — `deals.service_sub_id`,
a row of `service_sub` under a `service_major` family — is what is sold, and it already drives two
things through one reader each: the revenue type (`rsgRevenueType`: annuity or project, which picks
the generator and decides Contract vs Project after securing) and the margin rule. The proposal tool
is the third thing the service type should drive. One home per rule, so the rule lives on the
`service_sub` row.

## 2. What Focus does today (checked on PROD, 19 November)

- **The Proposal Builder tab** shows on every saved deal: the Revenue Stream Generator button, then
  the quotes list with **+ New Quote**, then the project plan card. Nothing reads the deal's service
  type. New Quote creates a manpower quote (`shifts_per_day` 2, margin 20) for a Business Analysis
  deal as readily as for a guarding deal.
- **The quote editor** is the manpower engine end to end: Basic info (with the PSIRA area), Posts and
  shifts, Shift Schedule, Workforce / Contract / Service support items, Site Mobility, Pricing
  (the labour engine and the calculation snapshot), Proposal. It never reads the deal's service
  type either. The proposal template has ten sections, two of them manpower-only (`scope_posts`,
  `shift_schedule`), and the pricing section prints the snapshot's post groups.
- **The generator** already follows the revenue type: the annuity block works; the project block is
  the "In development" placeholder and Auto-Populate refuses a project deal. A project deal's
  months are typed by hand on the revenue grid.
- **The Proposal Sandbox** holds manpower quotes with no deal (3 on PROD). Unaffected.
- **Files → Proposals** lists a quote's issued documents automatically; a PDF produced outside
  Focus is attached by hand.

Service types on PROD and their proposal reality:

| Family | Type | Revenue | Open deals | Quotes | Proposal built in Focus? |
|---|---|---|---|---|---|
| Manpower | Guarding Services | annuity | 6 (+64 untyped Manpower imports) | 2 (+2 on untyped) | yes, the quote tool |
| Control Room | On-site Control Room | annuity | 3 | 1 | yes, the quote tool |
| Control Room | Off-site Control Room | annuity | 2 | 1 | yes, the quote tool |
| Control Room | Build / Upgrade / Design | project | 0 | 0 | no |
| Technology Works | Project | project | 1 | 0 | no |
| Technology Works | Maintenance Services | annuity | 0 | 0 | no |
| Advisory & Design | Business Analysis | project | 2 | 0 | no |
| Advisory & Design | Design Consulting / Risk Review / Process Design | project | 0 | 0 | no |

137 of 156 deals carry no service type at all (the imports); all 64 open ones are in the Manpower
family. No proposal has ever been issued on PROD (0 issued documents), so nothing is frozen that a
change could contradict.

## 3. The rule proposed

`service_sub.proposal_mode`, one of:

- **`manpower`** — the quote tool as it stands. Guarding Services, On-site and Off-site Control Room.
- **`document`** — a proposal document without the manpower engine: the same template, issue number,
  freeze, versioning, Proposals folder and ledger engagement, but the pricing section is a typed
  schedule of line items (description · quantity · unit · amount, once-off or monthly) instead of
  posts and shifts. Technology Works Project, Control Room Build / Upgrade / Design, Maintenance,
  the Advisory & Design types.
- **`none`** — no proposal tool in Focus. The tab says so and points at Files → Proposals for the
  document produced elsewhere. Available for any type Richard wants kept out.

`dealProposalMode(deal)` is the one reader: the sub-type's mode; a deal with no sub-type takes the
family's mode when every active type in the family agrees (Manpower → manpower, so the 64 untyped
imports keep working), else the tab asks for the service type to be chosen on the General tab. This
is exactly the pattern `dealRevenueType` already uses for the same gap.

## 4. What changes, by surface

**Proposal Builder tab (deal page).**
- `manpower`: as today.
- `document` (phase 2): the same list shape — one row per proposal with its version, status and
  number — opening a document editor instead of the quote editor. Until phase 2 lands, `document`
  behaves as `none`.
- `none`: no quotes list, no New Quote; a short note naming the type and a link to the Files tab's
  Proposals folder. A quote that already exists on such a deal (there are two, both junk test
  quotes on Manpower extensions, so in practice none) stays listed and openable but no new one can
  be made.
- no type resolvable: "Choose a service type on the General tab to open the Proposal Builder."
- The tab's label stays Proposal Builder in every mode; only its body changes.

**Revenue Stream Generator.** Unchanged in what it keys on (revenue type), but the project half is
built: total value, start month, duration in months, and a spread — even across the months, or by
the project plan's milestone billing percentages when a plan exists (`project_milestones.billing_pct`
is already there and already warns past 100%). The early-estimate probability rule applies as it
does for annuity. This is the half of the 14 November note that has nothing to do with the quote
tool and can ship on its own.

**Quote editor.** No change in phase 1. In phase 2 the document editor is a sibling, not a mode of
the quote editor: Basic info (name, dates, validity, client), a Pricing tab with the line-item
schedule, a Proposal tab reusing `pgRenderDocument` with `scope_posts` and `shift_schedule` skipped
and the pricing section fed from the schedule. `issue_proposal` is reused as is: it takes a document
id and frozen content and knows nothing about posts. `pgIssueBlockers` loses its "needs a calc
snapshot" rule in document mode and gains "needs at least one priced line".

**Admin.** Lookups → Service Sub gains a "Proposal tool" select (Manpower quote tool / Proposal
document / None) and a column; `saveRecord` refuses nothing new. `LOOKUP_REV` bumps if the
seed values arrive by SQL, so stage-style caching never hides them.

**Untouched.** The Proposal Sandbox (no deal, manpower by nature); lead promotion (the service type
is chosen there already); Contracts / Projects pages and the project plan (revenue type); the
extension offer; the engine, snapshot and per-shift basis.

## 5. Data and SQL

`sql/add_service_proposal_mode.sql`, additive and re-runnable: the column with a CHECK, default
`document`, then the seed by name once: Guarding Services, On-site Control Room, Off-site Control
Room → `manpower`; everything else → `document`. Richard can flip any row to `none` on the admin
page. Code before SQL: a database without the column reads every type as `manpower` (today's
behaviour) and the admin select is disabled naming the file. Both databases.

## 6. Decisions for Richard

1. **Three modes or two?** The scope above offers manpower / document / none. If a proposal document
   for non-manpower work will always be made outside Focus, drop `document` and phase 2 with it:
   the rule is then manpower / none and phase 1 is the whole job. Recommendation: keep `document`
   as a value from day one (it costs nothing) and decide on building phase 2 after phase 1 has run
   for a while.
2. **Which types are manpower?** Proposed: Guarding Services, On-site Control Room, Off-site
   Control Room. Maintenance Services is annuity but priced as technology, not posts — proposed
   `document`. Confirm.
3. **The project generator's spread.** Even across the months, or by milestone billing percentages
   when a plan exists (even when none). Recommendation: both, the milestone spread offered only when
   a plan with billing percentages exists.
4. **Untyped deals.** The family fallback keeps every open import working without a data step.
   Alternatively, set `service_sub_id` on the 137 untyped deals by SQL (Manpower family → Guarding
   Services). Recommendation: the fallback now, the data step later and separately, because it also
   changes margin rules and the Contracts list for those deals.
5. **Document-mode pricing shape (phase 2 only).** A flat line list with once-off and monthly
   columns, VAT added as today. Milestone-linked lines (a line per plan milestone) would be a later
   step. Confirm the flat list is enough to start.

## 7. Phasing

- **Phase 1 — the rule and the tab** (a day): column, seed, admin select, `dealProposalMode`, the
  tab's three bodies, New Quote refused off-manpower, mock seed, Playwright harness, guides. Ships
  on its own; nothing a manpower user sees changes.
- **Phase 1b — the project generator** (a day): the project block of the modal, even and milestone
  spreads, the harness. Independent of phase 1 and could go first.
- **Phase 2 — the proposal document** (three to four days): the document editor, the line-item
  schedule and its table (`proposal_document_lines`), `pgRenderDocument` skipping the manpower
  sections, the issue blockers, the Files listing, the sandbox left alone.

## 8. Not in scope

Pricing engines for technology or advisory work; a bill of materials; the quote sandbox for
non-manpower work; re-typing the imports' service types (decision 4); changes to the manpower
engine, the snapshot or the per-shift basis.
