// fam.ly service worker: Web Push only (no offline caching yet).
// iOS requires every push to show a visible notification, so we always do (BUILD_PLAN §0).
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = {};
  }
  event.waitUntil(
    (async () => {
      await self.registration.showNotification(data.title || "fam.ly", {
        body: data.body || "Family update in fam.ly",
        // Pushes now say what happened, so each one stays on the lock screen. Only a prompt replaces
        // an earlier prompt of the same kind (e.g. a snoozed "Are you back?").
        tag: data.tag && data.tag.startsWith("prompt.") ? data.tag : undefined,
        icon: "/icons/icon-192.png",
        badge: "/icons/badge-72.png",
        data: { url: data.url || "/" },
      });
      // Home-screen badge (Badging API); the app sets the exact count when opened.
      if (self.navigator && "setAppBadge" in self.navigator) {
        try {
          await self.navigator.setAppBadge();
        } catch {
          /* not supported */
        }
      }
    })(),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || "/", self.location.origin).href;
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      for (const client of windows) {
        if ("focus" in client) {
          await client.focus();
          if ("navigate" in client) await client.navigate(url);
          return;
        }
      }
      await self.clients.openWindow(url);
    })(),
  );
});
