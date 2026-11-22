# Sign-in with Microsoft, an Authenticator code, and Outlook — scope

Richard, 22 November 2026: "i want two things scoped in focus. 1. login tied to Microsoft
authentication and 2. integration with outlook."
The same day: "i need users to be able to log in without microsoft too, when on another PC or when
not an employee (in some cases) so either MS or regular login? can i tie both to MS
authenticator?" and "xone email is on 365. i administer it".

Richard the same day: "go with recommendations, start phase 1" — rulings 1 to 5 taken as
recommended, and parts 0 and A built as **v7.10.58** (see CLAUDE.md for what was built and how it
was tested). Parts B and C are not built. Section 7 lists the rulings still needed for them.

## 1. What Focus does today (checked 22 November)

**Sign-in** (read in `supabase/functions/sb/index.ts`, `index.html`, `time.html`, `log.html`):

- Focus checks a username and password itself, inside the proxy (`handleAuth`: actions `env`,
  `check`, `set`, `login`). Passwords are PBKDF2-hashed on `system_users`. Five wrong passwords
  lock the account for 15 minutes.
- A successful sign-in returns a Focus session token: signed by the proxy, valid 24 hours, never
  renewed. Every later call re-checks that the account is active and its `session_version`
  unchanged (cached 60 seconds), so a deactivation or password reset ends a session within a
  minute.
- There are three login screens on one session record (`focus_session` in the browser): the main
  app, `/time` and `/log`.
- `system_users` carries no email address. A login reaches one through `person_id` →
  `people.email`.
- A reset account, and a new one created without a temporary password, has no password at all.
  Whoever types that username first at the login screen chooses one (`check` → the set panel,
  unverified).

**The server trusts every signed-in session completely.** After the session check the proxy
forwards any request, to any table, with the service key. Permissions are enforced in the browser
only. From reading the code (not tried against the live system):

- Any session can write `system_users`, `user_roles` and `role_permissions` — including the
  password-reset PATCH the System Users page sends (`resetUserPassword`), after which that
  account's password can be chosen from the login screen.
- The proxy strips `password_hash` / `password_salt` from replies by key name, and only on the
  `system_users` path. A request that renames the column, or reads it embedded under another
  table, is not stripped.

This is the "tightened with the wider permissions work" state the code comments already describe.
It matters here because a second sign-in step is worth little if any signed-in user — a
non-employee included — can read or reset somebody else's.

**PROD figures:**

- 8 active logins. On their person records 6 carry an xone.co.za address, 1 outlook.com and
  1 pesca.co.za. Roles: 3 Exco View Only, 2 Admin, 1 Executive, 1 Sales Manager, 1 Sales User.
  No Technician login exists yet.
- Engagements logged in the last 90 days, all typed by hand: 178 Email, 131 Call, 63 Meeting.
- 85 next actions with a due date are open.
- 101 of 121 people have an email address and no address is shared, so mail can be matched to a
  contact by address.
- Focus has no link that opens a particular record (the only URL parameter is `?mock`).

## 2. The shape

Four parts. Each is useful without the ones after it.

| Part | What it is | Depends on Microsoft |
|---|---|---|
| 0 | The server guards the sign-in tables | No |
| A | Regular sign-in asks for a 6-digit code from the Authenticator app | No |
| B | "Sign in with Microsoft" beside the regular sign-in | Yes: the registration in section 5 |
| C | Outlook: log email, log meetings, send next actions to Outlook | Yes: part B and three permissions |

**Two methods, set per user.** `system_users.signin_method` = `either` | `microsoft` | `regular`,
set by an admin. Microsoft says who a person is; Focus still decides whether they have a login
and what it may do. A Xone employee with no Focus user is refused.

**Both methods use the Microsoft Authenticator app, differently.** Microsoft sign-in uses the
approve prompt, run and enforced by Microsoft under Xone's own settings. The regular sign-in uses
Authenticator as a standard code generator (add account → Other account → scan), enforced by
Focus. Any code-generator app works the same way.

**Another PC needs nothing special.** Microsoft sign-in works from any PC or phone. The regular
sign-in is for people without a Xone Microsoft account.

## 3. Design

### Part 0 — the server guards the sign-in tables

1. **Secrets where no REST request can reach them.** A schema PostgREST does not serve
   (`focus_auth`) holds one row per login: password hash and salt, the Authenticator secret, the
   Microsoft link, trusted devices. Only the proxy's sign-in code reaches it. The hash and salt
   move there from `system_users`; the key-name strip stays as a backstop.
2. **Sign-in administration goes through the proxy, checked on the server.** Reset password, reset
   authenticator, link or unlink a Microsoft account and set the sign-in method become `/auth`
   actions. The proxy confirms the caller's token holds `manage_system_users` before acting. The
   browser stops sending those changes as plain table writes.
3. **Writes to the access tables need the permission, on the server.** A non-GET request to
   `system_users`, `user_roles`, `system_user_regions`, `system_user_branches`,
   `user_permission_overrides` (`manage_system_users`), `roles`, `role_permissions`
   (`manage_roles`) or `permissions` (`manage_permissions`) is refused unless the token's user
   holds that permission. The proxy reads the permissions with the active / version check it
   already makes each minute.
4. **A new or reset regular login starts from a one-time password** the admin hands over, never
   from an open username. The code path exists (`must_set_password` with a hash); the open path
   is removed.

Not in part 0: server-side permission checks for every other table. That is the wider
permissions work.

### Part A — the Authenticator code on regular sign-in

- **Standard:** time-based one-time codes (RFC 6238: 6 digits, a new code every 30 seconds). The
  proxy accepts the current code and the one either side of it, and refuses a code already used.
- **Enrolment:** at the first regular sign-in after the password is accepted, Focus shows a QR
  code and the key in text. The user adds it in Authenticator and types one code to confirm. On a
  phone, where the QR cannot be scanned by the phone showing it, the key is copied across.
- **Sign-in:** username and password, then the code. One stateless call: the login card keeps the
  password in memory and sends it again with the code, as it already does for a temporary
  password. Wrong codes count toward the existing five-attempt lock.
- **Trusted device:** a "trust this device for 30 days" tick, off by default. The server issues a
  random device token, stores only its hash, and skips the code while the token is valid. A
  password reset, an authenticator reset or a deactivation cancels every trusted device.
- **Lost or new phone:** an admin presses Reset authenticator on the System Users page; the user
  enrols again at the next sign-in. There are no printed recovery codes. Keep two Admins enrolled
  so one can reset the other.
- **Settings:** `signin_code_required` (all regular sign-ins, or per user) and
  `signin_trust_days` (0 switches the tick off).
- **Sign-in log:** `user_sessions.method` records password + code, password + trusted device, or
  Microsoft, and the Sign-in Log page shows it.
- **The QR code** is drawn by a small script file loaded only at enrolment and shared by the three
  login screens. Focus uses no libraries, so it is hand-written, like the Excel writer.

### Part B — sign in with Microsoft

- **Registration:** one single-tenant application in Xone's Microsoft Entra directory, of the
  single-page type. No client secret, so nothing expires.
- **Flow:** the standard browser flow (authorisation code with PKCE), hand-written. The login card
  sends the user to Microsoft and receives a signed identity token on return. It posts the token
  to `/auth` action `microsoft`.
- **The proxy verifies** the token's signature against Microsoft's published keys, and that it was
  issued by Xone's tenant, for this application, is unexpired, and carries a one-time value the
  proxy itself issued a few minutes earlier. Then it issues the same Focus session token as today.
  Roles, permissions, Work as…, revocation and the sign-in log are unchanged.
- **Tenant and application IDs** are edge function settings on each Supabase project, not rows in
  `settings`, so no session can repoint them. The login card learns them from the `env` action and
  shows the Microsoft button only where they are set.
- **Linking:** an admin enters each user's Microsoft account on the System Users page (one click
  to take the person's email address). The first Microsoft sign-in with that account pins
  Microsoft's permanent account ID, and later sign-ins match on the ID, not the address. Focus
  does not link by matching `people.email` itself, because any user can edit a person record.
- **Second step:** Microsoft's, under Xone's Microsoft 365 settings. Focus does not add a code on
  top.
- **Leavers:** disabling the account in Microsoft stops new Focus sign-ins. A session already
  running lasts up to 24 hours unless the login is also deactivated in Focus (60 seconds).
- **Daily use:** the Focus session still lasts 24 hours. A browser that is still signed in to
  Microsoft gets back in with one click and no typing.
- **Emergency:** keep one Admin on `either` with a regular password and code, in case Microsoft
  or the registration is unavailable.

### Part C — Outlook, on demand

Focus reads Outlook only while the user is in Focus, from the browser, with that user's own
permission. Mail and calendar content stays in Microsoft. Focus stores only what the user chooses
to log. A user on the regular sign-in who has a Xone mailbox gets a Connect Outlook button that
runs the Microsoft step for Outlook only.

**C1 — log an email as an engagement.** On a lead's or deal's Engagement tab, From Outlook lists
recent mail (30 days by default) exchanged with the people linked to that record and its
organisation. Ticking one opens the ordinary engagement form pre-filled: type Email, the message's
date, the people involved, and the subject and preview as the details. The user still completes
the next action, so the engagement rules are unchanged.

**C2 — meetings to log.** A dashboard card, also offered on `/log`, lists calendar meetings of the
last 14 days that had a known contact as an attendee and are not yet logged. Picking one opens
the engagement form with type Meeting, the date, the duration and the attendees. A meeting can be
dismissed.

**C3 — next actions to Outlook.** Saving an engagement with an open, dated next action creates a
Microsoft To Do task for the person saving it, due on that date, with a link back to the record.
Closing the action in Focus completes the task. Completing the task in Outlook does not close the
action in Focus, because Focus closes an action with an engagement. Each person switches this on
or off for themselves. Focus gains record links (`/?deal=…`, `/?lead=…`) for this.

**No double logging.** Each logged email or meeting keeps Outlook's own identifier, which is the
same for the sender and every recipient. The list shows "already logged by <name>" on a record
that holds it, including when a colleague logged it.

**Permissions requested, on the user's behalf only:** read mail, read calendar, read and write
tasks. Richard approves them once for Xone, so users see no consent screen.

## 4. What changes, by file

- `supabase/functions/sb/index.ts`: the sign-in handler reads the private schema; code
  verification, trusted devices, the Microsoft token check; the admin actions; the access-table
  write guard. Deployed to PROD and TEST with the Supabase MCP. Tests in `tests/sb_test.js`.
- `netlify/functions/sb.js`: the idle rollback copy. See decision 11.
- `index.html`, `time.html`, `log.html`: the login card (Microsoft button, code step, enrolment,
  trust tick); in `index.html` also the System Users page (sign-in method, Microsoft account,
  authenticator state, the reset buttons through `/auth`), the Sign-in Log method column, the two
  settings, and part C's panel, dashboard card, task sync and record links.
- A small shared script for the enrolment QR code.
- SQL, additive and re-runnable: the `focus_auth` schema and the credentials move;
  `system_users.signin_method`; `user_sessions.method`; for part C, a table tying an engagement
  to its Outlook item, a dismissals table and a per-person Outlook preference.
- `scripts/clone_prod_to_dev.js` copies the `public` schema only, so DEV keeps its own sign-in
  secrets after a clone. A login created on PROD since the last clone arrives on DEV with no
  password and needs a reset there. The clone drops and recreates `public`, so it must re-make
  the link from the private rows to `system_users` afterwards.

## 5. What Richard does in Microsoft 365

Steps 1 to 3 are needed for part B. Step 4 can wait for part C.

1. In the Microsoft Entra admin centre (entra.microsoft.com) open **App registrations** and choose
   **New registration**. Name it Focus CRM. Under supported account types choose the
   single-tenant option (shown as "Single tenant only" or "Accounts in this organizational
   directory only"). Under Redirect URI choose the **Single-page application** platform and enter
   `https://storied-griffin-6eab6b.netlify.app/`. Register.
2. From the Overview page send Claude the **Application (client) ID** and the **Directory
   (tenant) ID**. Neither is a secret. Do not create a client secret.
3. Under **Authentication** add two more single-page redirect addresses:
   `https://storied-griffin-6eab6b.netlify.app/time` and
   `https://storied-griffin-6eab6b.netlify.app/log`. Add the same three for the DEV site:
   `https://test--storied-griffin-6eab6b.netlify.app/`, `…/time` and `…/log`. More can be added
   at any time, for example a custom address later.
4. Under **API permissions** add Microsoft Graph delegated permissions `Mail.Read`,
   `Calendars.Read`, `Tasks.ReadWrite` and `offline_access`, then **Grant admin consent**.
5. Check that Xone's Microsoft 365 asks everyone for a second step (Security defaults, or a
   Conditional Access policy). Without that, Microsoft sign-in is password only.
6. Optional: under **Enterprise applications** → Focus CRM → Properties, set "Assignment
   required" to Yes and assign the people who may use it.

## 6. Phasing and effort

| Phase | Content | Effort |
|---|---|---|
| 1 | Part 0 and part A | four days; DEV first; every user enrols once |
| 2 | Part B | two days, plus tests on a real iPhone and Android phone |
| 3 | C1 and C2 | three to four days |
| 4 | C3 and record links | one to two days |

Phase 1 needs nothing from Microsoft and can start at once.

## 7. Decisions for Richard

1. **Build part 0 with part A?** DECIDED 22 November: yes. Recommendation: yes. Without it any signed-in user can read or
   reset another user's second step.
2. **Code on every regular sign-in, or per user?** DECIDED: every one. Recommendation: every one. A user allowed both
   methods is only as protected as the weaker.
3. **Offer "trust this device for 30 days"?** DECIDED: yes, off by default.
4. **Sign-in method per user, set by an admin** (either / Microsoft / regular). DECIDED; it is
   built with part B, when there is a second method to choose. Recommendation:
   employees start on either and move to Microsoft only once it has run for two weeks, except one
   emergency Admin.
5. **New and reset regular logins start from a one-time password the admin hands over.**
   DECIDED: yes.
6. **Non-employees use the regular sign-in**, not a guest account in Xone's Microsoft directory.
   Recommendation: yes, as asked.
7. **The two logins not on xone.co.za:** do they have Xone mailboxes as well, or do they stay on
   the regular sign-in?
8. **Field staff on `/time`:** will they have Microsoft accounts? If not they stay on the regular
   sign-in with a code.
9. **Outlook: C1, C2 and C3, on demand?** Recommendation: yes, in that order.
10. **Next actions as To Do tasks, not calendar entries.** Recommendation: tasks. A next action
    has a due date and no time, so a calendar entry would be an all-day block.
11. **The Netlify rollback copy of the proxy.** SETTLED BY THE BUILD, and further than first
    proposed: the file stays, but the deployed copy now answers 410 to everything. A live older
    proxy on the same service key would let any signed-in user write to the access tables and
    call the sign-in functions without the guard, so it could not stay as a working rollback.
12. **The DEV site's address**: given, `https://test--storied-griffin-6eab6b.netlify.app/`.
    Still open: whether Focus is to get an address such as focus.xone.co.za.

## 8. Risks and open points

- **Installed apps on an iPhone.** The Microsoft step leaves the installed `/time` or `/log` app
  and must return to it. This is the one part that cannot be proved without a real device. The
  regular sign-in stays available on those screens as the fallback.
- **A sole Admin who loses their phone** cannot reset their own authenticator. Two enrolled
  Admins avoid it; the last resort is a reset by SQL.
- **Enrolment day.** Every regular-sign-in user must enrol once. Do it with each person present.
- **The Outlook token in the browser** gives read access to that user's mailbox for up to 24
  hours. It is kept for the tab's session only and cleared at sign-out.
- **"Open in Outlook" on a logged email** opens only for the person whose mailbox holds it.
- **Staff should be told** that Focus can show their own recent mail and meetings with known
  contacts, to them only, and stores only what they log.
- **Menu names in Microsoft's admin centre change.** Section 5 was checked through search on
  22 November; Microsoft's documentation site could not be opened from the session.

## 9. Not in scope

A "Log to Focus" button inside Outlook (an add-in); sending mail from Focus; automatic background
capture of mail; contact sync; saving email attachments to the Files tab; shared mailboxes;
calendar entries created from Focus; guest accounts; printed recovery codes; server-side
permission checks beyond the access tables.
