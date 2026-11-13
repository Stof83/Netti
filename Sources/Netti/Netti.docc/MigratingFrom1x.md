# Migrating from 1.x

Move code written for Netti 1.x to the 2.0 API.

## Overview

Netti 2.0 breaks source compatibility on purpose: the public API is smaller, every error is typed, and the engine no longer uses Alamofire. This article summarizes the changes. The complete mapping, with before-and-after code for every breaking change, is in `MIGRATION.md` at the root of the repository.

To stay on 1.x until you are ready, keep the requirement at `.upToNextMajor(from: "1.5.0")`, which never resolves to 2.x.

### Checklist

1. Raise deployment targets to iOS 17, macOS 14, tvOS 17, watchOS 10 and Mac Catalyst 17, and build with a Swift 6.4 toolchain.
2. Move `jsonManager:` from the initializer to the ``Netti/jsonManager`` property.
3. Replace `send(_:parameters:method:)` with the verb methods.
4. Make endpoint types, and every query, body and response type, `Sendable`.
5. Update every `catch` of ``HTTPRequestError`` to the new cases.
6. Check `GET`, `HEAD` and `DELETE` queries that send dates, and query or body keys that start with an acronym.
7. Replace `AFConfiguration` and `AFNetworkService`, which no longer exist, with ``URLSessionNetworkService`` and a ``ServerTrustPolicy``.
8. Read ``NetworkMonitor/status`` on the main actor, or switch to ``NetworkMonitor/currentStatus``.
9. If you implement ``NetworkService`` yourself, rewrite it against the transport-only protocol, or use `NettiTesting` for test doubles.

### Configuration is set through properties

The initializer keeps `service:` and adds `deduplicatesRequests:` and `cacheSizeLimit:`. The 1.x `jsonManager:` argument is now a property, next to the new ``Netti/interceptors``, ``Netti/retryPolicy``, ``Netti/validation``, ``Netti/monitors``, ``Netti/isLoggingEnabled`` and ``Netti/connectivity``:

```swift
// 1.x
// let netti = Netti(jsonManager: JSONManager(keyStrategy: .useDefaultKeys))

let netti = Netti()
netti.jsonManager = JSONManager(keyStrategy: .useDefaultKeys)
```

Each request reads the configuration once, when it starts, so a change applies to the next request and never to one in flight.

### Requests use verb methods

```swift
// 1.x
// let response: HTTPResponse<User> = try await netti.send(UserAPI.user(42), method: .get)
// let created: HTTPResponse<User> = try await netti.send(UserAPI.users, parameters: NewUser(name: "Ada"), method: .post)

let response: HTTPResponse<User> = try await netti.get(UserAPI.user(42))
let created: HTTPResponse<User> = try await netti.post(UserAPI.users, body: NewUser(name: "Ada"))
```

Methods without a verb, such as `TRACE`, go through ``Netti/buildRequest(_:parameters:method:)`` and `send(_:)`. Always annotate the response type: without it, the overload that returns `HTTPResponse<Empty>` is chosen.

### `Netti` is final

``Netti`` is a `final class` and `Sendable`, so it can no longer be subclassed. Move logic from overrides to the matching extension point:

| 1.x override purpose | 2.0 |
|---|---|
| Add headers or tokens | A ``RequestAdapter`` or ``RequestInterceptor`` in ``Netti/interceptors`` |
| Refresh a token on `401` | ``AuthenticationInterceptor`` |
| Retry | ``RetryPolicy`` or a ``RequestRetrier`` |
| Log or measure | An ``EventMonitor`` in ``Netti/monitors`` |
| Reject statuses | ``ResponseValidation`` |

### Errors are typed

``HTTPRequestError`` has a dedicated case per failure and is thrown with typed throws. `requestFailed` now carries only a `URLError`. A decoding failure is ``HTTPRequestError/decodingFailed(_:response:)`` instead of being wrapped in `requestFailed`. `invalidResponse` and `statusCode(Int)` are gone. Non-2xx responses are still returned, not thrown, so code that reads `response.statusCode == 401` keeps working. See <doc:ValidationAndErrors>.

### Encoding changed

- Query parameters are encoded with ``URLEncodedFormEncoder``. Keys still follow the client's ``JSONManager`` key strategy, so `pageNumber` is sent as `page_number` by default, as in 1.x. Dates use `yyyy-MM-dd'T'HH:mm:ss.SSSZ`, the default ``JSONManager`` date format, as in 1.x. Netti 2.0 to 3.2 sent ISO 8601 instead; 3.3 restored the 1.x format. A custom `JSONManager` date format is not applied to queries; encode the query with ``URLEncodedFormParameterEncoder`` and a ``URLEncodedFormEncoder`` using `dateEncoding: .formatted(_:)`, then call `send(_:)`. A key that starts with an acronym converts differently, in queries and JSON bodies alike: `URLValue` was `u_rl_value` in 1.x and is now `url_value`, and `ID` was `i_d` and is now `id`. To keep the old spelling, declare `CodingKeys` on the type.
- JSON bodies are encoded straight to `Data`, so top-level arrays work and `Decimal` keeps its precision.
- Query items already in the URL are kept, and `+` is escaped.

### The engine and its configuration changed

- ``URLSessionNetworkService`` is the default engine. It takes a `URLSessionConfiguration` plus an optional trust policy, redirect handler, connection limit per host and response size cap. Without a redirect handler it uses ``RedirectHandler/secure``, which refuses `https` to `http` and keeps credentials and bodies on their origin; pass ``RedirectHandler/follow`` to follow every redirect unchanged, as 1.x did. Unlike Alamofire's default configuration, it does not add `Accept-Encoding`, `Accept-Language` and `User-Agent` headers; ``HTTPHeaders/default`` holds those values if your backend needs them.
- ``NetworkService`` is transport-only: `data`, `upload`, `download`, `bytes` and `webSocket` on a built `URLRequest`.
- `AFNetworkService` and `AFConfiguration` are removed, along with the Alamofire dependency. The 1.x parameter encoders are deprecated. Pinning moves to ``ServerTrustPolicy``; see <doc:CertificatePinning>.

### Caching and connectivity changed

- ``HTTPCachePolicy`` is a struct with `.none`, `.cache` and `.cache(maxAge:)`. `==` still works; a `switch` needs a `default` case, or read ``HTTPCachePolicy/isCaching``.
- The cache key now includes the query and body. Entries written by 1.x are never read, and `cachedResponse` and `clearCache(for:)` take the `parameters:` the request was sent with. See <doc:CachingAndOffline>.
- ``NetworkMonitor/Status`` gains `.unknown`, the state before the first path update. ``NetworkMonitor/status``, `isConnected` and `isDisconnected` are `@MainActor`.

### New defaults

- Concurrent identical `GET` and `HEAD` requests share one transfer. Pass `deduplicatesRequests: false` to opt out.
- ``NetworkLogger`` is on in DEBUG builds and off in release builds, and redacts credentials. Set ``Netti/isLoggingEnabled`` to change that.
- Retry and validation stay off unless you set ``Netti/retryPolicy`` or ``Netti/validation``.

### Security defaults

2.0 adds secure defaults that can change what an existing call does: TLS 1.2 or later, ``RedirectHandler/secure`` redirects, a 64 MB response cap, a 300 s total time for data and upload requests (streams, WebSockets and downloads exempt), header validation, a 60 s cap on `Retry-After`, wider redaction, and pins that anchor the chain when `performDefaultValidation` is `false`. Each one, with how to restore the old behaviour, is in the "Security defaults in 2.0" section of `MIGRATION.md`. See <doc:Security>.
