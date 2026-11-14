#!/usr/bin/env node
// Offline backup of Focus: databases, repository and uploaded files into ONE dated
// folder that can be copied to an external drive. Everything here only READS.
//
//   node scripts/backup_offline.js <destination folder>            full set
//   node scripts/backup_offline.js <destination folder> --no-dev   skip the dev database
//   node scripts/backup_offline.js <destination folder> --no-files skip the storage bucket
//
// Runs on a PC that has psql / pg_dump on PATH (scoop postgresql) and a .env in the
// repo root with:
//   SUPABASE_DB_URL        prod Postgres URL            (required)
//   SUPABASE_TEST_DB_URL   dev Postgres URL             (optional; --no-dev when absent)
//   SUPABASE_HOST          prod project host            (optional; defaults to the prod ref)
//   SUPABASE_SECRET_KEY    prod service-role JWT        (optional; needed for the storage bucket)
// No secret is ever written into the backup folder.
//
// The folder  <destination>/Focus-backup-<YYYYMMDD-HHMM>/  holds:
//   db/prod.dump, db/prod.sql          pg_dump custom format (pg_restore) and plain SQL
//   db/dev.dump,  db/dev.sql           the same for dev (unless --no-dev)
//   db/prod_counts.txt, db/dev_counts.txt   object and row counts at backup time
//   repo/Focus.bundle                  git bundle of every branch and tag (git clone Focus.bundle)
//   repo/worktree-<branch>.zip         a plain archive of the current checkout (no .git)
//   files/attachments/...              the private storage bucket, same paths as in storage
//   files/attachments_index.json       the bucket listing as returned by storage
//   MANIFEST.txt                       SHA-256 of every file written, sizes, versions
//   RESTORE.md                         how to rebuild from this set
const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const https = require('https');

const root = path.resolve(__dirname, '..');
require('dotenv').config({ path: path.join(root, '.env') });

const args = process.argv.slice(2);
const dest = args.find(a => !a.startsWith('--'));
const NO_DEV = args.includes('--no-dev');
const NO_FILES = args.includes('--no-files');
const PROD = process.env.SUPABASE_DB_URL;
const DEV = process.env.SUPABASE_TEST_DB_URL;
const SB_HOST = process.env.SUPABASE_HOST || 'kevrfdjqyuhmgziqxuvs.supabase.co';
const SB_KEY = process.env.SUPABASE_SECRET_KEY;
const BUCKET = 'attachments';

const die = (m) => { console.error('\nSTOP: ' + m); process.exit(1); };
const step = (n, m) => console.log(`\n[${n}] ${m}`);
// Names a database without its password: "postgres.<ref>@<host>/<db>" — the pooler
// URL carries the project ref in the user name, a direct URL carries it in the host.
const projectOf = (u) => { const m = /^[a-z]+:\/\/([^:@]+)(?::[^@]*)?@([^/?]*)\/?([^?]*)(\?.*)?$/.exec(String(u || '')); return m ? `${m[1]}@${m[2]}/${m[3]}${m[4] || ''}` : String(u || ''); };
const human = (b) => b < 1024 ? b + ' B' : b < 1048576 ? (b / 1024).toFixed(1) + ' KB' : (b / 1048576).toFixed(1) + ' MB';

if (!dest) die('give the destination folder, e.g.  node scripts/backup_offline.js D:\\Focus-backups');
if (!PROD) die('SUPABASE_DB_URL is not set in .env');
if (!NO_DEV && !DEV) die('SUPABASE_TEST_DB_URL is not set in .env — pass --no-dev to skip the dev database');
if (!NO_DEV && projectOf(PROD) === projectOf(DEV)) die('prod and dev URLs point at the same project');

for (const t of ['psql', 'pg_dump', 'git']) {
  const r = spawnSync(t, ['--version'], { encoding: 'utf8' });
  if (r.error) die(`${t} is not on PATH`);
}

const stamp = new Date().toISOString().slice(0, 16).replace(/[-:]/g, '').replace('T', '-');
const out = path.join(path.resolve(dest), `Focus-backup-${stamp}`);
const dirs = { db: path.join(out, 'db'), repo: path.join(out, 'repo'), files: path.join(out, 'files') };
for (const d of Object.values(dirs)) fs.mkdirSync(d, { recursive: true });
console.log('Writing to ' + out);

const written = [];
const note = (file, extra) => { written.push({ file, extra }); };

function sql(url, query) {
  return execFileSync('psql', [url, '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
}
function run(cmd, cmdArgs, label) {
  const r = spawnSync(cmd, cmdArgs, { encoding: 'utf8', maxBuffer: 1 << 28 });
  if (r.error) die(`${label}: ${r.error.message}`);
  if (r.status !== 0) die(`${label} failed:\n${r.stderr}`);
  return r;
}

const COUNTS = `select
  (select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE') as tables,
  (select count(*) from information_schema.views where table_schema='public') as views,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public') as functions,
  (select count(*) from (select 1 from information_schema.triggers where trigger_schema='public' group by event_object_table, trigger_name) t) as triggers,
  (select count(*) from organisations) as organisations,
  (select count(*) from people) as people,
  (select count(*) from leads) as leads,
  (select count(*) from deals) as deals,
  (select count(*) from engagements) as engagements,
  (select count(*) from revenue_stream_months) as revenue_stream_months,
  (select count(*) from audit_log) as audit_log,
  (select coalesce(value,'?') from settings where key='environment' limit 1) as environment,
  (select pg_size_pretty(pg_database_size(current_database()))) as database_size,
  now() as taken_at`;

// ---------------------------------------------------------------- databases
function dumpDb(name, url, n) {
  step(n, `${name} database — ${projectOf(url)} (read-only)`);
  const counts = sql(url, COUNTS);
  const countsFile = path.join(dirs.db, `${name}_counts.txt`);
  fs.writeFileSync(countsFile, 'tables|views|functions|triggers|organisations|people|leads|deals|engagements|revenue_stream_months|audit_log|environment|database_size|taken_at\n' + counts + '\n');
  console.log('    ' + counts);
  note(countsFile);
  const common = ['--schema=public', '--no-owner', '--no-privileges'];
  const dump = path.join(dirs.db, `${name}.dump`);
  run('pg_dump', [url, '-Fc', ...common, '-f', dump], `pg_dump ${name} (custom)`);
  note(dump, 'pg_dump custom format, schema public');
  const plain = path.join(dirs.db, `${name}.sql`);
  run('pg_dump', [url, '-Fp', ...common, '--inserts', '-f', plain], `pg_dump ${name} (plain)`);
  note(plain, 'pg_dump plain SQL with INSERTs, schema public');
  // Storage metadata (the bucket row and object list) so the files folder can be re-linked.
  const storage = path.join(dirs.db, `${name}_storage_objects.sql`);
  const r = spawnSync('pg_dump', [url, '-Fp', '--data-only', '--inserts', '--table=storage.buckets', '--table=storage.objects', '-f', storage], { encoding: 'utf8' });
  if (r.status === 0) note(storage, 'storage.buckets and storage.objects rows'); else console.log('    (storage schema not dumped: ' + (r.stderr || '').trim().split('\n')[0] + ')');
  console.log(`    ${human(fs.statSync(dump).size)} custom, ${human(fs.statSync(plain).size)} plain`);
}
dumpDb('prod', PROD, 1);
if (!NO_DEV) dumpDb('dev', DEV, 2); else console.log('\n[2] dev database skipped (--no-dev)');

// ---------------------------------------------------------------- repository
step(3, 'repository');
const git = (...a) => execFileSync('git', a, { cwd: root, encoding: 'utf8' }).trim();
const branch = git('rev-parse', '--abbrev-ref', 'HEAD');
const head = git('rev-parse', 'HEAD');
const dirty = git('status', '--porcelain');
try { git('fetch', '--all', '--tags', '--prune'); console.log('    fetched origin'); } catch (e) { console.log('    could not fetch origin (offline?) — bundling what is local'); }
const bundle = path.join(dirs.repo, 'Focus.bundle');
run('git', ['-C', root, 'bundle', 'create', bundle, '--all'], 'git bundle');
run('git', ['-C', root, 'bundle', 'verify', bundle], 'git bundle verify');
note(bundle, 'git bundle, every branch and tag; clone with: git clone Focus.bundle Focus');
const zip = path.join(dirs.repo, `worktree-${branch.replace(/[^A-Za-z0-9_.-]/g, '_')}.zip`);
run('git', ['-C', root, 'archive', '--format=zip', '-o', zip, 'HEAD'], 'git archive');
note(zip, `tracked files at ${head.slice(0, 10)} on ${branch}${dirty ? ' (uncommitted changes NOT included)' : ''}`);
if (dirty) console.log('    NOTE: the checkout has uncommitted changes; they are not in the bundle or the zip:\n' + dirty.split('\n').map(l => '      ' + l).join('\n'));
const refs = path.join(dirs.repo, 'refs.txt');
fs.writeFileSync(refs, git('for-each-ref', '--format=%(refname) %(objectname) %(committerdate:iso)') + '\n');
note(refs);
console.log(`    ${human(fs.statSync(bundle).size)} bundle, ${human(fs.statSync(zip).size)} zip`);

// ---------------------------------------------------------------- storage bucket
function sbRequest(method, p, body) {
  return new Promise((resolve, reject) => {
    const req = https.request({ hostname: SB_HOST, port: 443, path: '/storage/v1' + p, method,
      headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY, 'Content-Type': 'application/json' } }, (res) => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}
async function listAll(prefix) {
  const files = [];
  let offset = 0;
  for (;;) {
    const r = await sbRequest('POST', `/object/list/${BUCKET}`, { prefix, limit: 1000, offset, sortBy: { column: 'name', order: 'asc' } });
    if (r.status !== 200) throw new Error(`list ${prefix || '/'} → ${r.status} ${r.body.toString().slice(0, 200)}`);
    const rows = JSON.parse(r.body.toString());
    for (const row of rows) {
      const full = prefix ? `${prefix}/${row.name}` : row.name;
      if (row.id === null) files.push(...await listAll(full)); // a folder
      else files.push({ path: full, size: row.metadata && row.metadata.size, updated_at: row.updated_at, id: row.id });
    }
    if (rows.length < 1000) break;
    offset += rows.length;
  }
  return files;
}
async function downloadBucket() {
  step(4, `storage bucket '${BUCKET}' on ${SB_HOST}`);
  if (NO_FILES) { console.log('    skipped (--no-files)'); return; }
  if (!SB_KEY) { console.log('    skipped: SUPABASE_SECRET_KEY is not set in .env (the uploaded deal files are not in this set)'); return; }
  let files;
  try { files = await listAll(''); } catch (e) { console.log('    could not list the bucket: ' + e.message); return; }
  const index = path.join(dirs.files, `${BUCKET}_index.json`);
  fs.writeFileSync(index, JSON.stringify(files, null, 2));
  note(index, `${files.length} objects listed`);
  let bytes = 0, failed = 0;
  for (const f of files) {
    const target = path.join(dirs.files, BUCKET, ...f.path.split('/'));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    const r = await sbRequest('GET', `/object/${BUCKET}/${f.path.split('/').map(encodeURIComponent).join('/')}`);
    if (r.status !== 200) { failed++; console.log(`    FAILED ${f.path} → ${r.status}`); continue; }
    fs.writeFileSync(target, r.body);
    bytes += r.body.length;
    note(target, `storage object ${f.id}`);
  }
  console.log(`    ${files.length - failed} of ${files.length} files, ${human(bytes)}${failed ? `, ${failed} FAILED` : ''}`);
}

// ---------------------------------------------------------------- manifest
function sha256(file) {
  const h = crypto.createHash('sha256');
  h.update(fs.readFileSync(file));
  return h.digest('hex');
}
function writeManifest() {
  step(5, 'manifest and restore guide');
  const guide = path.join(root, 'docs', 'backup', 'RESTORE.md');
  if (fs.existsSync(guide)) { fs.copyFileSync(guide, path.join(out, 'RESTORE.md')); note(path.join(out, 'RESTORE.md')); }
  const lines = [
    `Focus offline backup — taken ${new Date().toISOString()}`,
    `prod project: ${projectOf(PROD)}    dev project: ${NO_DEV ? '(skipped)' : projectOf(DEV)}`,
    `repo: ${branch} @ ${head}${dirty ? ' (dirty checkout)' : ''}`,
    `pg_dump: ${spawnSync('pg_dump', ['--version'], { encoding: 'utf8' }).stdout.trim()}`,
    `node: ${process.version}`,
    '',
    'sha256                                                            size        file',
  ];
  let total = 0;
  for (const w of written.sort((a, b) => a.file.localeCompare(b.file))) {
    const size = fs.statSync(w.file).size; total += size;
    lines.push(`${sha256(w.file)}  ${String(size).padStart(10)}  ${path.relative(out, w.file).split(path.sep).join('/')}${w.extra ? '   # ' + w.extra : ''}`);
  }
  lines.push('', `${written.length} files, ${human(total)} in all`);
  fs.writeFileSync(path.join(out, 'MANIFEST.txt'), lines.join('\n') + '\n');
  console.log(`    ${written.length} files, ${human(total)}`);
  console.log(`\nDone. Copy the whole folder to the offline drive:\n  ${out}\n`);
}

downloadBucket().then(writeManifest).catch(e => die(e.stack || e.message));
