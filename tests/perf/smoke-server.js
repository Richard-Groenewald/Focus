// Static server for the working tree + a stub for the auth function, so the app
// can be driven in mock mode (?mock=1) without any backend.
const http = require('http'), fs = require('fs'), path = require('path');
const ROOT = path.join(__dirname, '..', '..');
const TYPES = { '.html': 'text/html; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json', '.js': 'text/javascript', '.txt': 'text/plain' };
const proxied = [];
http.createServer((req, res) => {
  const u = new URL(req.url, 'http://localhost');
  if (u.pathname === '/.netlify/functions/sb/auth') {
    let b = ''; req.on('data', c => b += c); req.on('end', () => {
      let j = {}; try { j = JSON.parse(b || '{}'); } catch (e) {}
      const out = j.action === 'env' ? { ok: true, environment: 'Mock' }
        : j.action === 'check' ? { ok: true, mustSet: false }
        : j.action === 'login' ? { ok: true, token: 'v1.mock.token', userId: 1, personId: 1 }
        : { ok: false, error: 'Bad request' };
      res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(out));
    });
    return;
  }
  if (u.pathname.startsWith('/.netlify/functions/')) { proxied.push(req.method + ' ' + u.pathname + u.search); res.writeHead(404); res.end('{}'); return; }
  const rel = u.pathname === '/' ? 'index.html' : decodeURIComponent(u.pathname.slice(1));
  const file = path.join(ROOT, rel);
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end('nf'); return; }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' }); res.end(data);
  });
}).listen(8765, () => console.log('smoke server on 8765'));
process.on('SIGTERM', () => { console.log('proxied (should be none in mock):', proxied); process.exit(0); });
