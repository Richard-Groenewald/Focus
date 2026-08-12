# Lead Lifecycle — Canonical Rules

> **Status: APPROVED by Richard, 2026-07-26.** This document is THE reference for lead stages,
> progression rules, oversight, and timers. It supersedes all earlier stage descriptions
> (see "Supersedes" at the bottom). Derived from the lifecycle flow diagram shared 2026-07-25
> and the qualification-workflow Q&A session of 2026-07-26.
>
> **Revised 2026-08-12 — stage bands redesign** (agreed in working session, revision awaiting
> final sign-off, not yet built): the Qualified stage is *displayed* as **Ready**; a two-band
> umbrella ("In Qualification" / "Qualified") sits over the stages; Hold and Nurture entry no
> longer require approval — **promotion is the only approval gate**.

## Stages (7)

| Stage | Meaning | How you get in | Live? |
|---|---|---|---|
| **New** | Captured, not yet worked | Lead creation (any source) | Yes |
| **Working** | Being actively qualified via FACT | Auto: completeness **and** first logged engagement | Yes |
| **Ready** *(stored as `Qualified`)* | Promotion-ready, awaiting approval | **Auto**: FACT all green + service category set + organisation (linked or typed) | Yes |
| **Hold** | Right profile, waiting for its moment | Owner/SM, **direct** — F/A/C green; **wake date mandatory**; a green Trigger is turned **Weak (amber)** on entry | Yes — engagements + FACT edits allowed |
| **Nurture** | Strategic long-game cultivation | Owner/SM, **direct** — **F/A green**; **per-lead cadence mandatory** | Yes |
| **Dead** | Killed, with record | User requests → moves **immediately**, awaiting SM oversight there | No — but reopenable |
| **Promoted** | Became an opportunity | SM approves at Ready (existing promotion machinery) | Terminal |

- **Naming (2026-08-12):** the stored stage value remains `Qualified` in the database and in
  code; the UI label is **Ready** (label subject to change — display-map only, never a data
  migration). The word **"Qualified"** in UI and reporting refers to the *band* below, not the
  stage. Do not conflate the two when reading code.
- No estimate of value is required anywhere in the lead lifecycle.
- `lead_sources` lookup stays as-is (the diagram's source list is illustrative, not a spec).

## Bands (added 2026-08-12)

Two umbrella groupings over the stages. Stored values are unchanged — a band is derived from
the stage (`leadStageGroup()`), never stored.

| Band | Stages | Meaning |
|---|---|---|
| **In Qualification** | New, Working | The lead's fate is still being established |
| **Qualified** | Nurture, Hold, Ready, Promoted | A deliberate decision has been made about the lead |

Dead sits outside both bands (off-pipeline).

**Surfaces:** a band header strip above the Leads Register stage tabs (tabs and their names
unchanged), plus a **reporting number**. The Qualified-band KPI always shows its composition —
e.g. "Qualified: 14 (Ready 5 · Nurture 6 · Hold 2 · Promoted 1)" — so the number cannot be
silently inflated by parking thin leads.

## Gates (FACT)

Fit → Access → Capacity → Trigger. A gate passes only on **Strong** — Weak does not count.

Consequence: the `promotion_green_counts_weak` setting is obsolete; the below-threshold
special-request path is superseded by the auto-flip to Ready.

Entry bars by stage (each parked stage's bar matches its meaning):

| Stage | Bar |
|---|---|
| Nurture | **F, A green** (long game — still building the case) |
| Hold | **F, A, C green** (right profile — the moment isn't now, so Trigger is turned amber on entry) |
| Ready | **FACT all green** + service category + organisation |

## Transitions

| From → To | Trigger | Approval |
|---|---|---|
| New → Working | Completeness (source, description, site, contact, next action) **and** first engagement — organisation **not** required here | None (auto) |
| Working → Ready | FACT all green + service category + organisation | None (auto) |
| Ready → Promoted | SM approves | **Sales management — the only approval gate in the lifecycle** |
| Working/Ready → Hold | Owner or SM, **direct action**; F/A/C green; wake date mandatory. If Trigger is green (i.e. coming from Ready), it is downgraded to **Weak (amber)** on entry | None |
| Working/Ready → Nurture | Owner or SM, **direct action**; F/A green; cadence mandatory | None |
| Hold → Working | Wake date expires | None (auto) — owner + SM get top-of-dashboard reminders |
| Hold → Ready | The full Ready gate is met while on Hold (FACT re-greens + service + organisation) | None (auto) — wake date cleared, owner notified |
| Hold → Working/Ready | **Early release** — owner or SM takes it off Hold before the wake date | None (direct) — wake date cleared, landing stage derived off the data |
| Nurture → Working/Ready | **Exit** — owner or SM releases it from Nurture | None (direct) — cadence cleared, landing stage derived off the data |
| Any → Dead | User requests | Moves immediately; SM oversight lands **post-hoc** in Dead |
| Dead → Working | SM or Executive reopens, reason required | FACT dots **cleared** on reopen |

**Hold/Nurture entry is direct (2026-08-12, supersedes the approval requirement):** entering
Hold or Nurture writes **no `lead_stage_requests` row** — it is a direct stage change like the
existing early-release/exit actions, recorded by the leads audit trigger. The declined-Hold/
declined-Nurture path no longer exists.

**Parked leads are releasable** (added 2026-07-31): the owner or a sales manager can take a
lead off Hold early or exit Nurture at any time from the Lead Progression tab. Direct action,
no approval, no `lead_stage_requests` row. The engine derives the landing stage: Ready if the
full Ready gate is met, otherwise Working.

**Organisation requirement sits at the Ready gate** (2026-08-08, reconfirmed 2026-08-12): an
organisation identity (linked record or typed name) is not part of Working completeness — a
lead can be worked without knowing whose site it is. It is mandatory at Ready, and therefore
for promotion. Once FACT goes all-green, any field still blocking Ready (service interest,
organisation) is highlighted.

**Declines:** the surviving decline paths are the **promotion** rejection and the post-hoc
**dead review** — in both, reason always required; the dead-review verdict remains the
approver's choice (default back to Working, option Dead stays dead).

**Self-approval collapse:** if the initiator holds the approval right (now only relevant to
promotion), the approval step is skipped — sales managers keep direct Promote.

## Red Flag

Raisable any time. The lead **stays where it is** — no auto-death. Review belongs to the
**Executive** role. Verdicts, reason always required:

- **Kill** → Dead, flag preserved on the record.
- **Ignore** → lead continues; Executive chooses to leave the flag visible or clear it.

While a flag is unresolved the lead is **not frozen** — work continues — but **promotion is
blocked** until the verdict is Ignore or the flag is removed.

## Timers — nothing sleeps forgotten

| Where | Mechanism |
|---|---|
| **Hold** | Mandatory wake date → auto back to Working + top-of-dashboard reminders (owner + SM) |
| **Nurture** | Per-lead recurring cadence → each tick creates a **next-action obligation** (campaign-cadence machinery) |
| **New** | Untouched X days → escalation to owner + SM |
| **Working** | No touch Y days → escalation to owner + SM |

X and Y are Admin → Settings values, **overridable per user by the sales manager**.

## Approvals Outstanding

A **dashboard widget, one per qualifying role**, aggregating every approval that role owes —
**promotions and dead reviews** (sales management) and **red flags** (Executive). Hold and
Nurture requests no longer appear (entry is direct). Lives in the existing role×widget matrix;
future approval types join the same widget.

## Cutover (2026-08-12 revision)

- No data migration for the rename — `Qualified` stays the stored value; **Ready** is a display
  label only.
- **Existing Nurture leads are grandfathered**: the new F/A entry bar applies at entry, not
  retroactively — nothing is swept back to Working.
- Existing Hold leads likewise stay put (their F/A/C bar was already enforced at entry).
- Any **pending** Hold/Nurture rows in `lead_stage_requests` at cutover are executed directly
  (the approval they were waiting for no longer exists), carrying their wake date / cadence.
  *(TBC with Richard before build.)*

### Cutover history (2026-07 lifecycle build)

- New / Working / Qualified / Promoted / Dead: mapped 1:1.
- Nurture leads kept under the new semantics (owners set cadences); Hold started empty.
- Dormant fully retired.

## Supersedes

- Hold/Nurture entry approval + declined-Hold/Nurture path (2026-08-12 — entry is direct)
- Open "any time" Nurture entry (2026-08-12 — F/A green bar)
- "Qualified" as the stage's display label (2026-08-12 — stage displays as **Ready**; "Qualified" = the band)
- Nurture-as-focus-stage (v7.8.15)
- Red-flag auto-death
- Dead-is-permanent (no-reopen)
- Estimate-of-value requirement for Qualified
- Weak-counts-toward-green (`promotion_green_counts_weak`)
- Organisation-required-for-Working (moved to the Qualified/Ready gate, 2026-08-08)
