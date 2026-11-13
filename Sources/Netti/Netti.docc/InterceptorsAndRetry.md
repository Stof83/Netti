# Interceptors & Retry

Change every request before it is sent, refresh credentials before they expire or when the server rejects them, and retry transient failures.

## Overview

Set interceptors and a retry policy on the client. Both are off by default:

```swift
let auth = AuthenticationInterceptor(bearerToken: token) { rejected in
    try await refreshToken(rejected)
}
let netti = Netti()
netti.interceptors = [auth]
netti.retryPolicy = RetryPolicy()
```

For every attempt, the pipeline runs these steps:

1. Every adapter runs in order. A retried request is adapted again, so it picks up a refreshed credential.
2. The engine sends the request.
3. Validation runs, if any is configured.
4. If the attempt threw, failed validation or returned a non-2xx status, the retriers are asked whether to send it again. The interceptors are asked first, in order, then the retry policy. The first that asks for a retry wins.

### Adapt requests

A ``RequestInterceptor`` adapts requests, decides retries, or both. Each requirement has a pass-through default, so implement only what you need:

```swift
struct AppHeadersInterceptor: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("ios/5.0", forHTTPHeaderField: "X-Client")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "Accept-Language")
        return request
    }
}

let netti = Netti()
netti.interceptors = [AppHeadersInterceptor()]
```

An adapter that throws stops the request before any network traffic. Its error reaches the caller as an ``HTTPRequestError``.

### Refresh credentials

``AuthenticationInterceptor`` sets a credential on every request and refreshes it when it expires. Its `refresh` closure is the only place your app handles an expired token. For a bearer token, build an ``AuthToken`` from your login or refresh response:

```swift
let token = AuthToken(accessToken: login.accessToken, refreshToken: login.refreshToken, expiresIn: .seconds(login.expiresIn))
let auth = AuthenticationInterceptor(token: token, hosts: ["api.example.com"]) { expired in
    try await authAPI.refresh(using: expired.refreshToken)
}
let netti = Netti()
netti.interceptors = [auth]
```

``AuthToken/init(accessToken:refreshToken:expiresAt:)`` takes a date instead of a lifetime. The token goes out as `Authorization: Bearer <accessToken>`, and only to the hosts in `hosts:`; without it, every host the client calls receives it. An ``AuthToken``'s description shows only ``AuthToken/expiresAt``, so logging one never leaks a token.

`refresh` runs in two cases:

- **Before sending**, when the token is expired. With ``AuthenticationInterceptor/init(token:hosts:excluding:refreshLeeway:isRejected:refresh:)``, that is when ``AuthToken/expiresAt`` is less than `refreshLeeway` away, 30 s by default. For a token that lives less than twice the leeway, the leeway is cut to half its life, so a fresh token never counts as expired. A token without an expiry date is refreshed only in the second case.
- **After a response**, when `isRejected` says the server refused the token. By default that is any `401`. ``RetryContext/failureResponse`` holds the response, whether it was returned or carried by the error, so `isRejected` can read the body:

```swift
let auth = AuthenticationInterceptor(
    token: token,
    isRejected: { context in
        guard context.statusCode == 401, let body = context.failureResponse?.rawData else {
            return false
        }
        return String(decoding: body, as: UTF8.self).contains("TOKEN_EXPIRED")
    },
    refresh: { expired in try await authAPI.refresh(using: expired.refreshToken) }
)
```

A backend that signals an expired token with a `419` passes `isRejected: { $0.statusCode == 419 }`.

However many requests hit either case at once, the token is refreshed once: the first request starts the refresh, the others wait for it, and each one is then sent, or sent again, with the new token. A request is retried at most once. A request whose token isn't expired goes out at once, without waiting for a refresh that a rejection started.

When the refresh throws:

- If it started because the token was expired, every waiting request fails with the refresh's error, so none is sent with a token known to be expired. An ``HTTPRequestError`` reaches the caller as thrown; any other error becomes ``HTTPRequestError/requestFailed(_:)`` with the original as its underlying error.
- If it started because of a rejected response, the waiting requests aren't retried and return the response they received.

Either way, the next request that needs a refresh starts a new one.

A request that already has its own `Authorization` header is left alone. HTTP Basic on a login or sign-up call to the same host keeps its credentials, and the interceptor neither replaces them nor refreshes the token when that call returns a `401`, since none of its credentials were sent:

```swift
struct LoginAPI: HTTPRequest {
    let username: String
    let password: String

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String { "login" }
    var headers: HTTPHeaders { [.authorization(username: username, password: password)] }
}
```

Every attempt adapts the original request, so a header found on it was never the interceptor's. The rule holds for every credential type, not only bearer tokens.

Sign-in, sign-up and refresh endpoints answer `401` for bad credentials, not for an expired session. List them in `excluding`, which every initializer takes: an excluded request carries no token, never waits for a refresh, and its `401` is returned as received.

```swift
AuthenticationInterceptor(token: session.token, excluding: [AuthAPI.signIn, AuthAPI.signUp, AuthAPI.refresh]) { expired in
    try await authAPI.refresh(using: expired.refreshToken)
}
```

A request matches an excluded endpoint on the host, port and path of its ``HTTPRequest/requestURL``; the scheme, query and HTTP method are ignored. Don't exclude a refresh endpoint that expects the expired token in `Authorization`: a request sent from the refresh closure already never triggers a refresh.

After a login, a logout or an account switch, replace the token with ``AuthenticationInterceptor/setCredential(_:)``. A refresh in flight is superseded: its result is discarded, so the previous session's renewal never overwrites the token you set, and the requests waiting for it after a rejection return their response as received.

```swift
await auth.setCredential(AuthToken(accessToken: newLogin.accessToken, refreshToken: newLogin.refreshToken, expiresIn: .seconds(newLogin.expiresIn)))
```

The refresh may send its request through the same client. A request sent while refreshing is never retried, so a `401` on it is returned to the refresh closure instead of waiting for its own refresh. Requests sent from `Task.detached` inside the closure are not recognized as part of the refresh.

For a credential other than a bearer token, say how it is set on a request, and optionally when it is expired. `apply` must *set* the value, never append to it:

```swift
let auth = AuthenticationInterceptor(
    credential: "api-key",
    apply: { key, request in request.setValue(key, forHTTPHeaderField: "X-API-Key") },
    refresh: { rejected in try await refreshToken(rejected) }
)
```

``AuthenticationInterceptor/init(credential:hosts:excluding:isExpired:isRejected:apply:refresh:)`` checks `isExpired` before every request; it must be cheap and free of side effects. ``AuthenticationInterceptor/init(bearerToken:hosts:excluding:refresh:)`` takes a plain `String` token with no expiry date.

`Examples/Authentication.swift` runs each case offline: an expired token, a backend body code, twenty parallel requests sharing one refresh, and login and logout. Run it with `swift run NettiExamples`; `EXAMPLES.md` at the root of the repository walks through it.

### Retry transient failures

``RetryPolicy`` with its defaults retries:

- at most 2 times;
- only idempotent methods: `GET`, `HEAD`, `PUT`, `DELETE`, `OPTIONS` and `TRACE`, never `POST` or `PATCH`;
- only after a transient connection error (time-out, lost connection, no connection, host unreachable, DNS failure) or a `408`, `429`, `500`, `502`, `503` or `504` status;
- after a random delay between zero and 0.5 s × 2ⁿ for retry *n* (full jitter), or after the delay in the response's `Retry-After` header when there is one.

Every value can be changed:

```swift
let netti = Netti()
netti.retryPolicy = RetryPolicy(
    maxRetries: 4,
    baseDelay: .seconds(1),
    retryableMethods: [.get, .post],
    retryableStatusCodes: [503]
)
```

When every retry is spent, the call throws ``HTTPRequestError/retryLimitExceeded(attempts:lastError:)``, even for a status the client would otherwise return, such as a `503`. `lastError` is the final failure; for a status it is ``HTTPRequestError/unacceptableStatusCode(_:response:)``. A request that is never retried returns or throws exactly as it would without a policy.

### Override retry per endpoint

An endpoint's ``HTTPRequest/retryPolicy`` replaces the client's policy, and ``RetryPolicy/disabled`` opts out:

```swift
enum CheckoutAPI: HTTPRequest {
    case pay

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String { "payments" }
    var headers: HTTPHeaders { [.accept("application/json")] }
    var retryPolicy: RetryPolicy? { .disabled }
}
```

### Write a retrier

Any ``RequestInterceptor`` can decide retries. The ``RetryContext`` holds the request as sent, the response or error, and how many retries have already happened. Return a ``RetryDecision``:

```swift
struct ReconnectRetrier: RequestInterceptor {
    func retry(_ context: RetryContext) async -> RetryDecision {
        guard case .requestFailed(let error) = context.error,
              error.code == .networkConnectionLost,
              context.retryCount < 1 else {
            return .doNotRetry
        }
        return .retryAfter(.seconds(2))
    }
}
```

A separate ``RequestAdapter`` or ``RequestRetrier`` can be combined into one interceptor with ``CompositeInterceptor``.

Retry delays are observable through ``EventMonitor/requestWillRetry(_:retryCount:delay:)``; see <doc:Observability>. WebSocket handshakes are adapted but never retried.
