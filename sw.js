// «بديل» — للإشعارات بس (مفيش كاش للصفحات عشان التحديثات توصل على طول)
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

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
