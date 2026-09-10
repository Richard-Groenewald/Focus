# Proving a server-side shape against the code it replaces

Every Tier 2 object (an RPC or a view that replaces a page's fan-out of reads)
ships with a fallback to the old reads. These scripts prove the two paths render
the same HTML over the same data, so the number the user sees cannot change.

How it works: the app runs in mock mode (`?mock=reset`, the in-memory PostgREST
emulation), the mock store is loaded with a snapshot of the Dev database, and
each page is rendered twice — once on the old per-widget reads (served by the
mock), once from the real SQL output for the same snapshot — then diffed.

```
# 1. snapshot Dev (needs a Supabase Management API token; never commit snap/)
SUPABASE_ACCESS_TOKEN=... python3 tests/perf/dump_snapshot.py

# 2. run (Playwright + Chromium; NODE_PATH points at the global playwright install)
NODE_PATH=$(npm root -g) node tests/perf/equiv_dash.js    # dashboard_summary() vs the 13 widgets' reads
NODE_PATH=$(npm root -g) node tests/perf/equiv_eh.js      # engagements_labelled vs Engagement History's 3 rounds
```

`same*` in the dashboard output means identical up to ties in an undefined sort
order (the old reads return physical order, the bundle orders by id) or the
300-character bug description in the Bugs card. Anything else is a bug in the
SQL or in the client wiring — fix it before shipping.

`smoke-server.js` serves the working tree and stubs the auth function so the app
can be driven without a backend. `snap/` is git-ignored.
