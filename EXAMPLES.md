# Examples

Each Netti feature has a working example in [`Examples/`](Examples), one file per feature. Together they form the `NettiExamples` executable target. It builds with the package but is not a product, so apps that depend on Netti never see it. Every example runs offline against the stubs in `NettiTesting` and checks its own result:

```sh
swift run NettiExamples
```

The command prints what each example does and exits non-zero if any of them fails. `swift build` compiles the examples too, so they break as soon as the API changes under them.

| Feature | File | What it shows |
|---|---|---|
| Requests | [RequestsAndVerbs.swift](Examples/RequestsAndVerbs.swift) | Every HTTP verb, a query, a JSON body, reading the status before the body, and sending a prebuilt `URLRequest` |
| Configuration | [Configuration.swift](Examples/Configuration.swift) | Every client setting: the JSON coder, interceptors, retry, validation, monitors, logging, connectivity, deduplication, cache size and the engine's own options |
| Upload | [UploadAndMultipart.swift](Examples/UploadAndMultipart.swift) | Uploading in-memory data, a file and a multipart form, with progress |
| Download | [DownloadAndResume.swift](Examples/DownloadAndResume.swift) | Downloading to a file, then resuming a download that failed halfway |
| Token refresh | [Authentication.swift](Examples/Authentication.swift) | Refreshing an expired token before sending, refreshing on a backend `TOKEN_EXPIRED` code, 20 parallel requests that share one refresh, and login, account switch and logout |
| Interceptors and retry | [InterceptorsAndRetry.swift](Examples/InterceptorsAndRetry.swift) | Adapting every request, retrying transient failures, a custom retrier and a per-endpoint override |
| Validation and errors | [ValidationAndErrors.swift](Examples/ValidationAndErrors.swift) | Turning validation on, custom rules, a per-endpoint override, and catching each kind of error |
| Caching | [CachingAndOffline.swift](Examples/CachingAndOffline.swift) | An endpoint that caches, served from disk while offline, read first for an instant UI, and invalidated |
| Streaming | [StreamingAndSSE.swift](Examples/StreamingAndSSE.swift) | Reading a response body as it arrives: Server-Sent Events, lines, and a `POST` stream |
| WebSocket | [WebSocket.swift](Examples/WebSocket.swift) | Opening a WebSocket, sending text and JSON, and reading typed messages until the server closes |
| Multiple requests | [QueuesBatchDedup.swift](Examples/QueuesBatchDedup.swift) | `async let`, batches that fail fast or keep every outcome, a sequence, a priority queue, and in-flight deduplication |
| Observability | [Observability.swift](Examples/Observability.swift) | Watching the request lifecycle with an `EventMonitor`, and what the logger redacts |
| Redirects | [Redirects.swift](Examples/Redirects.swift) | `StubServer.redirect` answers with a real `302`, so the real handler decides, offline: `.secure` keeping `Authorization` on the same origin and dropping it on another, `.doNotFollow` returning the `302` with its `Location`, a custom same-host handler, and `.follow` |
| Certificate pinning | [CertificatePinning.swift](Examples/CertificatePinning.swift) | A pin computed in code and checked against the `openssl` value, key and certificate pins, wildcards, a CDN passthrough, composite with revocation, a private CA, the DEBUG-only `.disabled`, handling a rejection, and the startup expiry check |
| Testing | [Testing.swift](Examples/Testing.swift) | Stubs, recorded requests, failures, `times:`, a stub engine that records what reaches it, and a scripted WebSocket |

[main.swift](Examples/main.swift) runs the examples in order. [Support.swift](Examples/Support.swift) holds the shared `User` model, the `UserAPI` endpoints and the `report` and `expect` helpers. One function, `pinnedRequestExample(netti:)`, only compiles: it needs a real TLS handshake, so `main.swift` doesn't call it.

## Token refresh

Give `AuthenticationInterceptor` the token from your login response and one `refresh` closure. That closure is the only place your app handles an expired token:

```swift
let token = AuthToken(accessToken: login.accessToken, refreshToken: login.refreshToken, expiresIn: .seconds(login.expiresIn))
netti.interceptors = [
    AuthenticationInterceptor(token: token, hosts: ["api.example.com"]) { expired in
        try await authAPI.refresh(using: expired.refreshToken)
    }
]
```

Use `AuthToken(accessToken:refreshToken:expiresAt:)` when the response gives a date instead of a lifetime. The interceptor sends the token as `Authorization: Bearer <accessToken>`, and only to the hosts in `hosts:`. Logging an `AuthToken` is safe, because its description shows only the expiry date.

`refresh` runs in two cases:

- **Before sending**, when the token is expired: `expiresAt` minus `refreshLeeway`, which is 30 s by default, has passed. For a token that lives less than twice the leeway, the leeway is cut to half its life, so a fresh token never counts as expired. With no `expiresAt`, only the second case applies.
- **After a response**, when `isRejected` says the server refused the token. That is any `401` by default.

**Expired by date** ([`refreshBeforeSendingExample`](Examples/Authentication.swift)). The token is refreshed before the request leaves the device, so the server never sees the stale token:

```swift
let stale = AuthToken(accessToken: "stale-token", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(-60))
let auth = AuthenticationInterceptor(token: stale) { _ in
    AuthToken(accessToken: "fresh-token", refreshToken: "refresh-2", expiresIn: .seconds(3600))
}
```

**Backend code** ([`refreshOnRejectionBodyExample`](Examples/Authentication.swift)). When the backend says why it refused the token, `isRejected` reads the status and the body through `RetryContext.failureResponse`. Only a `401` carrying `TOKEN_EXPIRED` triggers a refresh here; any other `401`, such as `ACCOUNT_SUSPENDED`, comes back untouched:

```swift
@Sendable private func isTokenExpired(_ context: RetryContext) -> Bool {
    guard context.statusCode == 401, let body = context.failureResponse?.rawData else {
        return false
    }
    return String(decoding: body, as: UTF8.self).contains("TOKEN_EXPIRED")
}

let auth = AuthenticationInterceptor(token: token, isRejected: isTokenExpired) { expired in
    try await authAPI.refresh(using: expired.refreshToken)
}
```

A backend that answers `419` instead passes `isRejected: { $0.statusCode == 419 }`.

**Parallel requests** ([`parallelRequestsShareOneRefreshExample`](Examples/Authentication.swift)). Twenty requests start with an expired token. One of them starts the refresh, the other nineteen wait for it, and all twenty go out with the new token. The same holds for any number of concurrent `401`s: one refresh, then each request is sent again, at most once. A request whose token isn't expired doesn't wait for a refresh that a `401` started.

If the refresh fails:

- When it started because the token was expired, every waiting request fails with the refresh's error. None is sent with a token known to be expired.
- When it started because of a rejected response, the waiting requests aren't retried and return the response they received.

Either way, the next request that needs a refresh tries again.

**Login and logout** ([`loginAndLogoutExample`](Examples/Authentication.swift)). `setCredential(_:)` swaps the token for a login, an account switch or a logout. It supersedes a refresh in flight, whose result is then discarded, so a logout is never undone by the old session's renewal:

```swift
await auth.setCredential(AuthToken(accessToken: "bob-token", expiresIn: .seconds(3600)))
```

The refresh closure may send its request through the same client without deadlocking: a `401` on that request comes back to the closure. This doesn't hold for requests sent from `Task.detached`.

For a credential other than a bearer token, use `AuthenticationInterceptor(credential:hosts:isExpired:isRejected:apply:refresh:)`, where `isExpired` decides when to refresh before sending.

## Certificate pinning and expiry

The snippets below are taken from [CertificatePinning.swift](Examples/CertificatePinning.swift). `primaryPin` and `backupPin` stand for base64 SPKI SHA-256 hashes.

**Public-key pins with a backup.** Key pins survive a certificate renewal as long as the server keeps its key. Always keep at least two, the current key and a backup. The policy logs a warning for a host with fewer than two. A wildcard matches exactly one leftmost label: `*.example.com` covers `eu.example.com`, but not `example.com` or `a.eu.example.com`.

```swift
let policy = ServerTrustPolicy([
    "api.example.com": .publicKeys([primaryPin, backupPin]),
    "*.example.com": .publicKeys([primaryPin, backupPin]),
])
let netti = Netti(service: URLSessionNetworkService(trustPolicy: policy))
```

The policy belongs to the engine, so it covers every request and WebSocket the client opens.

**Bundled certificates.** Pin every DER `.cer`, `.der` and `.crt` in a bundle folder, or pass the DER bytes directly:

```swift
ServerTrustPolicy([
    "api.example.com": .pinnedCertificates(in: .main, subdirectory: "Certificates"),
    "files.example.com": .pinnedCertificates([certificate]),
])
```

**CDN passthrough.** A host you don't pin gets default validation instead of being rejected:

```swift
ServerTrustPolicy(
    [
        "api.example.com": .publicKeys([primaryPin, backupPin]),
        "*.cdn.example.com": .default,
    ],
    allHostsMustBeEvaluated: false
)
```

**Composite with revocation.** Both evaluators must accept the host, in order: a soft-fail revocation check, then the pins.

```swift
ServerTrustPolicy([
    "api.example.com": .composite([.revocation, .publicKeys([primaryPin, backupPin])]),
])
```

**Private CA.** For a server issued by your own CA, the pinned certificates become the only trust anchors. The chain is still checked for validity dates, host name and key usage. Keep default validation on for public servers.

```swift
ServerTrustPolicy([
    "internal.example.com": .pinnedCertificates(in: .main, subdirectory: "Certificates", performDefaultValidation: false),
])
```

**Disable in DEBUG only.** `.disabled` exists in DEBUG builds only, so the code that names it must be conditional too, and it can never ship by accident:

```swift
let evaluator: ServerTrustEvaluator
#if DEBUG
evaluator = .disabled
#else
evaluator = .publicKeys([primaryPin, backupPin])
#endif
let policy = ServerTrustPolicy(["api.example.com": evaluator])
```

**Handling a rejection.** A rejected host throws `.serverTrustEvaluationFailed(host:reason:)`. `RetryPolicy` doesn't retry it, because it isn't a transient error.

```swift
do {
    let user: User? = try await netti.get(UserAPI.user(1)).data
    report("pinned   -> \(user?.name ?? "nil")")
} catch .serverTrustEvaluationFailed(let host, let reason) {
    report("pinned   -> untrusted \(host): \(reason)")
} catch {
    report("pinned   -> \(error)")
}
```

**Startup expiry check.** A pinned certificate locks users out the day it expires. `pinnedCertificatesExpiring(within:asOf:)` returns a `PinnedCertificateExpiry` (`host`, `subject`, `notAfter`, `isExpired(at:)`) for every pinned certificate that expires within the interval, soonest first. Expired certificates are always listed. Call it at launch and report what it returns to your logs, analytics or a dashboard while there is still time to ship a release:

```swift
let now = Date()
for pin in policy.pinnedCertificatesExpiring(within: .seconds(60 * 24 * 60 * 60), asOf: now) {
    let state = pin.isExpired(at: now) ? "EXPIRED" : "expires"
    report("expiry   -> \(pin.host) (\(pin.subject ?? "no subject")) \(state) \(pin.notAfter.formatted(.iso8601))")
}
```

The check covers certificate pins only, including those inside `.composite` and under wildcard hosts. Public-key pins have no expiry and survive renewal. Independently of this call, creating the policy logs one warning to the unified log (subsystem `Netti`, category `security`) for each pinned certificate that is expired or expires within 30 days.

**Rotation playbook.**

1. Ship the new key pin or certificate in an app release while the old one is still pinned, at least one release cycle before the server switches, plus a margin for users who update slowly.
2. Only then switch the server. The app accepts both meanwhile.
3. Drop the old pin in a later release.

Prefer key pins: they survive a renewal that keeps the key. Always keep at least two pins, the current one and a backup, so a lost or compromised key never locks users out.

**Compute a pin in code.** `ServerTrustPolicy.publicKeyPin(ofCertificate:)` takes the DER bytes, and `publicKeyPin(of:)` a `SecCertificate`, for example one from a `SecTrust` chain. Both return the same base64 SHA-256 of the SubjectPublicKeyInfo as the `openssl` pipeline below, and `nil` for bytes that are not a DER certificate, never a wrong pin. The example checks the pin of its embedded certificate against the `openssl` value:

```swift
let pin = try expectValue(ServerTrustPolicy.publicKeyPin(ofCertificate: der), "the embedded certificate has no readable public key")
try expect(pin == "vFzo9rMWlmH3bW6NPQM8oFmsF0J8fXVBGCP5gRmRwdQ=", "the pin differs from the openssl value")

// A `SecCertificate`, for example one taken from a `SecTrust` chain, works the same way.
let secCertificate = try expectValue(SecCertificateCreateWithData(nil, der as CFData), "the embedded certificate is not DER")
try expect(ServerTrustPolicy.publicKeyPin(of: secCertificate) == pin, "the SecCertificate overload must agree")

// Bytes that are not a certificate give nil, never a wrong pin.
try expect(ServerTrustPolicy.publicKeyPin(ofCertificate: Data("not a certificate".utf8)) == nil, "garbage must not produce a pin")
```

To compute a pin from a certificate in a shell:

```sh
openssl x509 -in api.example.com.pem -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | base64
```

To fetch the certificate a server sends, and to convert it to DER for the bundle:

```sh
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null | openssl x509 -outform pem > api.example.com.pem
openssl x509 -in api.example.com.pem -outform der -out api.example.com.cer
```

For the backup pin, hash the public key of a key pair you have generated but not deployed yet:

```sh
openssl pkey -in backup.key -pubout -outform der | openssl dgst -sha256 -binary | base64
```
