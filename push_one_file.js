// One-off, single-file pusher for the rare follow-up (a sql file that missed the release
// train). Same auth as push_to_github.js. Usage:
//   FILE=sql/whatever.sql MSG="message" BRANCH=main node push_one_file.js
require('dotenv').config();
const https = require('https');
const fs = require('fs');
const path = require('path');
const TOKEN = process.env.GITHUB_TOKEN;
const REPO = 'Richard-Groenewald/Focus';
const BRANCH = process.env.BRANCH || 'main';
const FILE = process.env.FILE;
const MSG = process.env.MSG || ('Add ' + FILE);
if (!TOKEN || !FILE) { console.error('Need GITHUB_TOKEN (.env) and FILE env var'); process.exit(1); }

function gh(method, p, data) {
  return new Promise((resolve, reject) => {
    const body = data ? JSON.stringify(data) : null;
    const req = https.request({ hostname: 'api.github.com', port: 443, path: p, method,
      headers: { 'Authorization': 'token ' + TOKEN, 'User-Agent': 'nodejs',
        'Accept': 'application/vnd.github.v3+json', 'Content-Type': 'application/json',
        ...(body ? { 'Content-Length': Buffer.byteLength(body) } : {}) } }, res => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => res.statusCode >= 400 ? reject(new Error(`HTTP ${res.statusCode}: ${d.slice(0, 200)}`)) : resolve(JSON.parse(d || '{}')));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

(async () => {
  const content = fs.readFileSync(path.join(__dirname, FILE)).toString('base64');
  let sha;
  try { sha = (await gh('GET', `/repos/${REPO}/contents/${FILE}?ref=${BRANCH}`)).sha; } catch (e) {}
  const r = await gh('PUT', `/repos/${REPO}/contents/${FILE}`,
    { message: MSG, content, branch: BRANCH, ...(sha ? { sha } : {}),
      author: { name: 'Richard Groenewald', email: 'richard@xone.co.za' },
      committer: { name: 'Richard Groenewald', email: 'richard@xone.co.za' } });
  console.log(`✓ ${FILE} → ${BRANCH} - ${(r.commit && r.commit.sha || '').slice(0, 8)}`);
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
