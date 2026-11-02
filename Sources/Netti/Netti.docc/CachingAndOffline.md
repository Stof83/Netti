# Caching & Offline

Keep the last good response of an endpoint on disk, serve it while the device is offline, and read it first for an instant UI.

## Overview

Caching is opt-in per endpoint, through ``HTTPRequest/cachePolicy``:

```swift
enum RideHistoryAPI: HTTPRequest {
    case page(Int)

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String {
        switch self {
            case .page(let number): "rides/\(number)"
        }
    }
    var headers: HTTPHeaders { [.accept("application/json")] }
    var cachePolicy: HTTPCachePolicy { .cache(maxAge: .seconds(24 * 60 * 60)) }
}
```

| Policy | Behavior |
|---|---|
| ``HTTPCachePolicy/none`` | The default. Nothing is cached. |
| ``HTTPCachePolicy/cache`` | `2xx` responses are cached with no expiry. |
| ``HTTPCachePolicy/cache(maxAge:)`` | `2xx` responses are cached and served for at most `maxAge` after they were written. |

### How the cache is used

For an endpoint that caches, the verbs work as follows:

- Every `2xx` response is written to disk before the call returns, so an immediate read finds it.
- While the device is **offline**, the verb returns the cached response, if there is a valid one, without touching the network. The response has a synthesized `200` status.
- While the device is online, or its state is still unknown, the request always goes to the network. The cache is a fallback, not a way to skip requests.

The client's ``Netti/connectivity`` decides what offline means. It defaults to ``NetworkMonitor/shared``, which starts as ``NetworkMonitor/Status/unknown``, so a cold start never serves stale data by mistake.

Only the verbs (`get`, `post` and the others) read and write the cache. `send(_:)`, uploads, downloads and streams never do.

### Show cached data first

``Netti/cachedResponse(for:method:parameters:)`` reads the cache whatever the connectivity, with no network access. Show it at once, then refresh:

```swift
if let cached: HTTPResponse<[Ride]> = await netti.cachedResponse(for: RideAPI.history) {
    show(cached.data)
}
let fresh: [Ride]? = try await netti.get(RideAPI.history).data
show(fresh)
```

The result is `nil` when the endpoint does not cache, when there is no valid entry, or when the entry no longer decodes as the requested type.

### Pass the same parameters

An entry's key is the SHA-256 of the method, the URL with its query items sorted, and a hash of the body. Different parameters are different entries, so `?page=1` and `?page=2` never collide. To read or remove an entry, pass the method and parameters the request was sent with. The method defaults to `GET`:

```swift
let secondPage: HTTPResponse<[Ride]>? = await netti.cachedResponse(for: RideAPI.history, parameters: Page(number: 2))
```

### Invalidate entries

Remove one entry after a mutation makes it stale, or every entry on logout:

```swift
try await netti.post(UserAPI.users, body: NewUser(name: "Ada"))
try await netti.clearCache(for: UserAPI.users)

try await netti.clearCache()
```

### Storage

Entries live in the app's Caches directory and survive relaunches. The system may purge them under storage pressure. The cache keeps at most 50 MB by default and evicts the least recently used entries first. Change the cap per client:

```swift
let netti = Netti(cacheSizeLimit: 10 * 1024 * 1024)
```

This cache is independent of `URLCache`. HTTP caching driven by `Cache-Control` headers is whatever the engine's `URLSessionConfiguration` does.

### React to connectivity

``NetworkMonitor`` watches the network path with `NWPathMonitor`. Its ``NetworkMonitor/status`` is `@Observable` and changes on the main actor, so SwiftUI views can read it directly:

```swift
struct OfflineBanner: View {
    var body: some View {
        if NetworkMonitor.shared.isDisconnected {
            Text("You're offline. Showing saved rides.")
        }
    }
}
```

Off the main actor, read ``NetworkMonitor/currentStatus``, or iterate ``NetworkMonitor/statusUpdates()``:

```swift
for await status in NetworkMonitor.shared.statusUpdates() {
    if status == .connected {
        break
    }
}
```

### Send writes made offline later

To hold writes while the device is offline and send them on reconnect, enqueue them on a ``RequestQueue`` that waits for connectivity:

```swift
let outbox = netti.queue(.serial(waitsForConnectivity: true))
try await outbox.enqueue { try await netti.post(TripAPI.log, body: entry) }
```

The queue lives in memory. Work still pending when the app terminates is lost, so persist anything that must survive a relaunch. See <doc:MultipleRequestsAndQueues>.
