# Security

Know what every client protects by default, what to opt into, and what stays your app's job.

## Overview

`Netti()` is secure with no configuration: TLS 1.2 or later, redirects that never leak credentials, bounded responses and streams, rejected header and request-line injection, and logs that hide credentials. Each default has an optional parameter when you must change it. The full policy, with the threat model mapping, the accepted risks and how to report a vulnerability, is in `SECURITY.md` at the root of the repository.

### Secure defaults

| Default | To change it |
|---|---|
| TLS 1.2 or later; a stricter configuration is kept | Raise it through the session configuration; it can't be lowered |
| ``RedirectHandler/secure``: an `https` to `http` redirect fails; `Authorization`, `Proxy-Authorization` and `Cookie` are stripped on a redirect to another origin and kept on the same origin; a cross-origin 307 or 308 with a body is not followed | `URLSessionNetworkService(redirectHandler: .follow)` |
| A data or upload response over 64 MB fails with `URLError.dataLengthExceedsMaximum` | `URLSessionNetworkService(maximumResponseSize: nil)` |
| A data or upload request ends after 300 s with `URLError.timedOut`, response included; streams, WebSockets and downloads are exempt. The configuration's `timeoutIntervalForResource` is kept as given, and a value you set applies to every task | `URLSessionNetworkService(maximumRequestDuration: nil)`, or a different duration |
| ``AsyncLineSequence`` lines are capped at 1 MB; a ``ServerSentEvent``'s data at 1 MB, and its `retry` at 1 hour | ``AsyncLineSequence/init(_:maximumLineLength:)``, ``ServerSentEventSequence/init(_:maximumDataLength:)`` |
| A stream or WebSocket fails when its consumer falls 8 MB, or 1,000 WebSocket messages, behind | None |
| Header names must be RFC 9110 tokens, and values must not hold control characters other than tab; forms nest at most 32 levels; multipart boundaries and MIME types are checked | None; the request fails with ``HTTPRequestError/encodingFailed(_:)`` |
| The request line never holds a raw control character: CR, LF, NUL and the rest of U+0000 to U+001F and U+007F in a path or query value are sent percent-encoded (`%0D%0A`), so a value cannot split the request or forge a header, and a newline in a query value still reaches the server intact | None |
| A `Retry-After` wait over 60 s is not retried, and a malformed one is ignored | ``RetryPolicy/maximumRetryAfter`` |
| A response to a request with `Authorization` never goes into `URLCache`; the disk cache is excluded from backups and file-protected | None |
| ``NetworkLogger`` is on in DEBUG builds only, and redacts credentials | ``Netti/isLoggingEnabled`` |

A name marks a credential, and its value is redacted in logs, ``HTTPHeaders`` descriptions and ``HTTPRequestError`` descriptions, when it contains `auth`, `token`, `key`, `secret`, `session`, `cookie`, `password`, `passwd`, `pwd`, `signature`, `credential` or `otp`, when one of its words is `sig` or `pin`, or when it is `code`. See <doc:Observability>.

### Opt into more

Send an `Idempotency-Key` with every `POST` and `PATCH`, so ``RetryPolicy`` can retry them safely. The key is the same on every retry of one call; your server must honour it:

```swift
netti.interceptors.append(.idempotencyKey)
```

Send the token only to your own API, never to a presigned upload URL or a CDN:

```swift
AuthenticationInterceptor(bearerToken: token, hosts: ["api.example.com"]) { _ in try await refreshToken() }
```

Pin your servers' keys or certificates; see <doc:CertificatePinning>.

### Your app's responsibilities

- Call ``Netti/clearCache()`` on logout. The offline cache key doesn't include the credential, so the next user can otherwise be served the previous user's cached responses.
- Move or delete a finished download's `fileURL`. Until you do, it stays in the temporary directory.
- Treat ``HTTPDownloadResponse/resumeData`` as a secret: it embeds the original request, `Authorization` included. Keep it in the Keychain if you persist it.
- Set `hosts:` on ``AuthenticationInterceptor`` when the client talks to hosts that aren't yours.
- Keep App Transport Security on. Netti's TLS floor and downgrade refusal add to ATS; they can't undo an ATS exception your app declares.
- Treat your ``EventMonitor`` types as trusted code: they see requests with their credentials.

## Topics

### Opt-in protections

- ``IdempotencyKeyAdapter``
- ``AuthenticationInterceptor``
- ``ServerTrustPolicy``

### Defaults you can tune

- ``RedirectHandler``
- ``RetryPolicy``
- ``NetworkLogger``
