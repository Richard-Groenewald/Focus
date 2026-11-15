# Focus — offline backup and restore

This folder was written by `scripts/backup_offline.js` (in the repo). It is a complete
copy of Focus as it stood at the time in `MANIFEST.txt`: the production database, the
development database, the source repository and the uploaded deal files. Nothing in
it is a secret, so it can sit on an external drive as it is.

## Taking a backup

On a PC with the Focus repo checked out, `psql` / `pg_dump` on PATH (scoop
`postgresql`, major version at least that of the server — 17 today) and a `.env`
in the repo root holding `SUPABASE_DB_URL`, `SUPABASE_TEST_DB_URL` and, for the
uploaded files, `SUPABASE_SECRET_KEY` (the prod service-role JWT):

```
node scripts/backup_offline.js D:\Focus-backups
```

It writes `D:\Focus-backups\Focus-backup-<date>-<time>\` and prints the row counts
it saw. Copy that whole folder to the offline drive (or point the script at the
drive directly). Verify a copy with the checksums in `MANIFEST.txt`:

```
certutil -hashfile db\prod.dump SHA256
```

Options: `--no-dev` skips the dev database, `--no-files` skips the storage bucket.

## What is in the set

| Path | What | Restore with |
|---|---|---|
| `db/prod.dump` | prod schema `public` — tables, data, functions, triggers, RLS policies, views | `pg_restore` |
| `db/prod.sql` | the same as readable SQL with INSERT statements | `psql -f`, or a text editor |
| `db/prod_storage_objects.sql` | the `storage.buckets` / `storage.objects` rows (the file index) | `psql -f` after the bucket exists |
| `db/prod_counts.txt` | object and row counts at backup time, for checking a restore | — |
| `db/dev.*` | the same for the dev project | — |
| `repo/Focus.bundle` | the whole git history, every branch and tag | `git clone repo/Focus.bundle Focus` |
| `repo/worktree-<branch>.zip` | the tracked files of the checkout, no git needed | unzip |
| `repo/refs.txt` | which commit each branch and tag pointed at | — |
| `files/attachments/...` | every object of the private storage bucket, same paths | upload back to a bucket named `attachments` |
| `files/attachments_index.json` | the bucket listing with sizes and ids | — |

Not in the set, by design (they are secrets or live elsewhere): the `.env` files,
the Supabase service-role key and database passwords, Netlify environment
variables (`SUPABASE_HOST`, `SUPABASE_SECRET_KEY`, `SB_GZIP`), user passwords
beyond their hashes in `system_users`. Keep those in a password manager.

## Restoring the database

Into an EMPTY Supabase project (never over the live one unless that is the point):

1. Create the project (Postgres 17 or later, region eu-west-1). Note its database
   URL (Settings → Database → connection string, session mode).
2. Restore schema and data:
   ```
   pg_restore --no-owner --no-privileges --schema=public -d "<db url>" db/prod.dump
   ```
   `--schema=public` is already all the dump holds. A few warnings about existing
   roles or extensions are normal; errors on tables are not.
3. Grant the API roles what the live project had:
   ```
   psql "<db url>" -c "grant usage on schema public to service_role; grant all on all tables in schema public to service_role; grant all on all sequences in schema public to service_role; grant all on all functions in schema public to service_role; alter default privileges in schema public grant all on tables to service_role; notify pgrst, 'reload schema';"
   ```
   then make sure RLS is on for every table and `anon` / `authenticated` hold
   nothing (the dump carries the policies; the proxy uses `service_role` only):
   ```
   psql "<db url>" -c "do \$\$ declare t text; begin for t in select tablename from pg_tables where schemaname='public' loop execute format('alter table public.%I enable row level security', t); end loop; end \$\$; revoke all on all tables in schema public from anon, authenticated;"
   ```
4. Check `db/prod_counts.txt` against the same query on the restored database
   (the query is in `scripts/backup_offline.js`, `COUNTS`).
5. If `pg_cron` was in use (forecast snapshots), enable the extension and
   re-run the schedule block at the end of `sql/add_forecast_snapshots.sql`.

## Restoring the uploaded files

1. Create the private bucket: run the bucket block of `sql/add_attachments.sql`
   (`INSERT INTO storage.buckets ... 'attachments'`, 50 MB limit).
2. Upload `files/attachments/` back with the same paths. The simplest route is
   the Supabase CLI: `supabase storage cp -r files/attachments ss:///attachments
   --experimental`, or a loop over the Storage REST API with the service key.
3. Rows in `attachments` (the table) reference the object paths, so once the
   paths match, downloads work again.

## Restoring the app

1. `git clone repo/Focus.bundle Focus` (or unzip the worktree).
2. Netlify: new site from the repo, build command `node build.js`, publish `dist/`;
   set `SUPABASE_HOST` to the new project's host and `SUPABASE_SECRET_KEY` to its
   service-role JWT (the JWT, not an `sb_secret_` key).
3. Deploy the edge function `supabase/functions/sb` to the new project with the
   Supabase CLI (`supabase functions deploy sb --no-verify-jwt`) and point
   `netlify.toml`'s `/sb/*` rewrite at the new project ref.
4. Sign in; `settings.environment` in the restored data still says which
   environment the dump came from — change it if this is not that environment.

## Keeping it honest

- Take a set before every release that runs SQL, and at least monthly.
- Keep two drives, swapped; a backup that lives beside the PC is not offline.
- Once a quarter, restore `prod.dump` into the dev project (the clone script,
  `scripts/clone_prod_to_dev.js`, does exactly that) to prove the dump restores.
