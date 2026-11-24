"use strict";

const CACHE_NAME = "noteit-shell-v3";
const PRECACHE_URLS = [
  "/",
  "/manifest.webmanifest",
  "/static/styles.css",
  "/static/db.js",
  "/static/recorder.js",
  "/static/app.js",
  "/static/icons/icon-192.png",
  "/static/icons/icon-512.png",
  "/static/icons/apple-touch-icon.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.addAll(PRECACHE_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => key.startsWith("noteit-shell-") && key !== CACHE_NAME)
            .map((key) => caches.delete(key))
        )
      )
      .then(() => self.clients.claim())
  );
});

function isShellAssetPath(pathname) {
  return (
    pathname.startsWith("/static/") ||
    pathname === "/manifest.webmanifest" ||
    pathname === "/apple-touch-icon.png"
  );
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Never cache API responses or health checks.
  if (url.pathname.startsWith("/api/") || url.pathname === "/health") {
    return;
  }

  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (res && res.ok) {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put("/", copy));
          }
          return res;
        })
        .catch(() => caches.match("/").then((cached) => cached || Response.error()))
    );
    return;
  }

  if (isShellAssetPath(url.pathname)) {
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (res && res.ok) {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
          }
          return res;
        })
        .catch(() => caches.match(req).then((cached) => cached || Response.error()))
    );
  }
});

function parsePushPayload(event) {
  const fallback = {
    title: "NoteIt",
    body: "Meeting update available.",
    url: "/",
    tag: "noteit",
    meeting_id: null,
  };
  if (!event.data) return fallback;
  try {
    const data = event.data.json();
    if (data && typeof data === "object") {
      return {
        title: typeof data.title === "string" && data.title ? data.title : fallback.title,
        body: typeof data.body === "string" ? data.body : fallback.body,
        url: typeof data.url === "string" && data.url ? data.url : fallback.url,
        tag: typeof data.tag === "string" && data.tag ? data.tag : fallback.tag,
        meeting_id: typeof data.meeting_id === "string" ? data.meeting_id : null,
      };
    }
  } catch (_) {
    try {
      const text = event.data.text();
      if (text) {
        return { ...fallback, body: text };
      }
    } catch (_) {
      // Fall back to defaults.
    }
  }
  return fallback;
}

self.addEventListener("push", (event) => {
  const payload = parsePushPayload(event);
  const work = self.registration
    .showNotification(payload.title, {
      body: payload.body,
      icon: "/static/icons/icon-192.png",
      badge: "/static/icons/icon-192.png",
      tag: payload.tag,
      renotify: true,
      data: {
        url: payload.url,
        meeting_id: payload.meeting_id,
      },
    })
    .then(() =>
      self.clients.matchAll({ type: "window", includeUncontrolled: true })
    )
    .then((clientList) => {
      for (const client of clientList) {
        if (client.url && client.url.startsWith(self.location.origin)) {
          client.postMessage({
            type: "noteit-push",
            meeting_id: payload.meeting_id,
            url: payload.url,
          });
        }
      }
    });

  event.waitUntil(work);
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const data = (event.notification && event.notification.data) || {};
  const targetPath = typeof data.url === "string" && data.url ? data.url : "/";
  const fullTargetUrl = new URL(targetPath, self.location.origin).href;
  const meetingId = typeof data.meeting_id === "string" ? data.meeting_id : null;

  event.waitUntil(
    self.clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((clientList) => {
        for (const client of clientList) {
          if (client.url && client.url.startsWith(self.location.origin)) {
            client.postMessage({
              type: "noteit-open-meeting",
              meeting_id: meetingId,
              url: targetPath,
            });
            if (typeof client.focus === "function") {
              return client.focus();
            }
            return client;
          }
        }
        if (typeof self.clients.openWindow === "function") {
          return self.clients.openWindow(fullTargetUrl);
        }
        return null;
      })
  );
});
