// Service worker tối giản: network-first cho file cùng origin, rơi về cache khi mất mạng.
// Không đụng tới request cross-origin (Supabase, fonts, CDN) nên realtime/RPC không bị ảnh hưởng.
const CACHE = "al-lunch-v1";
const SHELL = ["/", "/index.html", "/split.html", "/supabase-adapter.js", "/supabase-config.js", "/manifest.json"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== location.origin) return;
  e.respondWith(
    fetch(req)
      .then(res => {
        if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
        return res;
      })
      .catch(() => caches.match(req, { ignoreSearch: true }).then(r => r || caches.match("/index.html")))
  );
});
