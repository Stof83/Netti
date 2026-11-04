<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Assets/netti-light.png" width="420">
  <img src="./Assets/netti.png" alt="Netti" width="420">
</picture>

**Async/await networking for Apple platforms. Simple. Swift. Secure.**

[![Swift](https://img.shields.io/badge/Swift-6.4-orange?style=flat-square)](https://www.swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS_17_|_macOS_14_|_tvOS_17_|_watchOS_10_|_Catalyst_17-green?style=flat-square)](#requirements)
[![Swift Package Manager](https://img.shields.io/badge/Swift_Package_Manager-compatible-orange?style=flat-square)](#installation)
[![Release](https://img.shields.io/github/v/release/Stof83/Netti?style=flat-square)](https://github.com/Stof83/Netti/releases)
[![Docs](https://img.shields.io/badge/docs-DocC-blue?style=flat-square)](./Sources/Netti/Netti.docc)
[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

**[Features](#features)** • **[Quick Start](#quick-start)** • **[Installation](#installation)** • **[Usage](#usage)** • **[Documentation](#documentation)** • **[Netti vs Alamofire](#netti-vs-alamofire)** • **[Testing](#testing)**

**[Guides](./Sources/Netti/Netti.docc/GettingStarted.md)** • **[Examples](EXAMPLES.md)** • **[Migration](MIGRATION.md)** • **[Security](SECURITY.md)** • **[Changelog](CHANGELOG.md)**

</div>

---

Netti is a Swift networking library built on `URLSession` and Swift concurrency. You call one async method per HTTP verb and get back a typed response. Every API throws one error type, `HTTPRequestError`. Uploads, downloads, pinning, retry, streaming, WebSockets and test doubles are all built in, and the common case of each one fits in three lines or fewer. Netti has no third-party dependencies.

Upgrading from 1.x or coming from Alamofire? Read [MIGRATION.md](MIGRATION.md).

## Quick Start

With an endpoint already defined (see [Define an endpoint](#define-an-endpoint)):

```swift
let netti = Netti()
let user: User? = try await netti.get(UserAPI.user(42)).data
```

See the [Getting Started guide](./Sources/Netti/Netti.docc/GettingStarted.md) for the full walk-through.

## Features

**Requests**

- One method per verb: `get`, `head`, `delete`, `options`, `post`, `put`, `patch`, with typed throws
- JSON bodies, including top-level arrays, and an RFC 3986 URL form encoder for queries

Guide: [Making Requests](./Sources/Netti/Netti.docc/MakingRequests.md)

**Transfers**

- Upload of data, files and multipart forms (forms over 10 MB stream from disk), all with progress
- Download to a destination, with progress and resume

Guide: [Upload & Download](./Sources/Netti/Netti.docc/UploadAndDownload.md)

**Security**

- Certificate and public-key (SPKI) pinning per host, with wildcards, a missing-backup-pin warning and a pinned-certificate expiry check
- Secure by default: TLS 1.2 floor, credential-safe redirects, response and stream caps, header injection rejected, redacted DEBUG-only logs (see [SECURITY.md](SECURITY.md))

Guides: [Certificate Pinning](./Sources/Netti/Netti.docc/CertificatePinning.md), [Security](./Sources/Netti/Netti.docc/Security.md)

**Resilience**

- Interceptors, single-flight token refresh before expiry and on rejection, and a retry policy with backoff, jitter and `Retry-After`
- Opt-in response validation, per client or per endpoint
- An offline response cache with max age and a size-capped LRU, plus cache-first reads
- Concurrent, settled and sequential batches, request queues with an offline hold, and in-flight deduplication of identical `GET`/`HEAD` requests

Guides: [Interceptors & Retry](./Sources/Netti/Netti.docc/InterceptorsAndRetry.md), [Validation & Errors](./Sources/Netti/Netti.docc/ValidationAndErrors.md), [Caching & Offline](./Sources/Netti/Netti.docc/CachingAndOffline.md), [Multiple Requests & Queues](./Sources/Netti/Netti.docc/MultipleRequestsAndQueues.md)

**Streaming**

- Byte, line and Server-Sent Event streams, and a WebSocket actor

Guide: [Streaming & WebSocket](./Sources/Netti/Netti.docc/StreamingAndWebSocket.md)

**Tooling**

- Event monitors with task metrics, and a cURL logger that redacts credentials
- Connectivity monitoring with `NWPathMonitor`, observable from SwiftUI
- `NettiTesting`, a stub server so your tests never touch the network
- Swift 6 strict concurrency: `Netti`, endpoints and responses are `Sendable`

Guides: [Observability](./Sources/Netti/Netti.docc/Observability.md), [Testing](./Sources/Netti/Netti.docc/Testing.md)

## Documentation

| Guide | What it covers |
|---|---|
| [Overview](./Sources/Netti/Netti.docc/Netti.md) | Async/await networking for Apple platforms: one method per HTTP verb, typed errors, and every advanced feature opt-in through a property on the client. |
| [Getting Started](./Sources/Netti/Netti.docc/GettingStarted.md) | Add Netti to a package, describe an endpoint, and make your first request. |
| [Making Requests](./Sources/Netti/Netti.docc/MakingRequests.md) | Send any HTTP verb with a query or a JSON body, read the response, and drop down to `URLRequest` when you need to. |
| [Upload & Download](./Sources/Netti/Netti.docc/UploadAndDownload.md) | Upload data, files and multipart forms, and download to disk with progress and resume. |
| [Certificate Pinning](./Sources/Netti/Netti.docc/CertificatePinning.md) | Pin your servers' public keys or certificates per host, with wildcards, a backup-pin check and a certificate expiry check. |
| [Security](./Sources/Netti/Netti.docc/Security.md) | Know what every client protects by default, what to opt into, and what stays your app's job. |
| [Interceptors & Retry](./Sources/Netti/Netti.docc/InterceptorsAndRetry.md) | Change every request before it is sent, refresh credentials before they expire or when the server rejects them, and retry transient failures. |
| [Validation & Errors](./Sources/Netti/Netti.docc/ValidationAndErrors.md) | Decide which responses count as failures, and handle every error Netti throws. |
| [Caching & Offline](./Sources/Netti/Netti.docc/CachingAndOffline.md) | Keep the last good response of an endpoint on disk, serve it while the device is offline, and read it first for an instant UI. |
| [Streaming & WebSocket](./Sources/Netti/Netti.docc/StreamingAndWebSocket.md) | Consume a response body as it arrives, as bytes, lines or Server-Sent Events, and talk over a WebSocket. |
| [Multiple Requests & Queues](./Sources/Netti/Netti.docc/MultipleRequestsAndQueues.md) | Run requests concurrently or in sequence, queue them with priorities and an offline hold, and let identical requests share one transfer. |
| [Observability](./Sources/Netti/Netti.docc/Observability.md) | Log every request, observe the request lifecycle with event monitors, and read transfer metrics. |
| [Testing](./Sources/Netti/Netti.docc/Testing.md) | Test code that uses Netti without touching the network, with the `NettiTesting` product. |
| [Migrating from 1.x](./Sources/Netti/Netti.docc/MigratingFrom1x.md) | Move code written for Netti 1.x to the 2.0 API. |
| [Netti vs Alamofire](./Sources/Netti/Netti.docc/NettiVsAlamofire.md) | Compare Netti with Alamofire 5: what maps one to one, what Netti adds, and what it does not do. |

The rendered API reference is hosted on Swift Package Index at <https://swiftpackageindex.com/Stof83/Netti/documentation/netti> once the package is indexed, or build it locally in Xcode with Product › Build Documentation.

## Requirements

- iOS 17 / macOS 14 / tvOS 17 / watchOS 10 / Mac Catalyst 17
- Swift 6.4 toolchain (swift-tools-version 6.4)

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Stof83/Netti.git", from: "3.0.0")
],
targets: [
    .target(name: "App", dependencies: [.product(name: "Netti", package: "Netti")]),
    .testTarget(name: "AppTests", dependencies: [.product(name: "NettiTesting", package: "Netti")])
]
```

### Xcode

1. Choose File › Add Package Dependencies…
2. Paste `https://github.com/Stof83/Netti.git`.
3. Set the dependency rule to "Up to Next Major Version" from 3.0.0.
4. Add the `Netti` product to the app target and `NettiTesting` to the test target.

## Usage

### Define an endpoint


```swift
import Netti

enum UserAPI: HTTPRequest {
    case users
    case user(Int)

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String {
        switch self {
            case .users: "users"
            case .user(let id): "users/\(id)"
        }
    }
    var headers: HTTPHeaders { [.accept("application/json")] }
}

struct User: Codable, Sendable {
    let id: Int
    let name: String
}
```

Request and response types must be `Sendable`. An endpoint can also override `cachePolicy`, `validation`, `retryPolicy`, `timeoutInterval` (60 s by default) and `sampleData`. When `sampleData` is set, it is decoded in place of a network call.

→ Full guide: [Making Requests](./Sources/Netti/Netti.docc/MakingRequests.md)

### Requests


```swift
let netti = Netti()
let user: User? = try await netti.get(UserAPI.user(42)).data
```

```swift
let page: [User]? = try await netti.get(UserAPI.users, query: Page(number: 2)).data
let created: User? = try await netti.post(UserAPI.users, body: NewUser(name: "Ada")).data
try await netti.put(UserAPI.user(42), body: NewUser(name: "Ada Lovelace"))
try await netti.patch(UserAPI.user(42), body: NewUser(name: "Ada"))
try await netti.delete(UserAPI.user(42))
let status = try await netti.head(UserAPI.user(42)).statusCode
```

`GET`, `HEAD` and `DELETE` put `query` in the URL. `POST`, `PUT` and `PATCH` send `body` as JSON, encoded with the client's `JSONManager`. Query and body keys both follow the `JSONManager` key strategy, snake_case by default, so `pageNumber` is sent as `page_number`. Query dates are ISO 8601. When you don't annotate a response type, the call returns `HTTPResponse<Empty>` and ignores the body.

`HTTPResponse.data` is optional. A 2xx body that fails to decode throws `.decodingFailed`, so on success `data` is set. Non-2xx responses are returned, not thrown, unless validation is on. Their `data` is `nil` when the body doesn't decode as the requested type, and `statusCode` and `rawData` are always available:

```swift
let response: HTTPResponse<User> = try await netti.get(UserAPI.user(42))
if response.statusCode == 401 { signOut() }
```

To send a prebuilt `URLRequest`, use `try await netti.send(URLRequest(url: url))`. Caching and sample data don't apply to it.

→ Full guide: [Making Requests](./Sources/Netti/Netti.docc/MakingRequests.md)

### Configure the client


```swift
let netti = Netti()
netti.retryPolicy = RetryPolicy()
netti.jsonManager = JSONManager(keyStrategy: .useDefaultKeys)
```

The initializer takes only `service:`, `deduplicatesRequests:` and `cacheSizeLimit:`, all optional. Everything else is a property: `jsonManager`, `interceptors`, `retryPolicy`, `validation`, `monitors`, `isLoggingEnabled` and `connectivity`. You can set them at any time, from any thread. Each request reads the configuration once, when it starts, so a change applies to the next request and never to one in flight.

→ Full guide: [Making Requests](./Sources/Netti/Netti.docc/MakingRequests.md)

### Upload


```swift
let receipt: Receipt? = try await netti.upload(ReceiptAPI.scan, fileURL: photoURL).data
try await netti.upload(ProfileAPI.avatar, data: jpegData, method: .put)
```

```swift
var form = MultipartFormData()
form.append(fileURL: photoURL, name: "avatar")
try await netti.upload(ProfileAPI.avatar, multipart: form)
```

Every upload accepts `method:` (`.post` by default, or `.put` or `.patch`) and `progress:`.

→ Full guide: [Upload & Download](./Sources/Netti/Netti.docc/UploadAndDownload.md)

### Download


```swift
let file = try await netti.download(VideoAPI.movie, to: movieURL, progress: { report($0.fractionCompleted) }).fileURL
```

When a download fails after part of the body has arrived, it throws `.downloadFailed` carrying the resume data. Pass that data back to continue:

```swift
do {
    _ = try await netti.download(VideoAPI.movie, to: movieURL)
} catch {
    resumeData = error.resumeData
}
let file = try await netti.download(VideoAPI.movie, to: movieURL, resumeData: resumeData).fileURL
```

Without a destination, the file stays in a temporary directory. `options:` defaults to `.createIntermediateDirectories`; add `.removePreviousFile` to overwrite an existing file.

→ Full guide: [Upload & Download](./Sources/Netti/Netti.docc/UploadAndDownload.md)

### Certificate pinning


```swift
let pins = ServerTrustPolicy(["api.example.com": .publicKeys(["<primary SPKI SHA-256>", "<backup SPKI SHA-256>"])])
let netti = Netti(service: URLSessionNetworkService(trustPolicy: pins))
```

Pins are base64 SHA-256 hashes of the SubjectPublicKeyInfo, so they survive certificate renewal. To compute one:

```sh
openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
```

To compute a pin in code instead, pass the certificate's DER bytes to `ServerTrustPolicy.publicKeyPin(ofCertificate:)`, or a `SecCertificate` to `ServerTrustPolicy.publicKeyPin(of:)`. Both return the same string as the pipeline above, or `nil` when the bytes are not a DER certificate.

To pin the DER certificates in your app bundle instead, use `ServerTrustPolicy(["*.example.com": .pinnedCertificates()])`.

A host with no entry is rejected, because `allHostsMustBeEvaluated` defaults to `true`. A pinned host with fewer than two pins logs a warning. The policy also applies to WebSocket handshakes. When pinning rejects a host, the request throws `.serverTrustEvaluationFailed(host:reason:)`.

A pinned certificate locks users out once it expires. The policy logs a warning for each one that is expired or expires within 30 days, and you can check at launch:

```swift
for expiry in pins.pinnedCertificatesExpiring(within: .seconds(60 * 24 * 60 * 60)) {
    report("\(expiry.host) pin expires \(expiry.notAfter)")
}
```

The check covers certificate pins only; key pins don't expire. Ship a new pin in a release before the server switches to it, and keep the old one until then. [EXAMPLES.md](EXAMPLES.md#certificate-pinning-and-expiry) has the full rotation playbook.

→ Full guide: [Certificate Pinning](./Sources/Netti/Netti.docc/CertificatePinning.md)

### Interceptors, token refresh and retry


```swift
let token = AuthToken(accessToken: login.accessToken, refreshToken: login.refreshToken, expiresIn: .seconds(login.expiresIn))
let netti = Netti()
netti.interceptors = [
    AuthenticationInterceptor(token: token, hosts: ["api.example.com"]) { expired in
        try await authAPI.refresh(using: expired.refreshToken)
    }
]
netti.retryPolicy = RetryPolicy()
```

The `refresh` closure is the only place you handle an expired token. It runs before a request is sent when the token's `expiresAt` is less than `refreshLeeway` (30 s) away, and after a response when `isRejected` says the server refused the token. By default that is any `401`; to match a body code such as `TOKEN_EXPIRED`, or a `419`, read `context.failureResponse` in your own `isRejected`. Use `expiresAt:` instead of `expiresIn:` when the server sends a date. An `AuthToken`'s description hides the tokens.

However many requests are in flight, the token is refreshed once, and each request is sent, or sent again at most once, with the new token. A request whose token isn't expired doesn't wait for a refresh that a `401` started. If a refresh for an expired token fails, the waiting requests throw its error; if a refresh after a rejection fails, they return the response they received.

Call `await auth.setCredential(_:)` on login, logout or an account switch; it supersedes a refresh in flight. The refresh closure can send its request through the same client: a `401` on that request is returned to the closure instead of waiting for the refresh. For a credential other than a bearer token, use `AuthenticationInterceptor(credential:isExpired:apply:refresh:)`.

A request that already has its own `Authorization` header, such as HTTP Basic on a login call to the same host, is sent as it is, and a `401` for it never triggers a refresh.

`RetryPolicy()` retries up to twice, and only idempotent methods or requests carrying an `Idempotency-Key` (add `.idempotencyKey` to `interceptors`). It retries after transient connection errors or a `408`, `429`, `500`, `502`, `503` or `504` response, with jittered exponential backoff from 0.5 s. It honours `Retry-After` up to 60 s; a longer wait isn't retried.

To write your own interceptor, implement `adapt`, `retry`, or both:

```swift
struct APIKey: RequestInterceptor {
    func adapt(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("secret", forHTTPHeaderField: "X-API-Key")
        return request
    }
}
```

An endpoint opts out of the client's policy with `var retryPolicy: RetryPolicy? { .disabled }`.

→ Full guide: [Interceptors & Retry](./Sources/Netti/Netti.docc/InterceptorsAndRetry.md)

### Validation


```swift
let netti = Netti()
netti.validation = ResponseValidation()
do {
    try await netti.delete(UserAPI.user(42))
} catch .unacceptableStatusCode(let status, _) {
    handle(status)
}
```

`ResponseValidation()` accepts 2xx responses whose `Content-Type` matches the request's `Accept` header. You can pass `statusCodes:`, `contentTypes:` (`.any`, `.matchAcceptHeader` or `.only([...])`) or a `custom:` closure. An endpoint opts out with `var validation: ResponseValidation? { .disabled }`. Every validation error carries the raw response in `error.response`.

→ Full guide: [Validation & Errors](./Sources/Netti/Netti.docc/ValidationAndErrors.md)

### Errors


Every API throws `HTTPRequestError`:

| Case | When |
|---|---|
| `invalidURL` | The endpoint has no base URL, or its URL can't be built |
| `encodingFailed` | The query or body can't be encoded |
| `requestFailed(URLError)` | The transport failed before a response arrived |
| `serverTrustEvaluationFailed(host:reason:)` | Trust evaluation or pinning rejected the host |
| `unacceptableStatusCode`, `unacceptableContentType`, `validationFailed` | Validation rejected the response |
| `decodingFailed(_:response:)` | A 2xx body didn't decode as the requested type |
| `cancelled` | The task or request was cancelled |
| `retryLimitExceeded(attempts:lastError:)` | Every allowed retry failed |
| `fileSystem` | A file couldn't be read, written or moved |
| `downloadFailed(_:resumeData:)` | A download failed after part of the body arrived |

→ Full guide: [Validation & Errors](./Sources/Netti/Netti.docc/ValidationAndErrors.md)

### Caching


Opt an endpoint in with `var cachePolicy: HTTPCachePolicy { .cache(maxAge: .seconds(3600)) }`. Netti then writes successful responses to disk, and serves them in place of the network while the device is offline.

```swift
let cached: HTTPResponse<[User]>? = await netti.cachedResponse(for: UserAPI.users)
try await netti.clearCache(for: UserAPI.users)
try await netti.clearCache()
```

The cache key covers the method, the URL with its query sorted, and the body. Pass the same `method:` and `parameters:` you sent the request with. The disk cache is capped at 50 MB and evicts least-recently-used entries first; change the cap with `Netti(cacheSizeLimit:)`.

→ Full guide: [Caching & Offline](./Sources/Netti/Netti.docc/CachingAndOffline.md)

### Streaming, Server-Sent Events and WebSocket


```swift
for try await event in try await netti.stream(FeedAPI.live).serverSentEvents { handle(event) }
for try await line in try await netti.stream(LogAPI.tail).lines { append(line) }
```

```swift
let socket = try await netti.webSocket(ChatAPI.room(7))
try await socket.send(ChatMessage(text: "Hi"))
for try await message in socket.messages(as: ChatMessage.self) { show(message) }
```

`stream` returns as soon as the response headers arrive. Read the body through exactly one view: `body`, `lines` or `serverSentEvents`. For a method other than `GET`, use `stream(_ urlRequest:)`. `webSocket(_:pingInterval:)` turns `http(s)` into `ws(s)`, and sends no pings unless you pass `pingInterval`.

→ Full guide: [Streaming & WebSocket](./Sources/Netti/Netti.docc/StreamingAndWebSocket.md)

### Multiple requests and queues


```swift
let users: [User?] = try await netti.concurrent(ids, maxConcurrency: 4) { id in
    try await netti.get(UserAPI.user(id)).data
}
```

`concurrent` returns results in input order, runs at most 6 operations at once by default, and cancels the rest at the first failure. `concurrentSettled` collects a `Result` for every element, and `sequential` runs one operation at a time. Annotate the result type: without it, `get` resolves to its `Empty` overload.

For a few requests of different types, use `async let`:

```swift
async let user: HTTPResponse<User> = netti.get(UserAPI.user(42))
async let users: HTTPResponse<[User]> = netti.get(UserAPI.users)
let (me, everyone) = try await (user, users)
```

A queue runs operations serially, or with `.concurrent(max:)`. It supports priorities, `pause()`, `resume()` and `cancelAll()`. With `waitsForConnectivity: true`, it holds work while the device is offline and drains it on reconnect:

```swift
let outbox = netti.queue(.serial(waitsForConnectivity: true))
try await outbox.enqueue { try await netti.post(TripAPI.log, body: entry) }
```

Concurrent identical `GET` and `HEAD` requests share one transfer. Turn that off with `Netti(deduplicatesRequests: false)`. To limit connections per host, use `URLSessionNetworkService(maxConnectionsPerHost: 4)`.

→ Full guide: [Multiple Requests & Queues](./Sources/Netti/Netti.docc/MultipleRequestsAndQueues.md)

### Observability


```swift
struct SlowRequests: EventMonitor {
    func requestDidCollectMetrics(_ metrics: URLSessionTaskMetrics, for request: URLRequest) {
        if metrics.taskInterval.duration > 2 { report(request) }
    }
}
let netti = Netti()
netti.monitors = [SlowRequests()]
```

Every `EventMonitor` method has a no-op default, so you implement only the events you need. The built-in `NetworkLogger` writes each request as a cURL command to the unified log. It is on in DEBUG builds and off in release builds; change that with `netti.isLoggingEnabled`. It replaces credential values with `<redacted>`: any header, query item or JSON key whose name contains `auth`, `token`, `key`, `secret`, `session`, `cookie`, `password` and similar fragments. The full rules are in [SECURITY.md](SECURITY.md#redaction-rules).

`NetworkMonitor.shared` reports connectivity. Its `status`, `isConnected` and `isDisconnected` are `@MainActor` and observable from SwiftUI:

```swift
if NetworkMonitor.shared.isDisconnected { OfflineBanner() }
```

Off the main actor, read `NetworkMonitor.shared.currentStatus` instead.

→ Full guide: [Observability](./Sources/Netti/Netti.docc/Observability.md)

### Redirects


Redirects are followed through `RedirectHandler.secure` by default. An `https` → `http` redirect fails, `Authorization`, `Proxy-Authorization` and `Cookie` are dropped on a redirect to another origin, and a cross-origin 307 or 308 that would re-send a body isn't followed. To change that, pass a handler:

```swift
let netti = Netti(service: URLSessionNetworkService(redirectHandler: .doNotFollow))
```

`.follow` follows every redirect unchanged, credentials and body included; it is the explicit opt-out of `.secure`. `RedirectHandler { proposed, response in ... }` returns `.follow`, `.doNotFollow` or `.modify(request)`, and replaces `.secure` entirely.

→ Full guide: [Security](./Sources/Netti/Netti.docc/Security.md)

### Security


`Netti()` is secure by default: TLS 1.2 or later, `.secure` redirects, a 64 MB response cap, a 300 s total time for data and upload requests (streams and WebSockets exempt), bounded streams, header injection rejected, no `URLCache` for authenticated responses, and logging on in DEBUG builds only with credentials redacted. Two protections are opt-in:

```swift
netti.interceptors.append(.idempotencyKey)
AuthenticationInterceptor(bearerToken: token, hosts: ["api.example.com"]) { _ in try await refreshToken() }
```

Call `try await netti.clearCache()` on logout, since the offline cache isn't keyed by user. [SECURITY.md](SECURITY.md) lists every default and how to change it, your app's responsibilities, the accepted risks, and how to report a vulnerability.

→ Full guide: [Security](./Sources/Netti/Netti.docc/Security.md)

## Testing


```swift
let server = StubServer()
server.stub(.get, "https://api.example.com/v1/users/42", json: User(id: 42, name: "Ada"))
let user: User? = try await server.netti().get(UserAPI.user(42)).data
```

Each `StubServer` is isolated, so tests can run in parallel. `server.netti()` builds a client with its own empty cache, no logging and a connected network, and it doesn't wait out retry delays. You can also stub a status (`status: 503, times: 2`), an `error:` or a `delay:`. To inspect what was sent, read `server.requests`:

```swift
let sent: NewUser = try server.requests[0].decodedBody()
```

`server.redirect(from:to:)` answers with a real `302`, so the engine's `RedirectHandler` decides whether to follow it. To build your own client, use `server.service()` or `server.configuration`. To test without `URLSession` at all, `StubNetworkService` provides closure-based handlers.

→ Full guide: [Testing](./Sources/Netti/Netti.docc/Testing.md)

## Netti vs Alamofire

Netti runs on its own `URLSession` engine, `URLSessionNetworkService`, and has no third-party dependencies. Adding Netti never fetches Alamofire.

| | Netti 3 | Alamofire 5 |
|---|---|---|
| Request style | `try await netti.get(endpoint)`, one method per verb | `AF.request(...).validate().serializingDecodable(T.self).value` |
| Errors | Typed throws: `HTTPRequestError` | `AFError`, untyped throws |
| Non-2xx responses | Returned with status and body; validation is opt-in | Returned unless you call `validate()` |
| Upload (data, file, stream, multipart) | Yes | Yes |
| Download with resume and progress | Yes; resume data travels on the thrown error | Yes |
| Server trust | `ServerTrustPolicy`: default, revocation, SPKI SHA-256 pins, pinned certificates, composite, custom, disabled (DEBUG builds only); `*.host` wildcards | `ServerTrustManager` with the matching evaluators; keys come from certificates |
| Interceptors and token refresh | `RequestInterceptor`; `AuthenticationInterceptor` refreshes once, before expiry or after a rejection, for any number of concurrent requests | `RequestInterceptor`, `AuthenticationInterceptor` |
| Retry | `RetryPolicy`: backoff with full jitter, `Retry-After` capped at 60 s, idempotent or `Idempotency-Key` requests only | `RetryPolicy` |
| Event monitoring | `EventMonitor` with metrics; DEBUG-only logger redacts credentials in headers, queries and bodies | `EventMonitor`, `cURLDescription()` |
| Redirects | `RedirectHandler`; `.secure` by default: no `https` → `http`, no credentials to another origin | `Redirector`; follows by default |
| Streaming | Bytes, lines, Server-Sent Events | `DataStreamRequest` |
| WebSocket | `WebSocketConnection` actor, JSON in and out, keep-alive pings | Experimental, behind `@_spi(WebSocket)` |
| Response cache | Offline disk cache with max age, LRU size cap, cache-first reads | `CachedResponseHandler` over `URLCache` |
| Batches, queues, deduplication | `concurrent`, `concurrentSettled`, `sequential`, `RequestQueue`, in-flight `GET`/`HEAD` deduplication | Not built in |
| Reachability | `NetworkMonitor` (`@Observable`) | `NetworkReachabilityManager` |
| Test doubles | `NettiTesting`: `StubServer`, `StubURLProtocol`, `StubNetworkService` | Not shipped |
| Combine | No | Yes |
| Platforms | iOS 17, macOS 14, tvOS 17, watchOS 10, Mac Catalyst 17 | Lower deployment targets, plus non-Apple platforms |

→ Full comparison: [Netti vs Alamofire](./Sources/Netti/Netti.docc/NettiVsAlamofire.md)

## Examples

[EXAMPLES.md](EXAMPLES.md) maps every feature to a file in [`Examples/`](Examples), with walk-throughs of token refresh and certificate pinning. The examples run offline and check their own results:

```sh
swift run NettiExamples
```

## Contributing

Contributions are welcome. Please open an issue to discuss a feature, fix or improvement, or send a pull request. Run `swift test` before opening a pull request.

## Security

Report vulnerabilities as described in [SECURITY.md](SECURITY.md#reporting-a-vulnerability).

## License

Netti is available under the MIT License. See [LICENSE](./LICENSE) for details.
