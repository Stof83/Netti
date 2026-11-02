# Getting Started

Add Netti to a package, describe an endpoint, and make your first request.

## Overview

Netti needs iOS 17, macOS 14, tvOS 17, watchOS 10 or Mac Catalyst 17, and a Swift 6.4 toolchain. It has no third-party dependencies.

### Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/Stof83/Netti.git", from: "3.0.0"),
],
targets: [
    .target(name: "App", dependencies: ["Netti"]),
    .testTarget(name: "AppTests", dependencies: ["App", "NettiTesting"]),
]
```

`NettiTesting` is optional. Add it to test targets only; see <doc:Testing>.

### Describe an endpoint

An endpoint is any type conforming to ``HTTPRequest``, usually an enum with one case per endpoint. Only ``HTTPRequest/baseURL``, ``HTTPRequest/basePath``, ``HTTPRequest/path`` and ``HTTPRequest/headers`` are required. Caching, validation, retry and the timeout have defaults.

```swift
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
```

The URL is `baseURL` + `basePath` + `path`. A `nil` base URL makes the request throw ``HTTPRequestError/invalidURL``.

Response and body types must be `Sendable`, because ``Netti`` runs under Swift 6 strict concurrency:

```swift
struct User: Codable, Sendable {
    let id: Int
    let name: String
}
```

### Make a request

Every argument of the client's initializer has a default, so `Netti()` is a working client. Create it once and share it. It is `Sendable`, and each client owns one `URLSession`.

```swift
let netti = Netti()

let user: User? = try await netti.get(UserAPI.user(42)).data
let created: User? = try await netti.post(UserAPI.users, body: NewUser(name: "Ada")).data
try await netti.delete(UserAPI.user(42))
```

Always annotate the type you expect. Each verb also has an overload that returns ``HTTPResponse`` with an ``Empty`` body and ignores the body. That overload wins when nothing names a type, so `let user = try await netti.get(UserAPI.user(42)).data` is `Empty?`.

By default, ``JSONManager`` decodes responses and encodes bodies with `snake_case` keys and the date format `yyyy-MM-dd'T'HH:mm:ss.SSSZ`. Query keys follow the same key strategy; query dates are ISO 8601. Set your own manager to change that:

```swift
let netti = Netti()
netti.jsonManager = JSONManager(keyStrategy: .useDefaultKeys)
```

The rest of the configuration is also a property: ``Netti/interceptors``, ``Netti/retryPolicy``, ``Netti/validation``, ``Netti/monitors``, ``Netti/isLoggingEnabled`` and ``Netti/connectivity``. Set them at any time, from any thread. Each request reads the configuration once, when it starts, so a change applies to the next request and never to one in flight.

### Read the status before the body

A non-2xx response is returned, not thrown. Its ``HTTPResponse/data`` is `nil` when the body does not decode as the requested type, and ``HTTPResponse/rawData`` keeps the bytes:

```swift
let response: HTTPResponse<User> = try await netti.get(UserAPI.user(42))
if response.statusCode == 401 {
    signOut()
} else if let user = response.data {
    show(user)
}
```

To throw on unacceptable statuses instead, set a ``ResponseValidation`` on ``Netti/validation``. See <doc:ValidationAndErrors>.

### Handle errors

Every API throws ``HTTPRequestError`` with typed throws, so a `catch` clause can match its cases directly:

```swift
do {
    let user: User? = try await netti.get(UserAPI.user(42)).data
    show(user)
} catch .requestFailed(let urlError) {
    report(urlError.code)
} catch {
    report(error)
}
```

### Next steps

- <doc:MakingRequests> covers every verb, queries, bodies and raw requests.
- <doc:InterceptorsAndRetry> adds authentication and retry.
- <doc:MigratingFrom1x> lists what changed if you used Netti 1.x.
