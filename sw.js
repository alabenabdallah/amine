/* AMINE — service worker de l'application installable (version publiée sur un site, avec --pwa).
 *
 * - Page de l'application : réseau d'abord (toujours la dernière version publiée), copie locale
 *   seulement quand le réseau manque, pour que l'application s'ouvre hors connexion.
 * - Icônes et manifeste : copie locale.
 * - Supabase, cartes, photos : jamais mis en cache ici (autres domaines, données personnelles).
 * - Clic sur une notification système : ouvre (ou ramène au premier plan) l'application sur la bonne page.
 */
const CACHE = 'amine-3.0.0-6571f834a661'
const SHELL = ['./', './manifest.webmanifest', './icon-192.png', './icon-512.png', './badge-96.png']

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => cache.addAll(SHELL))
      .then(() => self.skipWaiting()),
  )
})

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key.startsWith('amine-') && key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (event) => {
  const request = event.request
  if (request.method !== 'GET') return
  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response.ok) {
            const copy = response.clone()
            void caches.open(CACHE).then((cache) => cache.put('./', copy))
          }
          return response
        })
        .catch(() => caches.match('./').then((hit) => hit || Response.error())),
    )
    return
  }
  event.respondWith(caches.match(request).then((hit) => hit || fetch(request)))
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const link = (event.notification.data && event.notification.data.link) || '#/'
  const target = new URL(self.registration.scope)
  target.hash = link.startsWith('#') ? link.slice(1) : ''
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
      for (const client of windows) {
        if (client.url.startsWith(self.registration.scope) && 'focus' in client) {
          // L'application ouverte change elle-même de page (sans recharger).
          client.postMessage({ type: 'amine-open', link })
          return client.focus()
        }
      }
      return self.clients.openWindow(target.href)
    }),
  )
})
