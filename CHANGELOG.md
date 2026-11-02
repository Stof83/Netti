# Changelog

All notable changes to this module are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this module adheres to [Semantic Versioning](https://semver.org/).

## [2.0.0] - 2026-11-02

Netti 2.0 is a major release with breaking changes. Every one of them, with before and after code, is in [MIGRATION.md](MIGRATION.md).

### Added

- **requests**: one method per verb: `get`, `head`, `delete`, `options`, `post`, `put` and `patch`. All use typed throws `throws(HTTPRequestError)`, and each has an `HTTPResponse<Empty>` overload.
- **requests**: `HTTPRequest.validation` and `HTTPRequest.retryPolicy` for per-endpoint overrides.
- **configuration**: `Netti` properties `jsonManager`, `interceptors`, `retryPolicy`, `validation`, `monitors`, `isLoggingEnabled` (`true` in DEBUG builds, `false` in release builds) and `connectivity`. They are thread-safe and can be set at any time; each request reads them once when it starts, so a change applies to the next request, never one in flight.
- **requests**: `HTTPResponse.metrics`, `HTTPResponse.statusCode`, `HTTPDownloadResponse.metrics` and `HTTPDownloadResponse.statusCode`, plus public initializers.
- **requests**: `HTTPMethod.isIdempotent` and `HTTPMethod.defaultParameterDestination`. `HTTPMethod` is now `CaseIterable` and `Sendable`.
- **encoding**: `URLEncodedFormEncoder` and `URLEncodedFormParameterEncoder`, with array, bool, date, key and space strategies, RFC 3986 escaping and query merging. Also `JSONParameterEncoder`, which encodes `Encodable` straight to `Data`.
- **encoding**: `MultipartFormData` with data, file and stream parts. Forms over 10 MB stream from a temporary file.
- **encoding**: `HTTPHeader.jsonContentType`, `formURLEncodedContentType` and `multipartFormDataContentType(boundary:)`, and the `HTTPHeaders.contentType` accessor.
- **transfers**: `upload(_:data:)`, `upload(_:fileURL:)` and `upload(_:multipart:)`, each with `method:` (`UploadMethod`) and `progress:`.
- **transfers**: `download(_:to:options:resumeData:progress:)` with `DownloadOptions`, `TransferProgress` and `ProgressHandler`.
- **security**: `ServerTrustEvaluating` and `ServerTrustEvaluator` with `.default`, `.revocation`, `.publicKeys` (SPKI SHA-256), `.pinnedCertificates` (data or bundle), `.composite`, `.custom`, and `.disabled` in DEBUG builds only.
- **security**: `ServerTrustPolicy`, a per-host map with `*.domain` wildcards and `allHostsMustBeEvaluated`. Both engines apply it, WebSockets included.
- **interception**: `RequestAdapter`, `RequestRetrier`, `RequestInterceptor`, `CompositeInterceptor`, `RetryContext` and `RetryDecision`.
- **interception**: `AuthenticationInterceptor`, which runs one refresh for any number of concurrent requests whose credential is expired or rejected, with `init(bearerToken:refresh:)`. The refresh closure may send its request through the same client: a `401` during the refresh is returned to the closure instead of deadlocking. Requests sent from `Task.detached` inside the closure are not covered.
- **interception**: `RetryPolicy`, with exponential backoff and full jitter, `Retry-After`, retries for idempotent methods only, and `RetryPolicy.disabled`.
- **validation**: `ResponseValidation`, opt-in per client or per endpoint, covering status codes, content type and a custom closure, plus `ResponseValidation.disabled`.
- **monitoring**: the `EventMonitor` protocol, with no-op defaults and task metrics, and `CompositeEventMonitor`. `NetworkLogger` is now a public `EventMonitor`.
- **redirects**: `RedirectHandler`, which follows, doesn't follow or modifies redirects, set through `URLSessionNetworkService(redirectHandler:)`. `RedirectHandler.secure` is the default; `RedirectHandler.follow` follows every redirect unchanged.
- **streaming**: `stream(_:query:)` and `stream(_ urlRequest:)`, returning `HTTPStreamResponse`. Read the body as `body`, `lines` (`AsyncLineSequence`) or `serverSentEvents` (`ServerSentEventSequence`, a WHATWG parser).
- **websocket**: `webSocket(_:pingInterval:)`, returning a `WebSocketConnection` actor that sends text, data or JSON and exposes `messages` and `messages(as:)`.
- **caching**: `HTTPCachePolicy.cache(maxAge:)`, an LRU disk cache capped by `Netti(cacheSizeLimit:)` (50 MB by default), and `parameters:` on `cachedResponse` and `clearCache(for:)`.
- **orchestration**: `concurrent`, `concurrentSettled` and `sequential` batches.
- **orchestration**: the `RequestQueue` actor, with serial or concurrent modes, priorities, pause and resume, `cancelAll()` and `waitsForConnectivity`, created with `netti.queue(_:)`. `enqueue` is `@discardableResult`, so a fire-and-forget `try await queue.enqueue { … }` needs no `_ =`.
- **orchestration**: in-flight deduplication of identical `GET`/`HEAD` requests, on by default, and `URLSessionNetworkService(maxConnectionsPerHost:)`.
- **reachability**: the `ConnectivitySource` protocol, `NetworkMonitor.currentStatus` and `NetworkMonitor.statusUpdates()`, set through `netti.connectivity`.
- **testing**: the `NettiTesting` product: `StubServer`, `StubURLProtocol`, `StubNetworkService`, `StubWebSocketTransport`, `StubConnectivity` and `RecordedRequest`.
- **interception**: `IdempotencyKeyAdapter`, added with `netti.interceptors.append(.idempotencyKey)`. It sets an `Idempotency-Key` UUID on every `POST` and `PATCH` without one, keeps it across retries, and `RetryPolicy` retries a keyed request like an idempotent one.
- **interception**: `AuthenticationInterceptor(bearerToken:hosts:refresh:)` and `(credential:hosts:apply:refresh:)`. With `hosts`, the credential goes only to those hosts, and a `401` from any other host doesn't trigger a refresh. `nil`, the default, keeps sending it to every host.
- **interception**: `AuthToken`, a bearer token with its optional refresh token and `expiresAt` date, created with `expiresAt:` or `expiresIn:` (a `Duration`). Its description leaves the tokens out. `AuthenticationInterceptor(token:hosts:refreshLeeway:isRejected:refresh:)` refreshes it before sending once `expiresAt` is less than `refreshLeeway` away (30 s by default, cut to half the token's life for a short-lived token), and after a response the server rejected.
- **interception**: `isExpired:` and `isRejected:` on `AuthenticationInterceptor(credential:hosts:isExpired:isRejected:apply:refresh:)`. `isExpired` is checked before every request; `isRejected` decides which failed attempt means the credential was refused, any `401` by default. A refresh started by an expired credential that fails makes the waiting requests throw its error, so none is sent with a credential known to be expired; a request whose credential isn't expired doesn't wait for a refresh a rejection started.
- **interception**: `RetryContext.failureResponse`, the response of the failed attempt whether it was returned or carried by the error. `RetryContext.statusCode` now reads it too.
- **security**: `ServerTrustPolicy.pinnedCertificatesExpiring(within:asOf:)`, returning a `PinnedCertificateExpiry` (`host`, `subject`, `notAfter`, `isExpired(at:)`) for each pinned certificate that is expired or expires within the interval, soonest first. Certificate pins only, including inside `.composite` and under wildcard hosts. Creating a policy also logs one warning per pinned certificate that is expired or expires within 30 days. The date is read from the DER, so the check works on iOS 17.
- **interception**: `RetryPolicy.maximumRetryAfter`, the longest `Retry-After` wait honoured, 60 s by default.
- **transport**: `URLSessionNetworkService(maximumResponseSize:)`, 64 MB by default, `nil` for no limit.
- **streaming**: `AsyncLineSequence.maximumLineLength` and `ServerSentEventSequence.maximumDataLength`, both 1 MB by default and set through their initializers.
- **security**: `ServerTrustPolicy.publicKeyPin(ofCertificate:)` and `ServerTrustPolicy.publicKeyPin(of:)` compute a public-key pin in code from DER data or a `SecCertificate`: the base64 SHA-256 of the SubjectPublicKeyInfo, the same value as the `openssl` pipeline. They return `nil` for bytes that are not a well-formed DER certificate.
- **interception**: `AuthenticationInterceptor` leaves a request that already has its own `Authorization` header unchanged, such as HTTP Basic on a login or sign-up call to the same host, and a `401` for it never triggers a refresh. Every attempt adapts the original request, so a header found there was never the interceptor's.
- **testing**: `StubServer.redirect(_:from:to:status:times:)` answers with a redirect status (`301`, `302`, `303`, `307` or `308`) and a `Location` header, so the engine's `RedirectHandler` makes the decision. A `301`, `302` or `303` is followed as a `GET` without a body, a `307` or `308` keeps the method and body, and `URLSession` drops `Authorization` from the followed request, so the handler decides whether it comes back. A redirect loop fails once `URLSession` reaches its limit of 16.
- **docs**: `MIGRATION.md`, `SECURITY.md`, a rewritten README, and the DocC article *Security*.
- **docs**: `EXAMPLES.md` and the `NettiExamples` executable target, one compiled example per feature in `Examples/`, run offline with `swift run NettiExamples`. It is not a product, so consumers never see it.

### Changed

- **BREAKING**: minimum platforms are now iOS 17, macOS 14, tvOS 17, watchOS 10 and Mac Catalyst 17, and swift-tools-version is 6.4.
- **BREAKING**: `Netti` is a `final class Netti: Sendable`, no longer `open`. Its initializer is `init(service:deduplicatesRequests:cacheSizeLimit:)`, all with defaults. `jsonManager` moves from the initializer to a property: replace `Netti(jsonManager: manager)` with `netti.jsonManager = manager`.
- **BREAKING**: the default engine is `URLSessionNetworkService`, no longer `AFNetworkService`.
- **BREAKING**: `send(_:parameters:method:)` is no longer public. Use the verb methods.
- **BREAKING**: response types must be `Decodable & Sendable`, and parameters `Encodable & Sendable`. `buildRequest` and `clearCache` use typed throws. `decode(_:request:)` is no longer `async`.
- **BREAKING**: `HTTPRequest` refines `Sendable`. `requestURL` and `asURLRequest(for:)` throw `HTTPRequestError.invalidURL` instead of calling `fatalError`.
- **BREAKING**: `HTTPRequestError` is `Sendable`, with these cases: `invalidURL`, `encodingFailed`, `requestFailed(URLError)`, `serverTrustEvaluationFailed`, `unacceptableStatusCode`, `unacceptableContentType`, `validationFailed`, `decodingFailed(_:response:)`, `cancelled`, `retryLimitExceeded`, `fileSystem` and `downloadFailed`. It also gains `response` and `resumeData` accessors.
- **BREAKING**: `NetworkService` is a transport-only `Sendable` protocol with `data`, `upload`, `download`, `bytes` and `webSocket`. Engines no longer encode parameters.
- **BREAKING**: `URLSessionNetworkService.init` takes a `URLSessionConfiguration`, `trustPolicy`, `redirectHandler`, `maxConnectionsPerHost` and `maximumResponseSize`, no longer a `URLSessionConfigurationWrapper`.
- **BREAKING**: `HTTPCachePolicy` is a struct (`.none`, `.cache`, `.cache(maxAge:)`), so an exhaustive `switch` now needs `default`.
- **BREAKING**: the cache key now covers the method, the URL with a sorted query, and the body. Entries written by 1.x are no longer read.
- **BREAKING**: `NetworkMonitor` is `final`. `Status` gains `.unknown`, which is now the initial value, and `status`, `isConnected` and `isDisconnected` are `@MainActor`.
- **BREAKING**: `JSONManager` is a `final class` and `Sendable`. Decoding an `EmptyResponse` type returns its empty value.
- **BREAKING**: query parameters for `GET`, `HEAD` and `DELETE` are encoded with `URLEncodedFormEncoder`. Keys still follow the client's `JSONManager` key strategy (snake_case by default, as in 1.x), but dates are ISO 8601 instead of `JSONManager`'s date format.
- **BREAKING**: `JSONManager`'s snake_case keeps leading acronyms together, in JSON bodies and query keys alike: `URLValue` is written `url_value` (1.x `u_rl_value`) and `ID` is written `id` (1.x `i_d`). Ordinary camelCase keys are unchanged, and a key is always spelled the same in the query and the body. `KeyEncodingDecodingStrategy.toEncoderStrategy()` now returns a `.custom` strategy for `.convertSnakeCase`.
- The cache write is awaited before a request returns.
- `NetworkLogger` writes to the unified log with private payloads, and runs in DEBUG builds only. Change that with `netti.isLoggingEnabled`.
- **BREAKING**: a `nil` redirect handler now means `RedirectHandler.secure`: an `https` → `http` redirect throws `requestFailed(URLError(.appTransportSecurityRequiresSecureConnection))`, `Authorization`, `Proxy-Authorization` and `Cookie` are stripped on a redirect to another origin (and kept on the same origin), and a cross-origin 307 or 308 with a body is not followed. Pass `.follow` for the 1.x behaviour.
- **BREAKING**: a data or upload response body over 64 MB throws `requestFailed(URLError(.dataLengthExceedsMaximum))`.
- **BREAKING**: `URLSessionNetworkService(maximumRequestDuration:)`, 300 s by default, bounds the total time of a data or upload request, response included; a request still running at the deadline throws `requestFailed(URLError(.timedOut))`. Byte streams, SSE, WebSockets and downloads are exempt. Pass `nil` for no limit. The configuration's `timeoutIntervalForResource` is kept as given, and a value you set still applies to every task.
- **BREAKING**: an endpoint or adapted header whose name isn't an RFC 9110 token, or whose value holds a control character other than tab, throws `encodingFailed` and is not sent. So does a URL-encoded form nested deeper than 32 levels, a multipart MIME type with a control character, NUL in a multipart name or file name, and a custom multipart boundary that breaks RFC 2046. `"`, CR and LF in multipart names are still percent-escaped, now on Unicode scalars.
- **BREAKING**: `RetryPolicy` reads `Retry-After` only as 1 to 10 digits or an HTTP-date, and doesn't retry when it asks for more than `maximumRetryAfter`.
- **BREAKING**: with `performDefaultValidation: false`, pinning evaluators use the pins as the only trust anchors and still evaluate the chain with the SSL policy for the host, so an expired chain or a leaf for another host fails, and a `.publicKeys` pin must be on a certificate the server sends.
- **BREAKING**: `HTTPRequestError` is `CustomStringConvertible` and `CustomDebugStringConvertible`, describing only the case, status, method, host and path. `HTTPHeaders` and `HTTPHeader` descriptions redact credential values.
- Line streams split in time linear in the bytes received.

### Deprecated

- `AFNetworkService`, `AFNetworkService.init(configuration: AFConfiguration)` and `AFConfiguration`. Use `URLSessionNetworkService` with a `ServerTrustPolicy`. Alamofire stays a dependency only for this engine, and both will be removed in a later release.
- `ParameterEncoder`, `URLSessionConfigurationWrapper`, `JSONBodyParameterEncoder` and `URLQueryParameterEncoder`. No engine uses them anymore.

### Removed

- `HTTPRequestError.invalidResponse` and `HTTPRequestError.statusCode(_:)`.
- `NetworkService.send(_:parameters:method:)`, `NetworkService.send(_:)` and `NetworkService.createURLRequest(_:parameters:method:)`.
- The public `Encodable.toDictionary(dateFormat:keyEncodingStrategy:)`, `Sequence.asyncMap` and `Sequence.asyncForEach`, which are now internal, and the commented-out `Sequence.concurrentForEach`.
- The unused internal `HTTPRequestQueue` and `PendingRequest` prototypes, replaced by `RequestQueue`.

### Fixed

- Decoding errors were re-wrapped as `requestFailed`; they now throw `decodingFailed` (B1).
- The cache key ignored parameters, so `?page=1` and `?page=2` shared one entry (B2).
- Tests called `example.com` for real; every suite now runs on stubs (B3).
- The 1.x query encoder replaced existing query items, wrote arrays as `"[1, 2]"` and bools as `1`, force-unwrapped the URL, and left `+` unescaped (B4).
- Top-level array bodies were dropped, and `Decimal` precision and key order were lost (B5).
- `URLSessionNetworkService` had no server trust handling, and imported Alamofire without using it (B6).
- `NetworkMonitor` started as `.disconnected`, so a cold start could serve offline cache, and it mutated observable state off the main actor (B7).
- `Package.swift` declared platform minimums below what `@Observable` needs, so the package didn't build on macOS (B8).
- A `nil` base URL called `fatalError` (B9).
- A detached cache write raced with immediate `cachedResponse` reads (B10).
- `NetworkLogger` logged `Authorization` and cookie values (B11).
- Dead code and public extensions that leaked into importers' namespaces were removed (B12).

### Security

- Certificate and public-key pinning are available on the native engine. They apply to every request and WebSocket handshake, and fail closed for hosts without an entry by default.
- A host pinned with fewer than two pins logs a backup-pin warning.
- `ServerTrustEvaluator.disabled` exists only in DEBUG builds.
- Both engines require TLS 1.2 or later (TM-06).
- Redirects never downgrade to `http`, never carry `Authorization`, `Proxy-Authorization` or `Cookie` to another origin, and never re-send a body to another origin (TM-03, TM-04, TM-05).
- Data responses are capped at 64 MB, data and upload requests at 300 s, lines and SSE event data at 1 MB, SSE `retry` at 1 hour, and unread stream and WebSocket buffers at 8 MB or 1,000 messages (TM-07, TM-08, TM-09, TM-21).
- A malformed `Retry-After` such as `inf` or `1e21` cannot crash the app, and a long one cannot park a request for hours (TM-01).
- Header, form-nesting and multipart validation stop header injection and stack exhaustion (TM-14, TM-16, TM-20).
- With `performDefaultValidation: false`, a forged leaf sent next to a genuine pinned certificate is rejected (TM-02).
- With `performDefaultValidation: false`, the anchored chain is evaluated with the SSL policy, so the host name is checked and a pinned CA no longer accepts a leaf it issued for another host. The evaluation runs on a copy of the server's trust, so a later `.default` in a composite still checks the system roots (TM-35, TM-47).
- `AuthenticationInterceptor.setCredential(_:)` supersedes a refresh in flight: its result no longer overwrites the new credential after a logout or account switch, and its waiting requests are not retried (TM-36).
- Resume data whose URL differs from the download request's, or cannot be read, is discarded and the download starts fresh (TM-39).
- Responses to requests carrying any credential header (`Authorization`, `Cookie`, `Proxy-Authorization`, API keys and every other name the redaction rules mark), on the request or in the session's `httpAdditionalHeaders`, are never stored in `URLCache`. The disk cache is excluded from backups and file-protected (TM-10, TM-17, TM-38).
- `NetworkLogger` is off in release builds, and logs, `HTTPHeaders` descriptions and `HTTPRequestError` descriptions redact credentials by name in headers, queries and JSON or form bodies (TM-18, TM-19). A decoding failure logs a response body only when it is JSON; otherwise only the coding path and byte count. Bodies over 64 KB are never parsed or logged, only their byte count, and Xcode previews no longer `print` log messages (TM-37, TM-40, TM-41).
- Trust failures reach `EventMonitor.requestDidFail` for data, transfer and WebSocket requests (TM-26).
- Fuzz, chaos and red-team suites in `Tests/NettiTests/Security`, plus address and thread sanitizer runs. `SECURITY.md` lists the defaults, app responsibilities and accepted risks.

## [1.5.0] - 2026-06-30

### Added

- **cache**: add cache invalidation methods to DiskCache and HTTPCacheStore (de22763)

## [1.4.0] - 2026-06-16

### Added

- add public cachedResponse(for:method:) for cache-first flows (8f312ee)

