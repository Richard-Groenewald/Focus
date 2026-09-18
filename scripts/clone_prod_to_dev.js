#!/usr/bin/env node
// Refresh the DEV database as a copy of PROD (the 2026-09-01 clean-slate recipe,
// scripted, with guards). Prod is only ever READ.
//
//   node scripts/clone_prod_to_dev.js          dry run: checks + plan, changes nothing
//   node scripts/clone_prod_to_dev.js --yes    execute
//
// Needs psql / pg_dump / pg_restore on PATH (scoop postgresql) and .env with
// SUPABASE_DB_URL (prod) + SUPABASE_TEST_DB_URL (dev).
//
// Steps:
//   1  guards      distinct projects; prod flag 'Production', dev flag 'Development'
//   2  backup dev  backups/dev_pre_prod_clone_<stamp>.dump          (custom format)
//   3  export prod backups/prod_snapshot_<stamp>.dump              (read-only; --no-owner --no-privileges)
//   4  dev         drop schema public cascade; create schema public; schema usage grants
//   5  dev         pg_restore the snapshot (triggers/indexes are post-data, so no audit noise)
//   6  dev         grant all to service_role + default privileges; notify pgrst
//   7  dev         re-run sql/enable_rls_lockdown.sql (RLS on every table, anon/authenticated revoked)
//   8  dev         settings.environment = 'Development'
//   9  verify      schema object counts and core row counts equal prod; RLS count; flag
//
// Dev-only schema to re-apply afterwards: none as of 2026-09-18 (schemas were
// identical). If that changes, add the migrations after step 8.
const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
require('dotenv').config({ path: path.join(root, '.env') });
const PROD = process.env.SUPABASE_DB_URL, DEV = process.env.SUPABASE_TEST_DB_URL;
const EXECUTE = process.argv.includes('--yes');
const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
const devBackup = path.join(root, 'backups', `dev_pre_prod_clone_${stamp}.dump`);
const prodSnap = path.join(root, 'backups', `prod_snapshot_${stamp}.dump`);

const die = (m) => { console.error('\nSTOP: ' + m); process.exit(1); };
const step = (n, m) => console.log(`\n[${n}] ${m}`);
const projectUser = (u) => { const m = /^[a-z]+:\/\/([^:@]+)[:@]/.exec(String(u || '')); return m ? m[1] : ''; };

function sql(url, query) {
  return execFileSync('psql', [url, '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
}
function sqlFile(url, file) {
  return execFileSync('psql', [url, '-X', '-A', '-v', 'ON_ERROR_STOP=1', '-f', file], { encoding: 'utf8' });
}
function run(cmd, args, label) {
  const r = spawnSync(cmd, args, { encoding: 'utf8' });
  if (r.error) die(`${label}: ${r.error.message}`);
  return r;
}

const COUNTS = `select
  (select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE') as tables,
  (select count(*) from information_schema.columns where table_schema='public') as columns,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public') as functions,
  (select count(*) from information_schema.views where table_schema='public') as views,
  (select count(*) from (select 1 from information_schema.triggers where trigger_schema='public' group by event_object_table, trigger_name) t) as triggers,
  (select count(*) from organisations) as organisations,
  (select count(*) from people) as people,
  (select count(*) from leads) as leads,
  (select count(*) from deals) as deals,
  (select count(*) from engagements) as engagements,
  (select count(*) from audit_log) as audit_log,
  (select count(*) filter (where rowsecurity) from pg_tables where schemaname='public') as rls_on,
  (select value from settings where key='environment') as env`;

// ── 1 guards ──────────────────────────────────────────────────────────────────
step(1, 'guards');
if (!PROD || !DEV) die('SUPABASE_DB_URL and SUPABASE_TEST_DB_URL must both be set in .env');
for (const t of ['psql', 'pg_dump', 'pg_restore']) {
  const r = spawnSync(t, ['--version'], { encoding: 'utf8' });
  if (r.error) die(`${t} not on PATH`);
  console.log('   ' + r.stdout.trim());
}
const pu = projectUser(PROD), du = projectUser(DEV);
console.log(`   prod project: ${pu}\n   dev  project: ${du}`);
if (!pu || !du || pu === du) die('prod and dev must be different projects');
const prodFlag = sql(PROD, "select value from settings where key='environment'");
const devFlag = sql(DEV, "select value from settings where key='environment'");
console.log(`   prod flag: ${prodFlag}\n   dev  flag: ${devFlag}`);
if (prodFlag !== 'Production') die(`prod flag is '${prodFlag}', expected 'Production'`);
if (devFlag !== 'Development') die(`dev flag is '${devFlag}', expected 'Development' — refusing to wipe it`);
const busy = sql(DEV, "select count(*) from pg_stat_activity where datname=current_database() and pid<>pg_backend_pid() and state<>'idle'");
console.log(`   other active sessions on dev: ${busy}`);
if (+busy > 0) die('dev has active sessions — wait for them to finish, then re-run');
const before = sql(PROD, COUNTS);
console.log('   prod counts (tables|columns|functions|views|triggers|orgs|people|leads|deals|engs|audit|rls_on|env):\n   ' + before);
fs.mkdirSync(path.join(root, 'backups'), { recursive: true });

if (!EXECUTE) {
  console.log(`\nDRY RUN — nothing changed. Plan:\n   2 backup dev  -> ${devBackup}\n   3 export prod -> ${prodSnap}\n   4-8 wipe + restore dev, grants, RLS lockdown, environment flag\n   9 verify against the prod counts above\nRe-run with --yes to execute.`);
  process.exit(0);
}

// ── 2 backup dev ──────────────────────────────────────────────────────────────
step(2, `backup dev -> ${devBackup}`);
{
  const r = run('pg_dump', [DEV, '-Fc', '--schema=public', '--no-owner', '-f', devBackup], 'pg_dump dev');
  if (r.status !== 0) die('dev backup failed:\n' + r.stderr);
  console.log(`   ${fs.statSync(devBackup).size} bytes`);
}

// ── 3 export prod (read-only) ─────────────────────────────────────────────────
step(3, `export prod -> ${prodSnap}`);
{
  const r = run('pg_dump', [PROD, '-Fc', '--schema=public', '--no-owner', '--no-privileges', '-f', prodSnap], 'pg_dump prod');
  if (r.status !== 0) die('prod export failed:\n' + r.stderr);
  console.log(`   ${fs.statSync(prodSnap).size} bytes`);
}

// ── 4 wipe dev public schema ──────────────────────────────────────────────────
step(4, 'dev: drop + recreate schema public');
sql(DEV, `drop schema public cascade;
create schema public;
grant usage, create on schema public to postgres, service_role;
grant usage on schema public to anon, authenticated;`);
console.log('   done');

// ── 5 restore ─────────────────────────────────────────────────────────────────
step(5, 'dev: pg_restore snapshot');
{
  const r = run('pg_restore', ['-d', DEV, '--no-owner', '--no-privileges', '--schema=public', prodSnap], 'pg_restore');
  const errs = (r.stderr || '').split('\n').filter(l => /error:/i.test(l) && !/already exists/i.test(l));
  const benign = (r.stderr || '').split('\n').filter(l => /already exists/i.test(l)).length;
  console.log(`   exit ${r.status}; benign 'already exists' notices: ${benign}; other errors: ${errs.length}`);
  if (errs.length) die('restore reported errors:\n' + errs.join('\n'));
}

// ── 6 grants for the proxy's role ─────────────────────────────────────────────
step(6, 'dev: service_role grants + schema reload');
sql(DEV, `grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all functions in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant all on functions to service_role;
notify pgrst, 'reload schema';`);
console.log('   done');

// ── 7 RLS lockdown ────────────────────────────────────────────────────────────
step(7, 'dev: sql/enable_rls_lockdown.sql');
console.log(sqlFile(DEV, path.join(root, 'sql', 'enable_rls_lockdown.sql')).trim().split('\n').slice(-6).join('\n   '));

// ── 8 environment flag ────────────────────────────────────────────────────────
step(8, "dev: settings.environment = 'Development'");
sql(DEV, "update settings set value = 'Development' where key = 'environment'");
console.log('   ' + sql(DEV, "select value from settings where key='environment'"));

// ── 9 verify ──────────────────────────────────────────────────────────────────
step(9, 'verify');
const after = sql(DEV, COUNTS);
console.log('   prod: ' + before + '\n   dev:  ' + after);
const p = before.split('|'), d = after.split('|');
const labels = ['tables', 'columns', 'functions', 'views', 'triggers', 'organisations', 'people', 'leads', 'deals', 'engagements', 'audit_log', 'rls_on', 'env'];
let bad = 0;
labels.forEach((l, i) => {
  const ok = l === 'env' ? d[i] === 'Development' : p[i] === d[i];
  if (!ok) { bad++; console.log(`   MISMATCH ${l}: prod=${p[i]} dev=${d[i]}`); }
});
const grants = sql(DEV, "select count(*) from information_schema.role_table_grants where table_schema='public' and grantee in ('anon','authenticated')");
console.log(`   anon/authenticated table grants on dev: ${grants} (must be 0)`);
if (+grants) bad++;
if (bad) die(`${bad} verification problem(s) — see above. Dev backup: ${devBackup}`);
console.log(`\nDONE — dev is a copy of prod as of now. Dev backup kept at ${devBackup}; prod snapshot at ${prodSnap}.`);
