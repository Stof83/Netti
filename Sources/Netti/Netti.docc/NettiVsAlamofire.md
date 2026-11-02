# Netti vs Alamofire

Compare Netti with Alamofire 5: what maps one to one, what Netti adds, and what it does not do.

## Overview

Netti 2.0 covers Alamofire's request features with plain async methods on its own `URLSession` engine. Alamofire is still a package dependency, but only the deprecated ``AFNetworkService`` engine uses it. That engine exists so a shared contract test suite can prove both engines behave the same. Alamofire will be removed from the package in a later release; until then, adding Netti also fetches Alamofire.

### The same request in both

```swift
// Alamofire
let user = try await AF.request("https://api.example.com/v1/users/42")
    .validate()
    .serializingDecodable(User.self)
    .value
show(user)
```

```swift
let netti = Netti()
netti.validation = ResponseValidation()
let user: User? = try await netti.get(UserAPI.user(42)).data
show(user)
```

Netti has no request objects to chain. You describe each endpoint once as an ``HTTPRequest`` type, and every call is one `try await`. The trade-off: a one-off URL needs either an endpoint type or a `URLRequest` passed to `send(_:)`.

### Feature map

| Alamofire | Netti |
|---|---|
| `AF.request(...).serializingDecodable(T.self)` | `get`, `post`, `put`, `patch`, `delete`, `head`, `options` |
| `AFError`, untyped throws | ``HTTPRequestError``, typed throws |
| `.validate()` | ``ResponseValidation``, per client or per endpoint |
| `RequestInterceptor`, `RequestAdapter`, `RequestRetrier` | ``RequestInterceptor``, ``RequestAdapter``, ``RequestRetrier`` |
| `AuthenticationInterceptor` with an `Authenticator` | ``AuthenticationInterceptor``, `init(bearerToken:refresh:)` for the common case |
| `RetryPolicy` | ``RetryPolicy``, with full jitter and `Retry-After` |
| `ServerTrustManager` and its evaluators | ``ServerTrustPolicy`` with ``ServerTrustEvaluator``; public-key pins are SPKI SHA-256 strings rather than bundled certificates |
| `AF.upload`, `MultipartFormData` | `upload(_:data:)`, `upload(_:fileURL:)`, `upload(_:multipart:)`, ``MultipartFormData`` |
| `AF.download`, `download(resumingWith:)` | ``Netti/download(_:to:options:resumeData:progress:)``; resume data travels on the thrown error |
| `DataStreamRequest` | ``Netti/stream(_:query:)`` with bytes, lines and Server-Sent Events |
| `WebSocketRequest`, behind `@_spi(WebSocket)` | ``WebSocketConnection``, public, with JSON messages and keep-alive pings |
| `EventMonitor`, `cURLDescription()` | ``EventMonitor``; ``NetworkLogger`` logs cURL with credentials redacted |
| `Redirector` | ``RedirectHandler`` |
| `NetworkReachabilityManager` | ``NetworkMonitor``, `@Observable` |
| `URLEncodedFormEncoder`, `JSONParameterEncoder` | ``URLEncodedFormEncoder``, ``JSONParameterEncoder`` |

### What Netti adds

- **An offline response cache.** Endpoints opt in with ``HTTPCachePolicy``; responses are kept on disk with a max age and an LRU size cap, served while offline, and readable cache-first. See <doc:CachingAndOffline>.
- **Batches and queues.** ``Netti/concurrent(_:maxConcurrency:_:)``, ``Netti/concurrentSettled(_:maxConcurrency:_:)``, ``Netti/sequential(_:_:)`` and ``RequestQueue`` with priorities and an offline hold. See <doc:MultipleRequestsAndQueues>.
- **In-flight deduplication** of identical `GET` and `HEAD` requests, on by default.
- **Bearer-token refresh in one line.** ``AuthenticationInterceptor`` takes a token and a refresh closure, with no `Authenticator` type to write. Concurrent `401`s still trigger a single refresh.
- **A backup-pin warning**, and `*.domain` wildcard hosts in the trust policy.
- **Test support.** The `NettiTesting` product ships a per-test stub server with request recording. See <doc:Testing>.

### What Netti does not do

- **No Combine publishers.** Netti is async/await only.
- **No `URLCache`-based response handler.** Netti's own cache is an offline fallback, not an HTTP cache. HTTP caching driven by `Cache-Control` is left to the session's `URLCache`.
- **No request objects.** You cannot suspend or resume a request, or read its cURL description on demand. Cancel with Swift task cancellation, and read cURL from the logger.
- **No custom response serializers.** Responses decode as JSON with ``JSONManager``. For anything else, read ``HTTPResponse/rawData``.
- **Fixed encoding in the verbs.** Queries use the default ``URLEncodedFormEncoder`` strategies, with keys converted by the client's ``JSONManager`` key strategy, and bodies are always JSON. For other encodings, build the request and call `send(_:)`; see <doc:MakingRequests>.
- **Progress only on uploads and downloads**, not on plain data requests.
- **Higher deployment targets.** Netti requires iOS 17, macOS 14, tvOS 17, watchOS 10 and Mac Catalyst 17, and supports Apple platforms only.

### Migrating from Alamofire

Map each Alamofire call to an endpoint plus a verb, move `Session` configuration to properties of ``Netti``, and move `ServerTrustManager` evaluators to a ``ServerTrustPolicy`` on ``URLSessionNetworkService``. A full concept mapping is in the "Alamofire to Netti" section of `MIGRATION.md` at the root of the repository.

```swift
// Alamofire
let interceptor = Interceptor(retriers: [RetryPolicy()])
let session = Session(
    interceptor: interceptor,
    serverTrustManager: ServerTrustManager(evaluators: ["api.example.com": PublicKeysTrustEvaluator()])
)
let users = try await session.request("https://api.example.com/v1/users")
    .serializingDecodable([User].self)
    .value
show(users)
```

```swift
let pinning = ServerTrustPolicy(["api.example.com": .publicKeys(["PRIMARY_SPKI_SHA256=", "BACKUP_SPKI_SHA256="])])
let netti = Netti(service: URLSessionNetworkService(trustPolicy: pinning))
netti.retryPolicy = RetryPolicy()
let users: [User]? = try await netti.get(UserAPI.users).data
show(users)
```
