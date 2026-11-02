// Deliberately network-only: this app handles private financial data and must not cache API responses.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()));
self.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return;
  // Do not store request or response bodies. Browser HTTP cache may handle static Next assets.
  event.respondWith(fetch(event.request));
});
