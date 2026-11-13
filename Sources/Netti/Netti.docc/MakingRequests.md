# Making Requests

Send any HTTP verb with a query or a JSON body, read the response, and drop down to `URLRequest` when you need to.

## Overview

``Netti`` has one method per verb. Each takes an ``HTTPRequest`` endpoint, throws ``HTTPRequestError``, and returns an ``HTTPResponse``:

| Method | Parameters go in | Notes |
|---|---|---|
| `get(_:query:)` | the URL query | |
| ``Netti/head(_:query:)`` | the URL query | Returns `HTTPResponse<Empty>` only |
| `delete(_:query:)` | the URL query | |
| `options(_:)` | none | |
| `post(_:body:)`, `put(_:body:)`, `patch(_:body:)` | the JSON body | |

`query` and `body` are optional and take any `Encodable & Sendable` value.

### Decode a response

Name the type you expect, either on the response or on its ``HTTPResponse/data``:

```swift
let users: [User]? = try await netti.get(UserAPI.users).data
let response: HTTPResponse<User> = try await netti.put(UserAPI.user(42), body: UserPatch(name: "Ada"))
```

When nothing names a type, the overload that returns `HTTPResponse<Empty>` is chosen, and it ignores the body. That is what you want for a call whose response you discard:

```swift
try await netti.delete(UserAPI.user(42))
try await netti.post(UserAPI.users, body: NewUser(name: "Ada"))
```

The `Empty` overload still keeps the undecoded body in ``HTTPResponse/rawData``, which is how you read a non-JSON payload:

```swift
let csv: Data? = try await netti.get(UserAPI.users).rawData
```

``HTTPResponse`` also carries the sent `request`, the `HTTPURLResponse`, its ``HTTPResponse/statusCode`` and the task ``HTTPResponse/metrics``.

### Send a query

Query keys follow the client's ``JSONManager`` key strategy, `snake_case` by default, like body keys. Everything else uses the ``URLEncodedFormEncoder`` defaults: arrays without brackets (`id=1&id=2`), bools as `true`/`false`, dates as `yyyy-MM-dd'T'HH:mm:ss.SSSZ` (the ``JSONManager`` default), keys sorted, and RFC 3986 escaping (`+` included). Query items already in the endpoint's URL are kept.

```swift
struct UserFilter: Encodable, Sendable {
    let ids: [Int]
    let isActive: Bool
}

let users: [User]? = try await netti.get(UserAPI.users, query: UserFilter(ids: [1, 2], isActive: true)).data
// GET https://api.example.com/v1/users?ids=1&ids=2&is_active=true
```

With `snake_case`, a key that starts with an acronym keeps it together: `URLValue` becomes `url_value` and `ID` becomes `id`, in the query and in a JSON body alike. Apart from keys, the verbs always use the default strategies. For brackets, numeric bools or another date format, build the request yourself and send it as shown in <doc:MakingRequests#Send-a-prebuilt-request>.

### Send a body

Bodies are encoded straight from `Encodable` to JSON with the client's ``JSONManager``, so top-level arrays work and `Decimal` keeps its digits. `Content-Type: application/json` is set unless the endpoint sets another one.

```swift
let created: [User]? = try await netti.post(UserAPI.users, body: [NewUser(name: "Ada"), NewUser(name: "Grace")]).data
```

### Set headers, timeouts and sample data

Headers come from the endpoint's ``HTTPRequest/headers``. ``HTTPHeaders`` keeps order, ignores case, and has helpers for common headers:

```swift
var headers: HTTPHeaders {
    [.accept("application/json"), .authorization(bearerToken: token), .userAgent("MyApp/1.0")]
}
```

For headers every request needs, such as a token, use an interceptor instead; see <doc:InterceptorsAndRetry>. The other per-endpoint knobs are optional requirements of ``HTTPRequest``:

- ``HTTPRequest/timeoutInterval``: 60 seconds by default.
- ``HTTPRequest/sampleData``: when set, the verbs decode it in place of sending the request, which helps with previews and prototypes.
- ``HTTPRequest/cachePolicy``, ``HTTPRequest/validation`` and ``HTTPRequest/retryPolicy``: see <doc:CachingAndOffline>, <doc:ValidationAndErrors> and <doc:InterceptorsAndRetry>.

### Send a prebuilt request

`send(_:)` sends any `URLRequest` through the same pipeline: interceptors, retry, validation, monitoring and decoding apply, but caching and sample data do not. Use it for methods without a verb, such as `TRACE`, or for custom encoding. ``Netti/buildRequest(_:parameters:method:)`` builds an endpoint's request with the client's encoders, without sending it:

```swift
let trace = try netti.buildRequest(UserAPI.users, method: .trace)
try await netti.send(trace)

let brackets = URLEncodedFormParameterEncoder(encoder: URLEncodedFormEncoder(arrayEncoding: .brackets))
let request = try brackets.encode(["ids": [1, 2]], into: UserAPI.users.asURLRequest(for: .get))
let users: [User]? = try await netti.send(request).data
// GET https://api.example.com/v1/users?ids[]=1&ids[]=2, with the brackets percent-escaped
```

A URL-encoded form body works the same way, with `URLEncodedFormParameterEncoder(destination: .httpBody)`.

### Decode data you already have

``Netti/decode(_:request:)`` turns raw JSON into a response with the client's ``JSONManager``, without any network exchange:

```swift
let fixture = Data(#"{"id": 1, "name": "Ada"}"#.utf8)
let user: User? = try netti.decode(fixture, request: nil).data
```

### Choose an engine

``URLSessionNetworkService`` is the default engine. Pass your own instance to configure the session, server trust, redirects, the response size cap or the connection limit per host:

```swift
let netti = Netti(service: URLSessionNetworkService(
    configuration: .ephemeral,
    redirectHandler: .doNotFollow,
    maxConnectionsPerHost: 4
))
```

Without a redirect handler, the engine uses ``RedirectHandler/secure``: it refuses an `https` to `http` redirect, drops `Authorization`, `Proxy-Authorization` and `Cookie` on a redirect to another origin, and doesn't follow a cross-origin 307 or 308 that would re-send a body. ``RedirectHandler/doNotFollow`` returns every redirect response as is; ``RedirectHandler/follow`` follows every redirect unchanged and is the explicit opt-out of those protections. See <doc:Security>.

Any type conforming to ``NetworkService`` can be an engine. It only moves bytes; encoding, interceptors, validation, retry, caching and decoding stay in ``Netti``.
