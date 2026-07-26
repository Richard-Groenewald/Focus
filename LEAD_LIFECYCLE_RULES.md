# Lead Lifecycle — Canonical Rules

> **Status: APPROVED by Richard, 2026-07-26.** This document is THE reference for lead stages,
> progression rules, oversight, and timers. It supersedes all earlier stage descriptions
> (see "Supersedes" at the bottom). Derived from the lifecycle flow diagram shared 2026-07-25
> and the qualification-workflow Q&A session of 2026-07-26.

## Stages (7)

| Stage | Meaning | How you get in | Live? |
|---|---|---|---|
| **New** | Captured, not yet worked | Lead creation (any source) | Yes |
| **Working** | Being actively qualified via FACT | Auto: completeness **and** first logged engagement | Yes |
| **Qualified** | Promotion-ready, awaiting approval | **Auto**: FACT all green + service category set | Yes |
| **Hold** | Right profile, waiting for its moment | Owner/SM initiates, SM approves; F/A/C green (T optional); **wake date mandatory** | Yes — engagements + FACT edits allowed |
| **Nurture** | Strategic long-game cultivation | Owner/SM initiates from Working or Qualified, SM approves; **per-lead cadence set** | Yes |
| **Dead** | Killed, with record | User requests → moves **immediately**, awaiting SM oversight there | No — but reopenable |
| **Promoted** | Became an opportunity | SM approves at Qualified (existing promotion machinery) | Terminal |

- No estimate of value is required anywhere in the lead lifecycle.
- `lead_sources` lookup stays as-is (the diagram's source list is illustrative, not a spec).

## Gates (FACT)

Fit → Access → Capacity → Trigger. A gate passes only on **Strong** — Weak does not count.

Consequence: the `promotion_green_counts_weak` setting is obsolete; the below-threshold
special-request path is superseded by the auto-flip to Qualified.

## Transitions

| From → To | Trigger | Approval |
|---|---|---|
| New → Working | Completeness (source, description, site, contact, next action) **and** first engagement | None (auto) |
| Working → Qualified | FACT all green + service category | None (auto) |
| Qualified → Promoted | SM approves | Sales management (existing request/accept machinery) |
| Working/Qualified → Hold | Owner or SM initiates; F/A/C green (Trigger green or not) | Sales management |
| Working/Qualified → Nurture | Owner or SM initiates; any time pre-promotion | Sales management |
| Hold → Working | Wake date expires | None (auto) — owner + SM get top-of-dashboard reminders |
| Hold → Qualified | FACT goes all green while on Hold | None (auto) — wake date cleared, owner notified |
| Any → Dead | User requests | Moves immediately; SM oversight lands **post-hoc** in Dead |
| Dead → Working | SM or Executive reopens, reason required | FACT dots **cleared** on reopen |

**Declines:** any declined approval (promotion, Hold, Nurture, or the post-hoc dead review) is
the **approver's choice — default back to Working, option Dead — reason always required**.

**Self-approval collapse:** if the initiator holds the approval right, the approval step is skipped.

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
promotions, Holds, Nurtures, dead reviews (sales management) and red flags (Executive).
Lives in the existing role×widget matrix; future approval types join the same widget.

## Cutover

- New / Working / Qualified / Promoted / Dead: map 1:1.
- **Current Nurture leads stay in Nurture** under the new semantics (owners to set cadences).
- **Hold starts empty.**
- Legacy Dormant wake-date rows, if any remain: → Working *(TBC — verify count on both DBs before migration)*.
- Dormant is fully retired.

## Supersedes

- Nurture-as-focus-stage (v7.8.15)
- Red-flag auto-death
- Dead-is-permanent (no-reopen)
- Estimate-of-value requirement for Qualified
- Weak-counts-toward-green (`promotion_green_counts_weak`)
