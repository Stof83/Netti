# Migrating to Netti 3.0

Netti 2.0 and 3.0 break source compatibility on purpose. This guide covers three paths:

- [Netti 2.x to 3.0](#netti-2x-to-30): the Alamofire engine and the Alamofire dependency are removed
- [Netti 1.x to 2.0](#netti-1x-to-20): a one-to-one API mapping, then every breaking change with before and after code
- [Alamofire to Netti](#alamofire-to-netti): concept mapping for code that calls Alamofire directly

To stay on 1.x until you're ready, keep the requirement at `.upToNextMajor(from: "1.5.0")`, which never resolves to 2.x.

## Netti 2.x to 3.0

3.0 removes `AFNetworkService`, `AFConfiguration` and the Alamofire package dependency, all deprecated since 2.0. Nothing else changes. Netti now has no third-party dependencies, so adding it no longer fetches Alamofire.

If your code doesn't name `AFNetworkService` or `AFConfiguration`, just raise the requirement to `from: "3.0.0"`. Otherwise move to the native engine and a `ServerTrustPolicy`:

```swift
// 2.x
let manager = ServerTrustManager(evaluators: ["api.example.com": PublicKeysTrustEvaluator()])
let netti = Netti(service: AFNetworkService(configuration: AFConfiguration(serverTrustManager: manager)))

// 3.0
let pins = ServerTrustPolicy(["api.example.com": .publicKeys(["<primary SPKI SHA-256>", "<backup SPKI SHA-256>"])])
let netti = Netti(service: URLSessionNetworkService(trustPolicy: pins))
```

If your project imports Alamofire itself, add it to your own `Package.swift`; Netti no longer brings it in.

## Netti 1.x to 2.0

### Checklist

1. Raise deployment targets to iOS 17, macOS 14, tvOS 17, watchOS 10 and Mac Catalyst 17, and build with a Swift 6.4 toolchain.
2. Move `Netti(jsonManager:)` to `netti.jsonManager = ...` (see [Configuration moves to properties](#configuration-moves-to-properties)).
3. Replace `send(_:parameters:method:)` with the verb methods.
4. Make endpoint types, and every request and response type, `Sendable`.
5. Update every `catch` of `HTTPRequestError` to the new cases.
6. Check `GET`/`HEAD`/`DELETE` queries that send dates, and query or body keys starting with an acronym (see [Query keys follow `JSONManager`; dates are ISO 8601](#query-keys-follow-jsonmanager-dates-are-iso-8601)).
7. Replace `AFConfiguration` and `AFNetworkService` with `URLSessionNetworkService` and a `ServerTrustPolicy`.
8. Read `NetworkMonitor.status` on the main actor, or switch to `currentStatus`.
9. If you implement `NetworkService` yourself, rewrite it against the transport-only protocol, or use `NettiTesting` for test doubles.
10. Review the [security defaults](#security-defaults-in-20): redirects, response size, request time, logging, header validation and `Retry-After` can change what an existing call does.
11. Call `try await netti.clearCache()` on logout.

### API mapping

| 1.x | 2.0 |
|---|---|
| `Netti(service:jsonManager:)`, defaulting to `AFNetworkService()` | `Netti(service:deduplicatesRequests:cacheSizeLimit:)`, defaulting to `URLSessionNetworkService()`; every argument is optional |
| `Netti(jsonManager: manager)` | `netti.jsonManager = manager` |
| `open class Netti: @unchecked Sendable` | `public final class Netti: Sendable` |
| `send(endpoint, parameters: p, method: .get)` | `get(endpoint, query: p)` |
| `send(endpoint, parameters: p, method: .head)` | `head(endpoint, query: p)` (returns `HTTPResponse<Empty>`) |
| `send(endpoint, parameters: p, method: .delete)` | `delete(endpoint, query: p)` |
| `send(endpoint, method: .options)` | `options(endpoint)` |
| `send(endpoint, parameters: p, method: .post / .put / .patch)` | `post / put / patch(endpoint, body: p)` |
| `send(endpoint, method: .trace / .connect)` | `send(try netti.buildRequest(endpoint, method: .trace))` |
| `send<Response: Decodable>(_ urlRequest:)` | `send<Response: Decodable & Sendable>(_ urlRequest:)`, plus an `HTTPResponse<Empty>` overload |
| `buildRequest(_:parameters:method:) throws` | `buildRequest(_:parameters:method:) throws(HTTPRequestError)`; same argument order |
| `decode(_:request:) async throws(HTTPRequestError)` | `decode(_:request:) throws(HTTPRequestError)` (no longer `async`) |
| `cachedResponse(for:method:)` | `cachedResponse(for:method:parameters:)`; `method` defaults to `.get` |
| `clearCache(for:method:) async throws` | `clearCache(for:method:parameters:) async throws(HTTPRequestError)`; `method` defaults to `.get` |
| `clearCache() async throws` | `clearCache() async throws(HTTPRequestError)` |
| `HTTPRequest` | `HTTPRequest: Sendable`, with optional `validation` and `retryPolicy` requirements |
| `HTTPRequest.requestURL` (`fatalError` on a `nil` base URL) | `requestURL` `get throws(HTTPRequestError)`, throws `.invalidURL` |
| `HTTPRequest.asURLRequest(for:) throws` | `asURLRequest(for:) throws(HTTPRequestError)` |
| `enum HTTPCachePolicy { case none, cache }` | `struct HTTPCachePolicy`: `.none`, `.cache`, `.cache(maxAge:)` |
| `HTTPRequestError.requestFailed(Error)` | `.requestFailed(URLError)`, plus dedicated cases for everything else |
| `HTTPRequestError.decodingFailed(Error)` | `.decodingFailed(any Error, response: HTTPResponse<Data>?)` |
| `HTTPRequestError.invalidResponse` | Removed |
| `HTTPRequestError.statusCode(Int)` | Removed; use `ResponseValidation` and `.unacceptableStatusCode(_:response:)` |
| `protocol NetworkService: AnyObject` with `send` and `createURLRequest` | `protocol NetworkService: Sendable` with `data`, `upload`, `download`, `bytes`, `webSocket` |
| `URLSessionNetworkService(configuration: URLSessionConfigurationWrapper)` | `URLSessionNetworkService(configuration: URLSessionConfiguration, trustPolicy:redirectHandler:maxConnectionsPerHost:maximumResponseSize:)` |
| `AFNetworkService(configuration: AFConfiguration)` | Removed in 3.0. Use `URLSessionNetworkService(trustPolicy:)` |
| `AFConfiguration(serverTrustManager:)` | Removed in 3.0. Use `ServerTrustPolicy` |
| `ParameterEncoder`, `URLSessionConfigurationWrapper`, `JSONBodyParameterEncoder`, `URLQueryParameterEncoder` | Deprecated and unused. Netti encodes with `URLEncodedFormParameterEncoder` and `JSONParameterEncoder` |
| `NetworkMonitor.Status { connected, disconnected }` | `Status { unknown, connected, disconnected }` |
| `NetworkMonitor.status`, `isConnected`, `isDisconnected` (any thread) | `@MainActor`; use `currentStatus` off the main actor |
| `class NetworkMonitor`, `class JSONManager` | `final class`, `Sendable` |
| `Encodable.toDictionary(dateFormat:keyEncodingStrategy:)` | Internal |
| `Sequence.asyncMap`, `Sequence.asyncForEach` | Internal; use `netti.sequential` or a `for` loop |
| `HTTPRequestQueue`, `PendingRequest` (internal prototypes) | `RequestQueue` via `netti.queue(...)` |

### Breaking changes

#### Platforms and toolchain

1.x declared macOS 11, watchOS 7 and Mac Catalyst 14, but its `@Observable` `NetworkMonitor` needs macOS 14, watchOS 10 and Catalyst 17, so 1.5.0 didn't build on macOS. 2.0 declares iOS 17, macOS 14, tvOS 17, watchOS 10 and Mac Catalyst 17, with swift-tools-version 6.4.

#### `send(_:parameters:method:)` is replaced by verb methods

```swift
// 1.x
let response: HTTPResponse<User> = try await netti.send(UserAPI.user(42), method: .get)
let created: HTTPResponse<User> = try await netti.send(UserAPI.users, parameters: NewUser(name: "Ada"), method: .post)

// 2.0
let response: HTTPResponse<User> = try await netti.get(UserAPI.user(42))
let created: HTTPResponse<User> = try await netti.post(UserAPI.users, body: NewUser(name: "Ada"))
```

Each verb also has an overload that returns `HTTPResponse<Empty>`. When you call a verb without annotating the response type, that overload wins. This means `let users = try await netti.get(UserAPI.users).data` gives you `Empty?`, not `[User]?`. Always annotate the type you expect.

Uploads take an `UploadMethod` (`.post`, `.put` or `.patch`), not an `HTTPMethod`. Downloads always use `GET`.

#### Configuration moves to properties

The initializer keeps `service:` and adds `deduplicatesRequests:` and `cacheSizeLimit:`. Everything else is a property you set after creating the client, at any time and from any thread. Each request reads the configuration once, when it starts, so a change applies to the next request and never to one in flight.

```swift
// 1.x
let netti = Netti(service: URLSessionNetworkService(), jsonManager: JSONManager(keyStrategy: .useDefaultKeys))

// 2.0
let netti = Netti()
netti.jsonManager = JSONManager(keyStrategy: .useDefaultKeys)
```

| 1.x | 2.0 | Default |
|---|---|---|
| `Netti(service:)` | `Netti(service:)` | `URLSessionNetworkService()` (1.x: `AFNetworkService()`) |
| `Netti(jsonManager:)` | `netti.jsonManager` | `JSONManager()`, snake_case keys |
| None | `netti.interceptors` | `[]` |
| None | `netti.retryPolicy` | `nil`, never retries |
| None | `netti.validation` | `nil`, returns every response |
| None | `netti.monitors` | `[]` |
| None | `netti.isLoggingEnabled` | `true` in DEBUG builds, `false` in release builds |
| None | `netti.connectivity` | `NetworkMonitor.shared` |
| None | `Netti(deduplicatesRequests:)` | `true` |
| None | `Netti(cacheSizeLimit:)` | 50 MB |

#### `Netti` is a `final` `Sendable` class

You can no longer subclass `Netti` or override `send`, `buildRequest` or `cachedResponse`. Move logic you used to put in an override to the matching extension point:

| 1.x override purpose | 2.0 |
|---|---|
| Add headers or tokens | A `RequestAdapter` / `RequestInterceptor` in `netti.interceptors` |
| Refresh a token on `401` | `AuthenticationInterceptor` |
| Retry | `RetryPolicy` or a `RequestRetrier` |
| Log or measure | An `EventMonitor` in `netti.monitors` |
| Reject statuses | `ResponseValidation` |

#### The default engine is `URLSessionNetworkService`

`Netti()` now runs on the native engine, not on Alamofire. Behaviour is covered by one contract test suite. One visible difference: `URLSessionNetworkService` uses `URLSessionConfiguration.default`, so `Accept-Encoding`, `Accept-Language` and `User-Agent` carry `URLSession`'s own values, not the ones Alamofire's default configuration sets. Alamofire's `User-Agent`, for example, names the app and the Alamofire version. If your backend depends on those values, add `HTTPHeaders.default`, which holds Netti's equivalents, to your endpoints' `headers`.

#### Request and response types must be `Sendable`

`HTTPRequest` refines `Sendable`. Every generic response type is `Decodable & Sendable`, and every query or body is `Encodable & Sendable`.

```swift
// 1.x
struct User: Decodable { let id: Int }

// 2.0
struct User: Decodable, Sendable { let id: Int }
```

#### Query keys follow `JSONManager`; dates are ISO 8601

In 1.x, every parameter object went through `JSONManager`'s encoder into a dictionary, so query keys and dates were written like JSON bodies. In 2.0, `get`, `head`, `delete` and `buildRequest` encode queries with `URLEncodedFormEncoder`. Keys still follow the client's `JSONManager` key strategy, so with the default `JSONManager()`, `pageNumber` is sent as `page_number`, as in 1.x. Dates are now ISO 8601 instead of `JSONManager`'s date format. JSON bodies still use `JSONManager` for both.

| Encodable `Filter(pageNumber: 2, createdAfter: date)` | 1.x | 2.0 |
|---|---|---|
| `GET` query | `page_number=2&created_after=<JSONManager date format>` | `created_after=<ISO 8601>&page_number=2` |
| `POST` body | `{"page_number":2,"created_after":...}` | unchanged |

With snake_case, a key that starts with an acronym, or has `_` before an uppercase letter, is spelled differently from 1.x, in queries and bodies alike. 1.x used `JSONEncoder`'s `.convertToSnakeCase`, which splits leading acronyms; 2.0's `JSONManager` keeps them together, and query keys use the same conversion, so a key is always spelled the same in the query and the body:

| Property | 1.x query and body | 2.0 query and body |
|---|---|---|
| `URLValue` | `u_rl_value` | `url_value` |
| `ID` | `i_d` | `id` |
| `my_Value` | `my__value` | `my_value` |

Ordinary camelCase keys, such as `pageNumber`, `userID` or `myURLValue`, convert as in 1.x. A `JSONManager(encoder:decoder:)` built with `JSONEncoder`'s own `.convertToSnakeCase` keeps `u_rl_value` in bodies, while its query keys use the 2.0 conversion. A `.custom` key strategy is applied to each key component on its own: the closure receives a coding path with that single key. To pin a spelling, declare it on the type:

```swift
struct Filter: Encodable, Sendable {
    let URLValue: String
    enum CodingKeys: String, CodingKey { case URLValue = "u_rl_value" }
}
```

Arrays are still encoded without brackets (`id=1&id=2`), and bools as `true`/`false`, as with 1.x's Alamofire `URLEncoding(arrayEncoding: .noBrackets, boolEncoding: .literal)`. Keys are sorted, `+` is escaped, and query items already in the URL are kept. The 1.x `URLSessionNetworkService` replaced them and wrote arrays as `"[1, 2]"`.

#### JSON bodies are encoded directly

1.x converted a body to a `[String: Any]` dictionary first. That silently dropped top-level arrays, lost `Decimal` precision and reordered keys. 2.0 encodes the `Encodable` value straight to `Data`, so `post(endpoint, body: [item1, item2])` now sends an array.

#### `HTTPRequestError` is redesigned

```swift
public enum HTTPRequestError: Error, Sendable {
    case invalidURL
    case encodingFailed(any Error)
    case requestFailed(URLError)
    case serverTrustEvaluationFailed(host: String, reason: String)
    case unacceptableStatusCode(Int, response: HTTPResponse<Data>)
    case unacceptableContentType(String?, response: HTTPResponse<Data>)
    case validationFailed(any Error, response: HTTPResponse<Data>)
    case decodingFailed(any Error, response: HTTPResponse<Data>?)
    case cancelled
    indirect case retryLimitExceeded(attempts: Int, lastError: HTTPRequestError)
    case fileSystem(any Error)
    indirect case downloadFailed(HTTPRequestError, resumeData: Data)
}
```

- `invalidResponse` and `statusCode(Int)` are removed. 1.x never threw them.
- `requestFailed` now carries only a `URLError`. A cancellation is `.cancelled`, a pinning failure is `.serverTrustEvaluationFailed`, and a file problem is `.fileSystem`.
- 1.x wrapped every failure, decoding errors included, in `.requestFailed`. 2.0 throws `.decodingFailed` for a 2xx body that doesn't decode, so a `catch .requestFailed` no longer sees decoding errors.
- The new `error.response` returns the raw response, when there is one, and `error.resumeData` returns download resume data.

```swift
// 1.x
do {
    let response: HTTPResponse<User> = try await netti.send(UserAPI.user(42), method: .get)
} catch HTTPRequestError.requestFailed(let error) {
    showOffline(error)
}

// 2.0
do {
    let user: User? = try await netti.get(UserAPI.user(42)).data
} catch .requestFailed(let urlError) {
    showOffline(urlError)
} catch .decodingFailed(let error, _) {
    report(error)
}
```

Non-2xx responses are still returned, not thrown, so code that reads `response.statusCode == 401` keeps working. Their `data` is `nil` when the body doesn't decode as the requested type. To throw on a bad status instead, set `netti.validation = ResponseValidation()`.

#### `HTTPRequest.requestURL` throws

A `nil` `baseURL` used to call `fatalError`. Now `requestURL` and `asURLRequest(for:)` throw `HTTPRequestError.invalidURL`, using typed throws. If you call them directly, add `try`. If you implement `requestURL` yourself, the signature changes:

```swift
// 1.x
var requestURL: URL { Self.exportURL }

// 2.0
var requestURL: URL {
    get throws(HTTPRequestError) { Self.exportURL }
}
```

#### `NetworkService` is transport-only

Engines now receive a fully built `URLRequest`, because Netti does the encoding itself. The protocol is `Sendable`, no longer `AnyObject`, and has five requirements: `data(for:)`, `upload(for:from:progress:)`, `download(for:resumeData:progress:)`, `bytes(for:)` and `webSocket(for:)`. `send(_:parameters:method:)`, `send(_:)` and `createURLRequest(_:parameters:method:)` are gone.

- If you call `service.createURLRequest(...)`, use `netti.buildRequest(endpoint, parameters: p, method: .get)` instead.
- If you wrote a mock engine, use `NettiTesting` instead: `StubServer` for HTTP-level stubs, or `StubNetworkService` for closure-based handlers.

```swift
// 2.0 test
let server = StubServer()
server.stub(.get, "https://api.example.com/v1/users/42", json: User(id: 42, name: "Ada"))
let user: User? = try await server.netti().get(UserAPI.user(42)).data
```

#### `URLSessionNetworkService` takes a `URLSessionConfiguration`

```swift
// 1.x
let service = URLSessionNetworkService(configuration: URLSessionConfigurationWrapper())

// 2.0
let service = URLSessionNetworkService(configuration: .default, trustPolicy: pins, maxConnectionsPerHost: 4)
```

Every argument is optional. The 1.x engine had no trust handling and no redirect control. 2.0 adds both, plus a response size cap, and applies the [security defaults](#security-defaults-in-20) to the configuration you pass.

#### Alamofire engine and configuration are removed

`AFNetworkService` and `AFConfiguration` were deprecated in 2.0 and are removed in 3.0. Only `AFConfiguration.serverTrustManager` was still read in 2.x; `cacheResponse`, `urlEncoding` and `jsonEncoding` were ignored. Move to the native engine and a `ServerTrustPolicy`:

```swift
// 1.x
let manager = ServerTrustManager(evaluators: ["api.example.com": PublicKeysTrustEvaluator()])
let netti = Netti(service: AFNetworkService(configuration: AFConfiguration(serverTrustManager: manager)))

// 2.0
let pins = ServerTrustPolicy(["api.example.com": .publicKeys(["<primary SPKI SHA-256>", "<backup SPKI SHA-256>"])])
let netti = Netti(service: URLSessionNetworkService(trustPolicy: pins))
```

`ParameterEncoder`, `URLSessionConfigurationWrapper`, `JSONBodyParameterEncoder` and `URLQueryParameterEncoder` are deprecated. No engine uses them anymore.

#### Caching: `HTTPCachePolicy` is a struct, and the key changed

`HTTPCachePolicy` is now a struct with `.none`, `.cache` and `.cache(maxAge: Duration)`. Comparisons with `==` still work. A `switch` still matches `.none` and `.cache`, but it now needs a `default` case:

```swift
// 1.x
switch endpoint.cachePolicy {
    case .none: break
    case .cache: prefetch()
}

// 2.0
if endpoint.cachePolicy.isCaching { prefetch() }
```

The cache key is now SHA-256 of the method, the URL with its query sorted, and a hash of the body. The 1.x key ignored parameters, so `?page=1` and `?page=2` shared one entry. As a result:

- Entries written by 1.x are never read by 2.0. They stay in `Caches/http_cache` until the 50 MB LRU cap evicts them or you call `clearCache()`.
- `cachedResponse` and `clearCache(for:)` take the `parameters:` the request was sent with:

```swift
// 1.x
let cached: HTTPResponse<[Ride]>? = await netti.cachedResponse(for: RideAPI.history, method: .get)

// 2.0
let cached: HTTPResponse<[Ride]>? = await netti.cachedResponse(for: RideAPI.history, parameters: Page(number: 1))
```

The cache write is now awaited before the request returns, so an immediate `cachedResponse` read finds it.

#### `NetworkMonitor` status is `@MainActor`, and starts as `.unknown`

- `Status` gains `.unknown`, the value before the system reports a path. A 1.x cold start reported `.disconnected` and could serve offline cache. Exhaustive `switch`es need the new case.
- `status`, `isConnected` and `isDisconnected` are `@MainActor`, because they drive SwiftUI. Off the main actor, read `currentStatus`.
- `NetworkMonitor` is `final`. To simulate connectivity in tests, set `netti.connectivity` to a `StubConnectivity`, or pass one to `StubServer.netti(connectivity:)`.

```swift
// 1.x, from any thread
if NetworkMonitor.shared.isDisconnected { useCache() }

// 2.0, off the main actor
if NetworkMonitor.shared.currentStatus == .disconnected { useCache() }
```

#### `JSONManager` is `final` and `Sendable`

You can't subclass it anymore. To customise it, pass your own coders with `JSONManager(encoder:decoder:)` and set the result on `netti.jsonManager`. Decoding a type that conforms to `EmptyResponse`, such as `Empty`, now returns its empty value whatever the body.

#### Public helpers made internal or removed

- `Encodable.toDictionary(dateFormat:keyEncodingStrategy:)`, `Sequence.asyncMap` and `Sequence.asyncForEach` are internal. They leaked into every importer's namespace. Copy them into your module if you depend on them.
- The commented-out `Sequence.concurrentForEach` is deleted. Use `netti.concurrent`.
- The internal `HTTPRequestQueue` and `PendingRequest` prototypes are replaced by `RequestQueue`.
- `JSONEncoder.toDictionary(_:)` is still public. Netti no longer uses it.

#### New defaults to be aware of

- Concurrent identical `GET` and `HEAD` requests (same method, URL, body and headers) share one transfer. To turn that off, create the client with `Netti(deduplicatesRequests: false)`.
- `NetworkLogger` is a public `EventMonitor`. It's on in DEBUG builds, off in release builds, and redacts credentials. Change it with `netti.isLoggingEnabled`.
- Every protection in [Security defaults in 2.0](#security-defaults-in-20) is on.
- Retry and validation stay off unless you set `netti.retryPolicy` or `netti.validation`.

### Security defaults in 2.0

2.0 turns on protections that 1.x didn't have. Most calls are unaffected, but each one below can change what an existing call does. Restore the old behaviour only for a reason you can name, and only for the client that needs it. [SECURITY.md](SECURITY.md) explains each default.

#### TLS 1.2 or later

Both engines negotiate TLS 1.2 or later; a configuration that already requires TLS 1.3 keeps it. ATS already required TLS 1.2 for app traffic, so only servers reached through an ATS exception, or from a process without ATS, are affected. There is no opt-out: upgrade the server.

#### Redirects no longer leak credentials or downgrade

Without a handler, `URLSessionNetworkService` now uses `RedirectHandler.secure`:

- an `https` → `http` redirect throws `.requestFailed` with `URLError.appTransportSecurityRequiresSecureConnection`;
- a redirect to another scheme, host or port is followed without `Authorization`, `Proxy-Authorization` and `Cookie`;
- a cross-origin 307 or 308 for a request with a body isn't followed: the 3xx response is returned.

To follow every redirect unchanged, as 1.x did:

```swift
let netti = Netti(service: URLSessionNetworkService(redirectHandler: .follow))
```

#### Responses over 64 MB fail

A data or upload response body over 64 MB throws `.requestFailed` with `URLError.dataLengthExceedsMaximum`. Downloads and streams aren't limited. For a larger JSON response, raise the cap or remove it:

```swift
let netti = Netti(service: URLSessionNetworkService(maximumResponseSize: nil))
```

#### Data and upload requests end after 300 seconds

A data or upload request that takes longer than `maximumRequestDuration`, 300 s by default and response included, throws `.requestFailed` with `URLError.timedOut`. It is a total time: `timeoutInterval` is an idle timeout, which a server sending one byte at a time keeps resetting. Byte and Server-Sent Events streams, WebSockets and downloads have no deadline, so a live feed stays open. For a large upload on a slow network, raise the limit or remove it:

```swift
let netti = Netti(service: URLSessionNetworkService(maximumRequestDuration: .seconds(3_600)))
```

The configuration's `timeoutIntervalForResource` is kept as given. A value you set there applies to every task, streams and WebSockets included.

#### Streams are bounded

`lines` throws on a line over 1 MB, `serverSentEvents` throws on an event with more than 1 MB of data and ignores a `retry:` above 1 hour, and a stream or WebSocket fails when its consumer falls 8 MB (or 1,000 WebSocket messages) behind. All failures throw `.requestFailed` with `URLError.dataLengthExceedsMaximum`. To allow longer lines or events, wrap the body with `AsyncLineSequence(response.body, maximumLineLength:)` or `ServerSentEventSequence(AsyncLineSequence(response.body), maximumDataLength:)`. The buffer limits have no opt-out: read the stream as fast as it arrives.

#### Logging is off in release builds

`NetworkLogger` runs in DEBUG builds only. 1.x logged in every build. To log in a release build:

```swift
netti.isLoggingEnabled = true
```

#### Wider redaction

1.x logged every header and body as is. 2.0 redacts any header, query item, JSON key or form field whose name contains `auth`, `token`, `key`, `secret`, `session`, `cookie`, `password`, `passwd`, `pwd`, `signature`, `credential` or `otp`, whose words include `sig` or `pin`, or that is exactly `code`. It also redacts the whole body of a request that carries a credential header. See [Redaction rules](SECURITY.md#redaction-rules).

The rules over-redact on purpose. A JSON `"code"` field, such as an error code in a response, is hidden, and so is any name that merely contains a fragment: `otp` in `footprint`, `auth` in `author`, `key` in `Idempotency-Key`. There is no opt-out. To see such values while debugging, read them from the response in code, or add your own `EventMonitor`, which receives unredacted requests and responses.

#### Invalid headers throw

A header name that isn't an RFC 9110 token (empty, or with a space, a colon or a non-ASCII character), or a value with a control character other than tab (CR, LF, NUL), now throws `.encodingFailed` and nothing is sent. 1.x passed such headers to `URLRequest`, which silently dropped a value with CR or LF and sent a NUL. There is no opt-out: strip or percent-encode the value before you set it.

The check runs on endpoint headers and again after interceptors adapt the request. One gap remains: a value with CR or LF set by an interceptor is dropped by `URLRequest` before Netti sees it, so that request is sent without the header instead of failing.

#### Multipart names are still escaped, not rejected

`"`, CR and LF in a part's name or file name are percent-escaped (`%22`, `%0D`, `%0A`), as before, so existing forms keep encoding. The escaping now works on Unicode scalars, so a combining mark after one of those characters no longer hides it. These are new and throw `.encodingFailed`: NUL in a name or file name, a control character in a part's MIME type, and a custom boundary that breaks RFC 2046 (1–70 allowed characters, not ending in a space).

#### `Retry-After` is capped at 60 seconds

`RetryPolicy` reads `Retry-After` only as 1 to 10 digits or an HTTP-date, and ignores any other value. When the server asks for more than 60 s, the request is not retried and its response is returned. To honour longer waits:

```swift
netti.retryPolicy = RetryPolicy(maximumRetryAfter: .seconds(300))
```

#### Pinning without default validation checks the chain

With `performDefaultValidation: false`, the pins now become the only trust anchors and the chain is still evaluated with the SSL policy for the host: signatures, validity dates, CA constraints and the host name. An expired chain now fails, a forged leaf next to a genuine pinned certificate fails, a leaf your pinned CA issued for another host fails, and with `.publicKeys` the server must send the certificate that carries the pinned key. Alamofire's evaluators, which 1.x used, only checked that a pin appeared in the chain. There is no opt-out: renew the expired certificate, or pin a key the server sends.

Because the host name is checked (TM-35), a private-CA leaf must name the host in its subject alternative names; a certificate with only a common name, or issued for another host, now fails with `serverTrustEvaluationFailed`. Reissue it with a SAN for every host it serves. The pin step also evaluates a copy of the server's trust, so in `.composite([.publicKeys(pins, performDefaultValidation: false), .default])` the `.default` step now checks the system roots instead of the pinned anchors (TM-47).

#### Replacing a credential cancels a refresh's effect

`AuthenticationInterceptor.setCredential(_:)` during a refresh now supersedes it: the refresh's result is discarded, and the requests waiting for it return their `401` instead of being retried (TM-36). Before, the renewed token of the previous credential overwrote the one you set, so a logout or account switch during a refresh was undone. Retry those requests yourself if they belong to the new session.

#### Resume data for another URL is discarded

`download(_:resumeData:)` uses the resume data only when its URL matches the request's; otherwise, or when it cannot be read, the download starts fresh (TM-39). A resumed download still sends the request stored in the resume data, with its original headers: interceptors, `hosts:` and header validation don't apply to it again.

#### Descriptions are redacted

`String(describing:)` of an `HTTPRequestError` now gives the case with only the status, method, host and path, such as `unacceptableStatusCode(500, GET api.example.com/v1/users/42)`. It never includes headers, query strings, bodies or underlying error values. `HTTPHeaders` and `HTTPHeader` descriptions redact credential values. If you parsed either description, match the error's cases and read `error.response` instead, and read header values by name:

```swift
let token = headers["Authorization"]
```

#### Caches are credential-safe

`URLSessionNetworkService` never stores in `URLCache` a response to a request carrying a credential header, any name the [Redaction rules](SECURITY.md#redaction-rules) mark (`Authorization`, `Cookie`, `Proxy-Authorization`, `X-Api-Key`, …), whether set on the request or in the configuration's `httpAdditionalHeaders`. The Netti disk cache is excluded from backups and, on iOS, tvOS, watchOS and visionOS, written with `completeUntilFirstUserAuthentication` protection. The offline cache key still doesn't include the credential, so call `clearCache()` on logout.

## Alamofire to Netti

Netti covers Alamofire's request features with plain async methods. You don't chain calls or use response serializers. Instead, you describe each endpoint once as an `HTTPRequest` type.

| Alamofire | Netti |
|---|---|
| `AF.request(url).serializingDecodable(User.self).value` | `let user: User? = try await netti.get(UserAPI.user(42)).data` |
| `AF.request(url, method: .post, parameters: body, encoder: JSONParameterEncoder.default)` | `netti.post(UserAPI.users, body: body)` |
| `.validate()` | `netti.validation = ResponseValidation()`, or per endpoint |
| `AFError` | `HTTPRequestError` (typed throws) |
| `Session(interceptor:)`, `RequestInterceptor`, `RequestAdapter`, `RequestRetrier` | `netti.interceptors` with `RequestInterceptor`, `RequestAdapter`, `RequestRetrier` |
| `AuthenticationInterceptor` + `Authenticator` | `AuthenticationInterceptor(bearerToken:refresh:)` or `(credential:apply:refresh:)` |
| `RetryPolicy` | `RetryPolicy` (adds jitter and `Retry-After`) |
| `ServerTrustManager(evaluators:)` | `ServerTrustPolicy([...])` passed to `URLSessionNetworkService(trustPolicy:)` |
| `PublicKeysTrustEvaluator` | `.publicKeys([...])`, which takes SPKI SHA-256 pins rather than bundled certificates |
| `PinnedCertificatesTrustEvaluator` | `.pinnedCertificates()` or `.pinnedCertificates([Data])` |
| `RevocationTrustEvaluator`, `DefaultTrustEvaluator`, `CompositeTrustEvaluator` | `.revocation`, `.default`, `.composite([...])` |
| `DisabledTrustEvaluator` | `.disabled`, compiled in DEBUG builds only |
| `AF.upload(data/fileURL, to:)` | `netti.upload(endpoint, data:)` / `upload(endpoint, fileURL:)` |
| `AF.upload(multipartFormData:to:)` | `netti.upload(endpoint, multipart: form)` |
| `AF.download(url, to:)`, `.downloadProgress`, `AF.download(resumingWith:)` | `netti.download(endpoint, to:progress:)`, `download(..., resumeData:)` |
| `AF.streamRequest(url)` | `netti.stream(endpoint)` with `.body`, `.lines` or `.serverSentEvents` |
| `EventMonitor`, `ClosureEventMonitor` | `EventMonitor` (no-op defaults) in `netti.monitors` |
| `cURLDescription()` | `NetworkLogger`, on in DEBUG builds, with credentials redacted |
| `Redirector` | `RedirectHandler` in `URLSessionNetworkService(redirectHandler:)`; `.secure` by default, `.follow` matches `Redirector.follow` |
| `NetworkReachabilityManager` | `NetworkMonitor.shared` |
| `URLEncodedFormEncoder`, `URLEncodedFormParameterEncoder` | Same names, with array, bool, date, key and space strategies |

```swift
// Alamofire
let user = try await AF.request("https://api.example.com/v1/users/42")
    .validate()
    .serializingDecodable(User.self)
    .value

// Netti
let netti = Netti()
netti.validation = ResponseValidation()
let user: User? = try await netti.get(UserAPI.user(42)).data
```

Netti has no equivalent of Alamofire's Combine publishers, its `URLCache`-backed `CachedResponseHandler`, or its non-Apple platform support. In return, you get things Alamofire doesn't ship: an offline disk cache, WebSockets without SPI, batches, queues, in-flight deduplication and the `NettiTesting` stub server.
