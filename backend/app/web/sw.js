"use strict";

const CACHE_NAME = "noteit-shell-v1";
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
