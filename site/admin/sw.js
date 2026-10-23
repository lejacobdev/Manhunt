/* Caches the app shell only, for an instant launch from the home screen. API responses are
   never cached: reports and player data must not persist on a phone that could be lost. */
const SHELL = "hg-admin-shell-v1";
const FILES = ["/admin/", "/admin/admin.css", "/admin/admin.js", "/admin/manifest.json",
  "/admin/icon-192.png", "/admin/icon-512.png", "/assets/apple-touch-icon.png", "/assets/favicon-32.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== SHELL).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== self.location.origin) return; // API: straight to network
  // Network first so a deploy shows up on the next launch; the cache is the offline fallback.
  e.respondWith(
    fetch(e.request)
      .then((res) => {
        if (res.ok && FILES.includes(url.pathname)) { const copy = res.clone(); caches.open(SHELL).then((c) => c.put(e.request, copy)); }
        return res;
      })
      .catch(() => caches.match(e.request).then((hit) => hit || caches.match("/admin/")).then((hit) => hit || offline()))
  );
});
function offline() {
  return new Response(`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>Offline</title>
<body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#090B10;color:#F4F6FA;font:15px -apple-system,system-ui,sans-serif;text-align:center">
<div><div style="font:800 22px ui-rounded,-apple-system,sans-serif">You're offline</div><p style="color:rgba(244,246,250,.55)">The admin panel needs a connection. It'll load as soon as you're back online.</p></div>`,
    { headers: { "Content-Type": "text/html; charset=utf-8" } });
}
