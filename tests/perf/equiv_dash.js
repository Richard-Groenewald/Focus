// Equivalence test: every dashboard widget rendered from the per-widget reads
// (old path, in-memory mock over a Dev snapshot) vs from the dashboard_summary()
// bundle (new path, the real SQL output for the same snapshot). HTML must match.
const { chromium } = require('playwright'); const fs = require('fs'); const { spawn } = require('child_process');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const path = require('path'); const S = process.env.FOCUS_SNAP_DIR || path.join(__dirname, 'snap'); const SERVER = path.join(__dirname, 'smoke-server.js');
const tables = ['leads','deals','organisations','sites','engagements','engagement_milestones','milestone_groups','milestone_types',
  'promotion_requests','lead_stage_requests','red_flags','lead_red_flags','research_campaigns','bug_reports',
  'revenue_streams','revenue_stream_months','service_sub','stages','industry_sectors','people','settings','engagement_people','work_projects'];
const snap = {}; tables.forEach(t => { snap[t] = JSON.parse(fs.readFileSync(`${S}/${t}.json`, 'utf8')); });
const bundle = JSON.parse(fs.readFileSync(`${S}/bundle.json`, 'utf8'));

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
    allData['service_sub'] = snap.service_sub; allData['stages'] = snap.stages; allData['industry_sectors'] = snap.industry_sectors;
    snap.settings.forEach(s => { appSettings[s.key] = s.value; });
    // Embeds the in-memory mock does not do: sites(name) on leads, months under streams.
    const orig = mockApi; window.__mockCalls = 0;
    window.mockApi = async (table, method, body, params) => {
      window.__mockCalls++;
      const rows = await orig(table, method, body, params);
      const sel = (params || '').split('&').find(kv => kv.startsWith('select=')) || '';
      if (method === 'GET' && table === 'leads' && /sites\(name\)/.test(sel))
        rows.forEach(r => { const s = snap.sites.find(x => +x.id === +r.site_id); r.sites = s ? { name: s.name } : null; });
      if (method === 'GET' && table === 'revenue_streams' && /revenue_stream_months\(/.test(sel))
        rows.forEach(r => { r.revenue_stream_months = snap.revenue_stream_months.filter(m => +m.stream_id === +r.id); });
      return rows;
    };
  }, { snap });

  const run = (mode, scope, personId) => page.evaluate(async ({ mode, scope, personId, bundle }) => {
    currentUser.personId = personId;
    localStorage.setItem(_dashScopeKey(), scope);
    delete allData['milestone_groups']; delete allData['milestone_types']; delete allData['red_flags']; delete allData['_org_touches'];
    window._dashIntPeriod = 'month'; window._dashIntScope = null;
    try { localStorage.removeItem('focus_dash_int_scope_' + personId); } catch (e) {}
    if (mode === 'bundle') { window._dashBundle = JSON.parse(JSON.stringify(bundle)); _dashSeedLookups(window._dashBundle); }
    else window._dashBundle = null;
    window.__mockCalls = 0;
    const sweepP = Promise.resolve({ woke: [], working: [] });
    const out = {};
    out.reminders = await _dashRemindersHtml(window._dashBundle, sweepP);
    const loaders = { approvals: _dashApprovals, actions: _dashActions, leads: _dashLeads, opportunities: _dashOpps,
      pipeline: _dashPipeline, sector_value: _dashSectorValue, campaigns: _dashCampaigns, contracts: _dashContracts,
      company: _dashCompany, bugs: _dashBugs, interactions: _dashInteractions, milestones: _dashMilestones, milestone_pulse: _dashMilestonePulse };
    for (const [k, fn] of Object.entries(loaders)) { try { out[k] = await fn(); } catch (e) { out[k] = 'ERROR ' + e.message + '\n' + e.stack; } }
    window._dashIntPeriod = 'week'; out.interactions_week = await _dashInteractions();
    window._dashIntScope = 'own'; out.interactions_own = await _dashInteractions();
    window._dashIntScope = 'team'; out.interactions_team = await _dashInteractions();
    window._dashIntScope = null; window._dashIntPeriod = 'month';
    const items = await _attentionLeadItems(window._dashBundle, sweepP);
    out.attn_leads = JSON.stringify(items.map(i => [i.id, i.kind, i.msg]));
    const rows = await _attentionActionRows(window._dashBundle);
    out.attn_actions = JSON.stringify(rows.map(r => [r.eng, r.id, r.kind, r.label, r.action, r.due]));
    out.__calls = window.__mockCalls;
    return out;
  }, { mode, scope, personId, bundle });

  let failed = 0;
  for (const [scope, personId] of [['all', 1], ['own', 4105], ['all', 4105]]) {
    const a = await run('old', scope, personId);
    const b = await run('bundle', scope, personId);
    console.log(`\n=== scope=${scope} person=${personId}: old path ${a.__calls} mock calls, bundle path ${b.__calls}`);
    for (const k of Object.keys(a)) {
      if (k === '__calls') continue;
      if (a[k] === b[k]) { console.log('  same ', k, `(${String(a[k]).length} chars)`); continue; }
      // Order among equal sort keys is undefined on the old path (physical order); the bundle orders by id.
      const norm = s => String(s).replace(/<[^>]+>/g, '\n').split(/\n|·|\],\[/).map(x => x.trim().slice(0, 100)).filter(Boolean).sort().join('|');
      if (norm(a[k]) === norm(b[k])) { console.log('  same*', k, '(identical up to tie order / 300-char bug text)'); continue; }
      failed++;
      const i = [...String(a[k])].findIndex((c, i) => c !== String(b[k])[i]);
      console.log('  DIFF ', k, 'at', i, '\n    old: …' + String(a[k]).slice(Math.max(0, i - 120), i + 160) + '\n    new: …' + String(b[k]).slice(Math.max(0, i - 120), i + 160));
    }
    const strip = s => String(s).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 160);
    console.log('  sample leads card:', strip(b.leads)); console.log('  sample actions card:', strip(b.actions)); console.log('  sample pipeline:', strip(b.pipeline));
    console.log('  sample interactions:', strip(b.interactions)); console.log('  reminders:', strip(b.reminders) || '(none)');
  }
  console.log('\npage errors:', errors.length ? errors : 'none');
  await browser.close(); server.kill('SIGTERM');
  if (failed || errors.length) process.exit(1);
})().catch(e => { console.error('FAILED', e); process.exit(1); });
