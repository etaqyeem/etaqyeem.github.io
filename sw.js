/* Service Worker — يخزّن واجهة التطبيق ليعمل بسرعة وبدون إنترنت
   (البيانات نفسها تحتاج اتصالًا لأنها في Supabase). */

const CACHE = "taqyeem-v1";
const SHELL = [
  "./",
  "./index.html",
  "./config.js",
  "./manifest.webmanifest",
  "./icon.svg"
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  // لا تخزّن نداءات Supabase إطلاقًا — يجب أن تكون البيانات حيّة دائمًا
  if (url.hostname.endsWith("supabase.co")) return;

  // الواجهة: من الشبكة أولًا ثم الكاش عند انقطاع الاتصال
  e.respondWith(
    fetch(req)
      .then((res) => {
        if (res && res.status === 200 && url.origin === location.origin) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
        }
        return res;
      })
      .catch(() => caches.match(req).then((hit) => hit || caches.match("./index.html")))
  );
});
