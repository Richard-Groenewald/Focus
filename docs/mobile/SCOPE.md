# Focus on a PC and on a phone — scope

Richard, 19 November 2026: "focus needs to differentiate between running on a PC or Mobile".
A scope, not a build. Section 5 lists the decisions it needs.

## 1. What Focus does today (checked 19 November)

- **The main app has no phone layout at all.** `index.html` carries two `@media` rules, both for
  print. The shell is a fixed 100vh flex row — a 240px navy sidebar and the main column with a
  56px top bar padded 32px — and every page, table, modal and form is sized for a desktop. On a
  phone the browser renders the desktop layout at device width and the user pinches and pans. The
  only concession is the ☰ Menu button the three wide pages (Revenue Pipeline, Opportunities,
  Leads) use to hide the sidebar.
- **Focus already knows about devices in two places**, neither of which changes the layout: the
  PWA install guide reads the user agent to pick Windows / Mac / iOS / Android instructions, and
  the sign-in log stores each session's user agent.
- **The timesheet page is the one phone-first surface.** `/time` (`time.html`) is a separate
  646-line page with its own manifest, 16px type, safe-area padding, an offline queue and a
  bottom bar. It is opened from the sidebar in a phone-sized modal on a PC (v7.10.08) and as a
  standalone page on a phone. It is the pattern to follow, not to duplicate.
- **Usage, PROD, last 60 days** (`user_sessions`): 88 desktop sign-ins by 6 people, 74 hours
  online; 1 phone sign-in by 1 person on 18 November (dashboard, Leads, Engagement History). No
  tablet. Today Focus is a PC application in practice; the phone visit is the question being asked.

## 2. What "differentiate" should mean

Three layers, each useful on its own and each building on the one before.

**Layer 1 — know the device, one reader.** `deviceClass()` → `phone` | `tablet` | `desktop`,
judged by capability, never by user agent: a coarse pointer and a viewport under 768px is a
phone; a coarse pointer wider than that is a tablet; everything else a desktop. Re-judged on
resize, so a desktop window dragged narrow behaves like a phone and a tablet with a keyboard like
a PC. A manual override ("Desktop view" / "Phone view", remembered per person in the browser) sits
in the user menu, because no rule is right for everyone. `<html data-device="phone">` carries the
answer so CSS and code read the same fact. The sign-in log gains a Device column (phone / tablet /
desktop, derived from the stored user agent) so the question "who uses Focus on a phone" has data.

**Layer 2 — a phone layout for the shell** (CSS first, little code): the sidebar becomes a slide-in
drawer behind the ☰ button on every page, not only the three wide ones; the top bar drops to one
row with the title and the menu; tables scroll sideways inside their card instead of squashing;
modals and the deal / lead / quote pages open full-screen; form rows stack; buttons and inputs
reach 44px tap targets; the dashboard cards stack one per row. Nothing is removed — every page
stays reachable and works, just arranged for a narrow screen.

**Layer 3 — a phone home and honest "open this on a PC" notes.** A salesperson on the road wants
five things: what is due today (Outstanding Actions), the leads needing attention, log an
engagement against a lead or deal, capture time, and look up a contact or a client. On a phone the
Dashboard becomes that list, each item one tap away, with the full sidebar behind the drawer. The
pages that cannot work on a phone — the Revenue Pipeline matrix, the quote editor, the project
schedule / Gantt / PERT, the Proposal Builder, Excel export — open with a short note "This page
needs a PC" and a link to what the phone can do there instead (for the pipeline: the headline
figures; for a quote: its list and status). The timesheet page's own layout is left as it is; the
phone home links to it directly rather than through the modal.

Not proposed: a separate mobile application or a second HTML page for the whole app. `time.html`
earns its separate file because it works offline and is used by people who have nothing else in
Focus; the rest of the app would only duplicate its logic.

## 3. What changes, by file

- `index.html`: `deviceClass()` and the override (Layer 1); a `@media (max-width: 767px)` block
  and `html[data-device="phone"]` rules for the shell, tables, modals, forms and pages (Layer 2);
  `renderDashboard` branching to a phone home, and a `PHONE_UNSUITED` list of pages that
  `showPage` fronts with the note (Layer 3). The Sign-in Log page gains the Device column from
  the user agent it already stores.
- `manifest.webmanifest`: unchanged — the installed app simply follows the device.
- `time.html`: unchanged.
- No SQL for any layer.

## 4. Phasing and effort

| Layer | Content | Effort |
|---|---|---|
| 1 | device reader, override, Sign-in Log Device column | half a day |
| 2 | phone shell: drawer, top bar, tables, modals, forms, dashboard stacking | two days, mostly CSS; checked page by page in Playwright at 390 × 844 |
| 3 | phone home, the needs-a-PC notes, contact lookup | two days |

Layers 1 and 2 together make Focus usable on a phone without changing what a PC user sees at all.
Layer 3 makes it good on a phone.

## 5. Decisions for Richard

1. **Is a tablet a PC or a phone?** Recommendation: a PC (the layouts fit at 768px and up), with
   the override available.
2. **The phone home's five things** — confirm or change the list in Layer 3: today's actions,
   leads needing attention, log an engagement, capture time, look up a contact or client.
3. **Pages a phone may not edit on.** Layer 3 fronts the unsuited pages with a note but blocks
   nothing. Should any page be read-only on a phone (the deal form's revenue grid, for example),
   or is the note enough? Recommendation: the note is enough; rights stay with the login, not
   the device.
4. **Go for layers 1 and 2 now, 3 after you have used it?** Recommendation: yes. Layer 2 is the
   one that changes the daily experience for anyone opening Focus on a phone, and layer 3's list
   is better written after a week of that.

## 6. Not in scope

Offline working for the main app; push notifications; a native app; changes to `time.html`;
a tablet-specific layout.
