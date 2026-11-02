# Testing

Test code that uses Netti without touching the network, with the `NettiTesting` product.

## Overview

`NettiTesting` is a separate library product. Add it to test targets only. It re-exports `Netti`, so `import NettiTesting` is enough in a test file. It provides:

- `StubServer`: an in-process server for one test. It answers from stubs and records every request.
- `StubNetworkService`: a closure-based engine for streams, downloads and WebSockets, or for asserting what reaches the engine.
- `StubWebSocketTransport` and `StubConnectivity`: an in-memory WebSocket and a connectivity source you set by hand.

Because your code receives a ``Netti`` instance, a test can hand it a stubbed client instead of a real one.

### Stub a response

Create one `StubServer` per test, register stubs, and use the client it returns:

```swift
import Testing
import NettiTesting

@Test func loadsUser() async throws {
    let server = StubServer()
    server.stub(.get, "https://api.example.com/v1/users/42", json: User(id: 42, name: "Ada"))

    let user: User? = try await server.netti().get(UserAPI.user(42)).data

    #expect(user?.name == "Ada")
    #expect(server.requests.count == 1)
}
```

In a real test file, also `@testable import` your app module to reach its endpoints and models.

- `stub(_:_:status:headers:body:delay:times:)` answers with raw bytes, `stub(_:_:json:status:headers:delay:times:)` with a value encoded by the server's ``JSONManager``, and `stub(_:_:error:delay:times:)` with a failure. A `URLError` surfaces as ``HTTPRequestError/requestFailed(_:)`` with the same code.
- A stub URL without a query matches that path with any query; one with a query matches only those items.
- The most recently registered matching stub wins. `times:` lets a stub answer that many requests before an older one takes over.
- A request with no matching stub fails with a `URLError` that reads `No stub registered for GET <url>`. Nothing ever reaches the network.

Every server has its own stubs and recordings, so tests that run in parallel never see each other's stubs, even for the same URL.

### Inspect what was sent

`server.requests` lists every request in arrival order, including requests that matched no stub. Each entry has the `method`, `url`, `headers` and `body`, and decodes the body with `decodedBody(as:)`:

```swift
@Test func postsNewUser() async throws {
    let server = StubServer()
    server.stub(.post, "https://api.example.com/v1/users", status: 201)

    try await server.netti().post(UserAPI.users, body: NewUser(name: "Ada"))

    let sent = try #require(server.requests.first)
    #expect(sent.method == "POST")
    #expect(try sent.decodedBody(as: NewUser.self).name == "Ada")
}
```

### Test retries, validation and interceptors

`server.netti(...)` takes the interceptors, retry policy, validation and monitors you would set on the real client. Retry delays are not waited out, so retry tests run instantly:

```swift
@Test func retriesUnavailableServer() async throws {
    let server = StubServer()
    let url = "https://api.example.com/v1/users/42"
    server.stub(.get, url, json: User(id: 42, name: "Ada"))
    server.stub(.get, url, status: 503, times: 2)

    let response: HTTPResponse<User> = try await server.netti(retryPolicy: RetryPolicy()).get(UserAPI.user(42))

    #expect(response.statusCode == 200)
    #expect(server.requests.count == 3)
}
```

The client from `server.netti(...)` has its own empty cache, no logging, and a connected network. To build your own client, use `server.service()` as the engine, or `server.configuration` for your own session.

### Test redirects

`redirect(_:from:to:status:times:)` answers with a redirect status and a `Location` header, so the engine's ``RedirectHandler`` makes the real decision, offline. Stub the target as well, to answer the request that follows. A client from `server.netti(...)` uses the default engine, so build your own on `server.configuration` to choose the handler:

```swift
@Test func customHandlerFollowsOnlyTheSameHost() async throws {
    let server = StubServer()
    server.redirect(.get, from: "https://api.example.com/v1/users", to: "https://api.example.com/v2/users")
    server.redirect(.get, from: "https://api.example.com/v1/users/2", to: "https://cdn.example.net/users/2")
    server.stub(.get, "https://api.example.com/v2/users", json: [User(id: 1, name: "Ada")])

    let sameHostOnly = RedirectHandler { proposed, response in
        guard proposed.url?.host == response.url?.host else {
            return .doNotFollow
        }
        var request = proposed
        request.setValue("followed", forHTTPHeaderField: "X-Redirect")
        return .modify(request)
    }
    let netti = Netti(service: URLSessionNetworkService(configuration: server.configuration, redirectHandler: sameHostOnly))
    netti.isLoggingEnabled = false

    let users: [User]? = try await netti.get(UserAPI.users).data
    #expect(users?.count == 1)
    #expect(server.requests.last?.headers["X-Redirect"] == "followed")

    let blocked: HTTPResponse<Empty> = try await netti.get(UserAPI.user(2))
    #expect(blocked.statusCode == 302)
}
```

- `status:` defaults to `302`; `method:` defaults to `.get`. The stub matches the method of the request that is redirected, and `times:` limits how many requests it redirects before an older stub takes over. `redirect` traps unless `status` is `301`, `302`, `303`, `307` or `308` and `to` is an absolute URL.
- A `301`, `302` or `303` is followed as a `GET` without a body, as `URLSession` does. A `307` or `308` keeps the method and body.
- `URLSession` drops `Authorization` from the followed request, and the handler decides whether it comes back. `Examples/Redirects.swift` reads `server.requests` to show `.secure` keeping it on the same origin and dropping it on another.
- A redirect loop fails once `URLSession` reaches its limit of 16 redirects.

### Test offline behavior

Pass a `StubConnectivity` and change it during the test. This example uses an endpoint whose ``HTTPRequest/cachePolicy`` is ``HTTPCachePolicy/cache``:

```swift
@Test func servesCachedRidesOffline() async throws {
    let server = StubServer()
    server.stub(.get, "https://api.example.com/v1/rides", json: [Ride(id: 1)])
    let connectivity = StubConnectivity(.connected)
    let netti = server.netti(connectivity: connectivity)

    let _: HTTPResponse<[Ride]> = try await netti.get(RideAPI.history)
    connectivity.set(.disconnected)
    server.reset()

    let rides: [Ride]? = try await netti.get(RideAPI.history).data
    #expect(rides?.count == 1)
    #expect(server.requests.isEmpty)
}
```

### Test streams and WebSockets

`StubServer` cannot fake streams or WebSockets. Use `StubNetworkService`, whose handlers answer each kind of call. Every handler has a default, so replace only the one the test needs:

```swift
@Test func sendsAndReceivesChat() async throws {
    let socket = StubWebSocketTransport(echoes: false)
    let netti = Netti(service: StubNetworkService(webSocket: { _ in socket }))
    netti.isLoggingEnabled = false

    let connection = try await netti.webSocket(ChatAPI.room(7))
    try await connection.send("hello")
    socket.receive(.text(#"{"text": "hi"}"#))
    socket.serverClose()

    var received: [ChatMessage] = []
    for try await message in connection.messages(as: ChatMessage.self) {
        received.append(message)
    }
    #expect(socket.sent == [.text("hello")])
    #expect(received.map(\.text) == ["hi"])
}

@Test func parsesServerSentEvents() async throws {
    let service = StubNetworkService(bytes: { request in
        HTTPStreamResponse(
            request: request,
            response: HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: nil, headerFields: nil),
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data("data: hello\n\n".utf8))
                continuation.finish()
            }
        )
    })
    let netti = Netti(service: service)
    netti.isLoggingEnabled = false

    var events: [String] = []
    for try await event in try await netti.stream(FeedAPI.live).serverSentEvents {
        events.append(event.data)
    }
    #expect(events == ["hello"])
}
```

`StubNetworkService` records `requests`, `uploads`, `downloads` and `webSocketRequests`. `HTTPResponse.stub(for:status:headers:body:metrics:)` and `HTTPResponse.json(for:status:_:encoder:)` build responses for its `data` handler. Note that a ``Netti`` built directly on it uses the shared ``NetworkMonitor`` and the default disk cache, unlike `server.netti(...)`.
