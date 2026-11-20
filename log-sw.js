// Focus Log service worker: keeps the /log page openable with no signal (mines, estates).
// It caches ONLY the page shell and icons; API traffic (/sb/) is never touched, so data
// is always live when there is a connection and the page's own offline queue handles the rest.
'use strict';
const CACHE = 'focus-log-v1';
const SHELL = ['/log', '/log.html', '/log.webmanifest', '/icons/icon-192.png', '/icons/apple-touch-icon.png', '/icons/favicon-48.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => Promise.all(SHELL.map(u => c.add(u).catch(() => {})))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k.startsWith('focus-log-') && k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.origin !== location.origin || u.pathname.startsWith('/sb/')) return;
  const isPage = r.mode === 'navigate' && (u.pathname === '/log' || u.pathname === '/log.html');
  const isShell = SHELL.includes(u.pathname);
  if (!isPage && !isShell) return;
  // network first so a new deploy shows at once; the cached copy only answers when the network does not
  e.respondWith(fetch(r).then(res => {
    if (res && res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(isPage ? '/log' : r, copy)); }
    return res;
  }).catch(() => caches.match(isPage ? '/log' : r).then(m => m || Response.error())));
});
