// Orbyt Portal service worker: makes the portal installable, and shows a friendly page when there's no connection.
// Pages always come from the network, so every update reaches people right away. Data (Supabase) is never cached.
const CACHE = "orbyt-shell-v2";
const SHELL = ["/favicon.svg", "/icon-192.png", "/icon-512.png", "/apple-touch-icon.png", "/manifest.webmanifest"];
self.addEventListener("install", e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
const OFFLINE = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Orbyt Portal</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#F6F4EA;color:#18314F;font-family:Jost,system-ui,sans-serif;text-align:center;padding:24px}
h1{font-weight:500;font-size:24px;margin:16px 0 6px}p{margin:0 0 18px;color:#5E6E83}button{font:inherit;background:#18314F;color:#F6F4EA;border:0;border-radius:999px;padding:10px 22px}</style></head>
<body><div><img src="/icon-192.png" width="72" height="72" alt=""><h1>You're offline</h1><p>Orbyt needs a connection to load your projects. Check your signal or Wi-Fi.</p><button onclick="location.reload()">Try again</button></div></body></html>`;
self.addEventListener("fetch", e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== "GET" || u.origin !== self.location.origin) return;
  if (r.mode === "navigate") {
    e.respondWith(fetch(r).catch(() => new Response(OFFLINE, { headers: { "content-type": "text/html; charset=utf-8" } })));
    return;
  }
  if (SHELL.includes(u.pathname)) e.respondWith(caches.match(r).then(m => m || fetch(r)));
});
