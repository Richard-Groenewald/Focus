// Netlify build (v7.9.36): publish a minified copy of the single-file app.
//
//   node build.js        → dist/index.html (script minified in place), dist/version.txt,
//                          icons/, assets/, manifest and the other top-level pages.
//
// The development workflow is unchanged: index.html stays the one source file and
// local_preview.js keeps serving it verbatim. Only what Netlify publishes changes:
// the inline <script> is run through esbuild (identifiers at the top level are
// kept, so inline onclick="…" handlers still resolve), comments go, and the
// __BUILD_BRANCH__ / __BUILD_COMMIT__ placeholders are stamped exactly as the old
// sed command did. The 1.5 MB script ships at roughly two thirds of its raw size,
// which after gzip is ~150 KB less on every load and every post-deploy reload.
'use strict';
const fs = require('fs');
const path = require('path');
const esbuild = require('esbuild');

const root = __dirname;
const dist = path.join(root, 'dist');
const OPEN = '<script>\n';

let html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const open = html.indexOf(OPEN);
const close = html.lastIndexOf('</script>');
if (open < 0 || close < 0 || close < open) throw new Error('build.js: app <script> block not found in index.html');

const js = html.slice(open + OPEN.length, close);
const out = esbuild.transformSync(js, {
  minify: true,
  target: 'es2020',
  legalComments: 'none',
  logLevel: 'error',
});
html = html.slice(0, open) + OPEN + out.code + '\n' + html.slice(close);

// Build stamp — same placeholders and env vars as the previous netlify.toml command.
html = html.split('__BUILD_BRANCH__').join(process.env.BRANCH || 'local')
           .split('__BUILD_COMMIT__').join(process.env.COMMIT_REF || 'local');

fs.rmSync(dist, { recursive: true, force: true });
fs.mkdirSync(dist, { recursive: true });
fs.writeFileSync(path.join(dist, 'index.html'), html);

// version.txt drives the in-app "newer version available" banner (checkAppVersion).
const version = (html.match(/FOCUS v([0-9.]+)/) || [])[1] || '';
fs.writeFileSync(path.join(dist, 'version.txt'), version + '\n');

// API route per environment (v7.10.21). netlify.toml proxies /sb/* to the PRODUCTION
// project's Supabase Edge Function, and [[redirects]] cannot vary by deploy context.
// A deploy that targets another database — the same SUPABASE_HOST the Netlify
// function has always used to pick its database — gets a _redirects file instead,
// which Netlify processes before netlify.toml, pointing /sb/* at that project's own
// copy of the function. (Unpinned: _redirects cannot add the x-region header.)
const PROD_HOST = 'kevrfdjqyuhmgziqxuvs.supabase.co';
const sbHost = String(process.env.SUPABASE_HOST || '').trim();
if (sbHost && sbHost !== PROD_HOST) {
  if (!/^[a-z0-9.-]+$/i.test(sbHost)) throw new Error(`build.js: SUPABASE_HOST is not a hostname: ${sbHost}`);
  fs.writeFileSync(path.join(dist, '_redirects'), `/sb/*  https://${sbHost}/functions/v1/sb/:splat  200!\n`);
}

// Static files served alongside the app.
for (const dir of ['icons', 'assets']) {
  const from = path.join(root, dir);
  if (fs.existsSync(from)) fs.cpSync(from, path.join(dist, dir), { recursive: true });
}
for (const f of fs.readdirSync(root)) {
  if (f === 'index.html') continue;
  if (/\.(webmanifest|html)$/.test(f)) fs.copyFileSync(path.join(root, f), path.join(dist, f));
}

const kb = n => (n / 1024).toFixed(0) + ' KB';
console.log(`build.js: dist/index.html ${kb(Buffer.byteLength(html))} (script ${kb(Buffer.byteLength(js))} → ${kb(Buffer.byteLength(out.code))}), version ${version || '?'}, /sb → ${sbHost && sbHost !== PROD_HOST ? sbHost + ' (_redirects)' : PROD_HOST + ' (netlify.toml)'}`);
