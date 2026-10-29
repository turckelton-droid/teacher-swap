// «بديل» — الإشعارات + فتح البرنامج من غير نت
// الشبكة أولًا (عشان التحديثات توصل على طول)، ولو مفيش نت نفتح آخر نسخة محفوظة
const CACHE = 'badeel-v1';
const CORE = ['./', 'manifest.json', 'icon.svg', 'icon-192.png', 'apple-touch-icon.png',
  'fonts/KOSans-Regular.woff2', 'fonts/KOSans-Medium.woff2', 'fonts/KOSans-Bold.woff2'];

self.addEventListener('install', e => e.waitUntil(
  caches.open(CACHE).then(c => Promise.all(CORE.map(u => c.add(new Request(u, {cache: 'reload'})).catch(() => {}))))
    .then(() => self.skipWaiting())));
self.addEventListener('activate', e => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
  await self.clients.claim();
})()));

self.addEventListener('fetch', e => {
  const req = e.request; if (req.method !== 'GET') return;
  const url = new URL(req.url), same = url.origin === self.location.origin;
  const gf = /^fonts\.(googleapis|gstatic)\.com$/.test(url.hostname);
  if (!same && !gf) return;              // Supabase وغيره: من غير تدخل
  if (same && req.cache === 'no-store') return;   // فحص «يوجد تحديث»
  e.respondWith(netFirst(req, same));
});

async function netFirst(req, same){
  const cache = await caches.open(CACHE);
  const net = fetch(req).then(r => {
    if ((r.ok && !r.redirected) || r.type === 'opaque') cache.put(req, r.clone()).catch(() => {});
    return r;
  });
  try {
    return await Promise.race([net, new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 6000))]);
  } catch (_) {
    const hit = await cache.match(req, {ignoreSearch: same}) || (req.mode === 'navigate' ? await cache.match('./') : null);
    if (hit) return hit;
    return net;   // مفيش نسخة محفوظة: نستنى الشبكة
  }
}

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data && e.data.text() }; }
  e.waitUntil((async () => {
    await self.registration.showNotification(d.title || 'بديل', {
      body: d.body || '', tag: d.tag, renotify: !!d.tag, dir: 'rtl', lang: 'ar',
      icon: 'icon-192.png', badge: 'icon-192.png', data: { url: d.url || './' }
    });
    // نقول للصفحة لو مفتوحة تحدّث نفسها
    const cs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    cs.forEach(c => c.postMessage({ t: 'push' }));
  })());
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const cs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of cs) { if (c.url.startsWith(self.registration.scope)) { c.postMessage({ t: 'open', tab: 'req' }); return c.focus(); } }
    return self.clients.openWindow(url);
  })());
});
