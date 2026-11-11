# Security

Netti is the networking layer under every package built on it, so its defaults decide how credentials, PII and app availability hold up against a hostile network or server. This document lists what Netti 3 protects by default, what you opt into, what stays your app's job, and which risks are accepted and why.

## Supported versions

| Version | Security fixes |
|---|---|
| 3.x | Yes |
| 2.x | No. Upgrade to 3.x with [MIGRATION.md](MIGRATION.md) |
| 1.x | No. None of the defaults below exist in 1.x; upgrade with [MIGRATION.md](MIGRATION.md) |

## Reporting a vulnerability

Report privately to the maintainer. Do not open a public issue or pull request for a vulnerability.

security contact: <maintainer email>

Include the Netti version, the platform and OS version, the engine (`URLSessionNetworkService` or your own), and a reproduction: ideally a failing test, or the request and response bytes. Strip real tokens and personal data first.

## Secure defaults

`Netti()` gets every row below with no configuration. Unless a row says otherwise, it applies to the default engine, `URLSessionNetworkService`.

| Protection | Default | Opt-out |
|---|---|---|
| TLS floor | TLS 1.2 or later on both engines. A configuration that already requires TLS 1.3 keeps it | None. You can raise the floor through `URLSessionConfiguration.tlsMinimumSupportedProtocolVersion`, never lower it |
| Redirects | `RedirectHandler.secure`: an `https` → `http` redirect fails with `requestFailed(URLError(.appTransportSecurityRequiresSecureConnection))`. On a redirect to another origin (scheme, host or port), `Authorization`, `Proxy-Authorization` and `Cookie` are stripped. On the same origin they are kept, restored after `URLSession` drops them. A cross-origin 307 or 308 for a request with a body is not followed; the 3xx is returned, so the body never reaches that origin | `URLSessionNetworkService(redirectHandler: .follow)` follows every redirect unchanged. A custom `RedirectHandler` replaces `.secure` and takes over its checks |
| Response size | A data or upload response body over 64 MB fails with `requestFailed(URLError(.dataLengthExceedsMaximum))`, before the body arrives when `Content-Length` declares it. Downloads and streams are not limited | `URLSessionNetworkService(maximumResponseSize: nil)`, or a different byte count |
| Total request time | 300 s per data or upload request, response included; a request still running at the deadline fails with `requestFailed(URLError(.timedOut))`. Byte and SSE streams, WebSockets and downloads are exempt. The configuration's `timeoutIntervalForResource` is kept as given; a value you set applies to every task, streams included | `URLSessionNetworkService(maximumRequestDuration: nil)`, or a different duration |
| Line streams | `lines` throws `requestFailed(URLError(.dataLengthExceedsMaximum))` on a line over 1 MB, and splits in linear time | `AsyncLineSequence(response.body, maximumLineLength:)` |
| Server-Sent Events | One event's `data` is capped at 1 MB (same error). A `retry:` field above 1 hour is ignored | `ServerSentEventSequence(AsyncLineSequence(response.body), maximumDataLength:)`. The `retry` cap has none |
| Stream back-pressure | A byte stream fails when its consumer falls more than 8 MB behind; a WebSocket when it falls more than 8 MB or 1,000 messages behind (same error) | None |
| Header validation | A header name must be a non-empty RFC 9110 token. A value must hold no control character other than tab (CR, LF and NUL included). A failure throws `encodingFailed` and sends nothing. Checked when the request is built and again after interceptors adapt it. Exception: a resumed download sends the request stored in its resume data, with its original headers (see [Your app's responsibilities](#your-apps-responsibilities)) | None |
| Form nesting | URL-encoded forms nest at most 32 levels; deeper throws `encodingFailed` instead of exhausting the stack | None |
| Multipart | A custom boundary must follow RFC 2046 (1–70 allowed characters). A part's MIME type must hold no control character. NUL in a name or file name is rejected. `"`, CR and LF in a name or file name are percent-escaped, on Unicode scalars, so a combining mark cannot hide them. A failure throws `encodingFailed` | None |
| `Retry-After` | Read only as 1–10 decimal digits or an HTTP-date; anything else (`inf`, `1e21`, `-1`) is ignored and backoff applies. A wait over 60 s is not retried; the response is returned | `RetryPolicy(maximumRetryAfter: .seconds(300))` |
| `URLCache` | A response to a request carrying a credential header is never stored in `URLCache`, which keys by URL alone. A credential header is any name the [Redaction rules](#redaction-rules) mark (`Authorization`, `Cookie`, `Proxy-Authorization`, `X-Api-Key`, …), on the request or in the session configuration's `httpAdditionalHeaders` | None |
| Netti disk cache | The cache directory is excluded from backups. On iOS, tvOS, watchOS and visionOS each entry is written with `completeUntilFirstUserAuthentication` file protection | None |
| Logging | `NetworkLogger` is on in DEBUG builds and off in release builds. Every message is marked private in the unified log, and nothing is printed. A body over 64 KB is never parsed or logged, only its byte count | `netti.isLoggingEnabled = true` in a release build, or `false` in a DEBUG build |
| Redaction | See [Redaction rules](#redaction-rules). Applied to logs, `HTTPHeaders.description`, `HTTPHeader.description` and `HTTPRequestError.description` | None. A custom `EventMonitor` sees the adapted request, credentials included |

### Redaction rules

A name marks a credential when, compared case-insensitively:

- it contains `auth`, `token`, `key`, `secret`, `session`, `cookie`, `password`, `passwd`, `pwd`, `signature`, `credential` or `otp`;
- one of its words is `sig` or `pin`. Words split at every character that is not a letter or digit, and at every lowercase-to-uppercase change: `X-Sig` and `userPin` match, `design` and `spinner` do not;
- it is exactly `code`, the OAuth authorization code, optionally after `X-`. `countryCode` does not match.

What the logger and descriptions do with it:

- A header or query item with such a name shows `<redacted>` (`NetworkLogger.redactionMarker`). A password in the URL is redacted too.
- A request that carries such a header has its whole body replaced by `<redacted>`.
- In any other request or response body, the value of every such key is redacted at any depth when the body is JSON, and per pair when it is form-urlencoded. A request body in another format is logged as it is. A response body that is not JSON is not logged; on a decoding failure only its coding path and byte count are.
- `HTTPRequestError.description` gives the case with the status, method, host and path. It never includes headers, query strings, bodies or the values inside underlying errors, so you can send it to a crash reporter.

The fragments over-redact on purpose: `Idempotency-Key`, `author`, `footprint` (contains `otp`), and a JSON `"code"` field such as an error code are all hidden. A hidden harmless value costs a debugging session; a leaked token costs an account.

## Opt-in protections

Each is one line.

**Idempotency key.** Sets an `Idempotency-Key` UUID on every `POST` and `PATCH` that has none. The key stays the same across retries of one call, and `RetryPolicy` then retries the keyed request like an idempotent one. Your server must honour the key, since replay protection is server-side.

```swift
netti.interceptors.append(.idempotencyKey)
```

**Token host scope.** Without `hosts:`, `AuthenticationInterceptor` sends the token to every host the client calls, including a presigned storage URL or a CDN. With it, only the listed hosts get the token, and a `401` from any other host does not trigger a refresh:

```swift
AuthenticationInterceptor(bearerToken: token, hosts: ["api.example.com"]) { _ in try await refreshToken() }
```

**Certificate pinning.** Pin SPKI hashes or certificates per host with a `ServerTrustPolicy`; it applies to every request and WebSocket the engine opens. See the *Certificate Pinning* article in the DocC catalog (`Sources/Netti/Netti.docc/CertificatePinning.md`), including what `performDefaultValidation: false` checks: the pins become the only anchors, and the chain, validity dates and host name are still checked.

```swift
let netti = Netti(service: URLSessionNetworkService(trustPolicy: ServerTrustPolicy(["api.example.com": .publicKeys([primaryPin, backupPin])])))
```

A pin or trust failure throws `serverTrustEvaluationFailed` and reaches `EventMonitor.requestDidFail`, for data, transfer and WebSocket requests alike.

## Your app's responsibilities

Netti cannot do these for you:

- **Call `clearCache()` on logout.** The offline cache key covers the method, URL and body, not the credential, so user B can be served user A's cached response after an account switch (TM-11). The key stays stable across token refreshes on purpose.

  ```swift
  try await netti.clearCache()
  ```

- **Move or delete finished downloads.** Without a destination, a download stays in `tmp/netti.downloads` until you move or delete `fileURL` (TM-23).
- **Treat resume data as a secret.** `resumeData` embeds the original request, `Authorization` included. If you persist it, store it in the Keychain or with `.complete` file protection (TM-23).
- **Expect resumed downloads to keep their original headers.** A resumed download sends the request stored in its resume data: interceptors, the `hosts:` scope and header validation don't run again, so a token refreshed since is not used. Netti discards resume data whose URL differs from the request's or cannot be read (TM-39).
- **Set `hosts:` on `AuthenticationInterceptor`** whenever the client also talks to hosts that are not yours (TM-12).
- **Keep App Transport Security on.** ATS already blocks cleartext and weak TLS for app traffic. Netti's TLS floor and downgrade refusal are defence in depth, and Netti cannot override an ATS exception your `Info.plist` grants.
- **Treat event monitors as trusted code.** Monitors receive adapted requests with `Authorization` (TM-30). Don't forward them unredacted to analytics.
- **Keep `.disabled` and custom evaluators out of shipped builds.** `ServerTrustEvaluator.disabled` compiles only when the package builds with `DEBUG`. A custom build configuration that defines `DEBUG` for a distributed build (Staging, Ad Hoc) brings it back (TM-22).
- **Ship at least two pins per host.** One pin, or two pins on the same key, locks every installed app out when the key rotates. Netti logs a warning for fewer than two (TM-34).
- **Replace pinned certificates before they expire.** An expired pinned certificate rejects its host in every installed app. Netti logs a warning for each pinned certificate that is expired or expires within 30 days; call `ServerTrustPolicy.pinnedCertificatesExpiring(within:)` at launch to report them yourself, and ship the new certificate in a release before the server switches to it. Public-key pins have no expiry.

## Accepted risks

| ID | Risk | Why it is accepted |
|---|---|---|
| TM-chaos-1 | `URLSession` falls back to HTTP/0.9 on a malformed status line and reports a synthesized `200` whose body is the raw bytes | Engine-level behaviour Netti cannot see. Over `https`, TLS and pinning stop anyone but the server from injecting such a response |
| TM-chaos-2 | A chunked body cut off before its last chunk is reported as complete | Engine-level: `URLSession` ends the task without an error. Enable `ResponseValidation`, and validate payloads whose completeness matters |
| — | When a connection closes early under load, `URLSession` can drop bytes it read but did not yet deliver, so a stream receives fewer bytes than were sent | Engine-level. The stream ends or throws as usual; Netti cannot recover bytes `URLSession` never delivered |
| TM-red-2 | The cache key sorts query items by name and value, so `?id=1&id=2` and `?id=2&id=1` share one entry | Repeated keys whose order changes meaning are rare. Sorting keeps keys stable for the common case |
| TM-red-3 | The cache key ignores headers, so content-negotiated variants of one URL share an offline entry | Netti caches only endpoints that opt in. Don't opt in an endpoint whose response varies by header |
| TM-red-4 | Cache entries carry no integrity check; a modified entry is served | Modifying it needs write access to the app's Caches directory, at which point the attacker already controls the app's data |
| TM-red-9 | A header value with CR or LF set by an adapter is silently dropped by Foundation's `URLRequest`, so the request is sent without it instead of failing with `encodingFailed` | Foundation drops the value before Netti's check runs. Nothing is injected; validate values in your adapter if a missing header matters |
| TM-scope / TM-44 | `AuthenticationInterceptor(hosts:)` matches the host only, not the scheme or the port: the token also goes to `api.example.com:8443` | ATS and `.secure` redirects keep app traffic on `https`. A port on your own host is your own server; list only hosts whose every port you trust |
| TM-42 | `HTTPRequestError.description` is redacted, but `dump(error)` and `Mirror`-based reporters still reach the embedded response: the request's `Authorization` and the response's `Set-Cookie` | Reflection walks stored properties by design. Send `String(describing: error)` to crash reporters and logs, never `dump(error)` or a reporter that reflects the error |
| TM-24 | `..` segments in a path are kept | Authorization is the server's job |
| TM-25 | An `http` base URL opens a cleartext `ws://` WebSocket | Same exposure as `http://`; ATS governs it |

### Out of scope

These belong to the OS or the server, so Netti documents them rather than reimplementing them:

- Connection pooling, HTTP/2 multiplexing and keep-alive: owned by `URLSession`. Netti exposes only `maxConnectionsPerHost`.
- TLS cipher suites, curves and renegotiation: chosen by the OS TLS stack under ATS.
- Post-quantum key exchange (hybrid ML-KEM): negotiated by the OS when both ends support it.
- Certificate Transparency and revocation freshness: enforced by the OS. Netti offers opt-in `.revocation(requirePositiveResponse:)`.
- Replay protection: server-side replay windows, nonces and timestamps. Netti ships only the opt-in `Idempotency-Key`.
- Jailbreak and debugger detection, binary protections: an app-level concern; a networking library cannot defend a compromised process.
- Supply chain: Netti has no third-party dependencies (TM-33).

## OWASP mapping

Mapped from the threat model, `openspec/changes/netti-2/threat-model.md`, against OWASP MASVS v2 and the Mobile Top 10 (2024).

| MASVS control | Netti 3 coverage | Findings |
|---|---|---|
| MASVS-NETWORK-1 | TLS 1.2 floor, `.secure` redirects, token host scope | TM-03, 04, 05, 06, 12, 13, 25 |
| MASVS-NETWORK-2 | Pins anchor the chain when default validation is off; `.disabled` DEBUG-only; trust failures observable | TM-02, 15, 22 |
| MASVS-STORAGE-1 | No `URLCache` for authenticated requests; disk cache file protection and backup exclusion | TM-10, 17 |
| MASVS-STORAGE-2 | Redacted logs and descriptions; logging off in release; `clearCache()` on logout; resume data guidance | TM-10, 11, 18, 19, 23 |
| MASVS-AUTH-1 | Credentials never cross origins on redirect; token host scope | TM-03, 12 |
| MASVS-CODE-4 | Bounded responses and streams, header and form validation, safe `Retry-After` | TM-01, 07, 08, 09, 14, 16, 20, 21, 24 |

| Mobile Top 10 (2024) | Findings |
|---|---|
| M1 Improper Credential Usage | TM-12 |
| M3 Insecure Authentication/Authorization | TM-03, 12 |
| M4 Insufficient Input/Output Validation | TM-01, 07, 08, 09, 14, 16, 20, 21, 24 |
| M5 Insecure Communication | TM-02, 03, 04, 05, 06, 13, 15, 25 |
| M6 Inadequate Privacy Controls | TM-05, 11, 18, 19 |
| M8 Security Misconfiguration | TM-04, 06, 13, 22 |
| M9 Insecure Data Storage | TM-10, 11, 17, 23 |

## How security is tested

Each `transport-security` requirement has named tests. On top of them, `Tests/NettiTests/Security/` holds three adversarial suites:

- **Fuzz** (`Fuzz*Tests`): seeded random input to the SSE parser, line splitter, form encoder, multipart encoder, headers, `Retry-After`, certificate and SPKI parsing, JSON decoding and corrupted disk cache entries. The invariants are no trap, a typed `HTTPRequestError`, and bounded time and memory.
- **Chaos** (`Chaos*Tests`): a real-socket server that drops mid-body, resets, drips, sends garbage status lines, wrong `Content-Length`, broken chunking and header floods. Retry, deduplication and queues must not wedge, and the client must deallocate.
- **Red team** (`RedTeam*Tests`): forged chains (self-signed leaf next to a genuine pinned intermediate), wrong, expired and other-host certificates, 10,000 random pins, cache tampering and cross-user reads, token leakage through redirects and logs, `https` → `http` downgrade, 1,000 concurrent `401`s with exactly one refresh, and a pinned and an unpinned engine in one process.

```sh
swift test --filter Fuzz
NETTI_FUZZ_ITERATIONS=100000 swift test --filter Fuzz
NETTI_FUZZ_SEED=0x1234 swift test --filter Fuzz
NETTI_FUZZ_REPLAY=0x… swift test --filter FuzzHeaderTests
swift test --sanitize=address
swift test --sanitize=thread
```

- `NETTI_FUZZ_ITERATIONS`: cases per fuzz test, 200 by default.
- `NETTI_FUZZ_SEED`: the base seed, decimal or `0x` hex, for a different but reproducible run.
- `NETTI_FUZZ_REPLAY`: one failing case's seed, as printed in the failure (`seed=0x…`). Filter to the failing test to replay it.

The accepted risks above are kept in the suites as `withKnownIssue` tests, so a change in Foundation's behaviour shows up.

This is evidence, not proof. The suites show that the threats in the threat model are handled as described, on the OS versions they ran on. They cannot show that Netti is unbreachable, and no client library can. The remaining risk lies with the OS TLS stack, the server, the app's configuration (ATS exceptions, custom evaluators, monitors that log) and compromised devices.
