// Equivalence test: Engagement History built from the three-round reads (old
// path, in-memory mock over the Dev snapshot) vs from engagements_labelled (new
// path, the real view output for the same snapshot). Rows + HTML must match.
const { chromium } = require('playwright'); const fs = require('fs'); const { spawn } = require('child_process');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const path = require('path'); const S = process.env.FOCUS_SNAP_DIR || path.join(__dirname, 'snap'); const SERVER = path.join(__dirname, 'smoke-server.js');
const tables = ['leads','deals','organisations','sites','engagements','engagement_milestones','milestone_groups','milestone_types',
  'service_sub','stages','people','settings','engagement_people'];
const snap = {}; tables.forEach(t => { snap[t] = JSON.parse(fs.readFileSync(`${S}/${t}.json`, 'utf8')); });
const view = JSON.parse(fs.readFileSync(`${S}/engagements_labelled.json`, 'utf8'));

(async () => {
  const server = spawn('node', [SERVER], { stdio: 'ignore' }); await sleep(900);
  const browser = await chromium.launch(); const page = await browser.newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  await page.goto('http://localhost:8765/?mock=reset'); await page.waitForSelector('#login-username', { state: 'visible' });
  await page.fill('#login-username', 'richard'); await page.fill('#login-password', 'mock'); await page.click('#login-btn');
  await page.waitForSelector('#main-app', { state: 'visible' }); await sleep(2500);

  await page.evaluate(({ snap }) => {
    const db = _mockStore(); Object.entries(snap).forEach(([t, rows]) => { db[t] = rows; });
    allData['organisations'] = snap.organisations; allData['sites'] = snap.sites; allData['people'] = snap.people;
    allData['service_sub'] = snap.service_sub; allData['stages'] = snap.stages;
    currentUser.personId = 4105;
    const orig = mockApi; window.__mockCalls = 0;
    window.mockApi = async (table, method, body, params) => {
      window.__mockCalls++;
      const rows = await orig(table, method, body, params);
      const sel = (params || '').split('&').find(kv => kv.startsWith('select=')) || '';
      if (method === 'GET' && table === 'leads' && /sites\(name\)/.test(sel))
        rows.forEach(r => { const s = snap.sites.find(x => +x.id === +r.site_id); r.sites = s ? { name: s.name } : null; });
      return rows;
    };
  }, { snap });

  const canon = v => JSON.stringify(v, (k, x) => (x && typeof x === 'object' && !Array.isArray(x)) ? Object.keys(x).sort().reduce((o, kk) => (o[kk] = x[kk], o), {}) : x);
  const run = (mode, cat, scope) => page.evaluate(async ({ mode, cat, scope, view }) => {
    const db = _mockStore();
    if (mode === 'view') db['engagements_labelled'] = view; else delete db['engagements_labelled'];
    localStorage.setItem(_engHistScopeKey(), scope);
    delete allData['milestone_groups']; delete allData['milestone_types'];
    window.__mockCalls = 0;
    await renderEngagementHistory(cat);
    const st = window._engHist;
    return { calls: window.__mockCalls, n: st.rows.length, capHit: st.capHit,
             rows: st.rows, milestones: st.milestones, clients: st.clients, deals: st.deals, persons: st.persons,
             html: (document.getElementById('eh-results') || {}).innerHTML || '' };
  }, { mode, cat, scope, view });

  let failed = 0;
  for (const cat of ['Outreach', 'Sales', 'Contract', 'Project', 'All']) {
    for (const scope of ['mine', 'all']) {
      const a = await run('old', cat, scope), b = await run('view', cat, scope);
      const ok = k => canon(a[k]) === canon(b[k]);
      const keys = ['n', 'capHit', 'rows', 'milestones', 'clients', 'deals', 'persons', 'html'];
      const bad = keys.filter(k => !ok(k));
      console.log(`${cat.padEnd(9)} ${scope.padEnd(4)} rows=${a.n}/${b.n} calls old=${a.calls} view=${b.calls} html=${a.html.length}/${b.html.length} → ${bad.length ? 'DIFF ' + bad.join(',') : 'identical'}`);
      if (bad.length) {
        failed++;
        if (bad.includes('rows')) {
          for (let i = 0; i < Math.max(a.rows.length, b.rows.length); i++) {
            if (canon(a.rows[i]) !== canon(b.rows[i])) {
              const ra = a.rows[i] || {}, rb = b.rows[i] || {};
              for (const k of new Set([...Object.keys(ra), ...Object.keys(rb)])) if (canon(ra[k]) !== canon(rb[k])) console.log('   row', i, 'key', k, '\n     old:', canon(ra[k]).slice(0, 300), '\n     new:', canon(rb[k]).slice(0, 300));
              break;
            }
          }
        } else if (bad.includes('html')) {
          const i = [...a.html].findIndex((c, i) => c !== b.html[i]);
          console.log('   html diff at', i, '\n     old: …' + a.html.slice(Math.max(0, i - 100), i + 120) + '\n     new: …' + b.html.slice(Math.max(0, i - 100), i + 120));
        } else for (const k of bad) console.log('   ', k, '\n     old:', canon(a[k]).slice(0, 300), '\n     new:', canon(b[k]).slice(0, 300));
      }
    }
  }
  console.log('page errors:', errors.length ? errors : 'none');
  await browser.close(); server.kill('SIGTERM');
  if (failed || errors.length) process.exit(1);
})().catch(e => { console.error('FAILED', e); process.exit(1); });
