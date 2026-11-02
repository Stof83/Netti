//
//  StubServer.swift
//  NettiTesting
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation
import os

/// An in-process server for one test: it answers requests from stubs and records every request.
///
/// Create one per test. Its stubs and recordings belong to it alone, so tests that run in
/// parallel never see each other's stubs, even for the same URL.
///
/// ```swift
/// let server = StubServer()
/// server.stub(.get, "https://api.example.com/users", json: [User(id: 1)])
///
/// let users: [User]? = try await server.netti().get(UserAPI.list).data
/// #expect(server.requests.count == 1)
/// ```
///
/// A request with no matching stub fails with a `URLError` whose description reads
/// `No stub registered for GET https://…`. No request ever reaches the network.
public final class StubServer: Sendable {

    // MARK: - Properties

    /// Encodes `json:` stubs and decodes recorded bodies; the clients it makes use it too, so
    /// stubs and clients always agree on key strategy and dates.
    public let jsonManager: JSONManager

    let storage = StubStorage()
    private let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("netti-testing-\(UUID().uuidString)", isDirectory: true)

    // MARK: - Initialization

    /// Creates a server with no stubs.
    ///
    /// - Parameter jsonManager: Encodes `json:` stubs and decodes recorded bodies. Defaults to
    ///   `JSONManager()`, the same default as ``Netti``.
    public init(jsonManager: JSONManager = .init()) {
        self.jsonManager = jsonManager
        StubURLProtocol.register(storage)
    }

    deinit {
        StubURLProtocol.unregister(storage)
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: - Stubbing

    /// Stubs a response.
    ///
    /// The most recently registered stub that matches wins. A `url` that is not absolute stops the
    /// test with a precondition failure. A `url` without a query matches that
    /// path with any query string; a `url` with a query matches only that exact set of items.
    ///
    /// ```swift
    /// server.stub(.post, "https://api.example.com/users", status: 201)
    /// ```
    ///
    /// - Parameters:
    ///   - method: The HTTP method. `.get` by default.
    ///   - url: The absolute URL.
    ///   - status: The status code. `200` by default.
    ///   - headers: The response headers.
    ///   - body: The response body.
    ///   - delay: How long to wait before answering. No delay by default.
    ///   - times: How many requests the stub answers before an older stub takes over. Unlimited by default.
    public func stub(
        _ method: HTTPMethod = .get,
        _ url: String,
        status: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data(),
        delay: Duration? = nil,
        times: Int? = nil
    ) {
        storage.add(method: method, url: url, outcome: .response(status: status, headers: headers, body: body), delay: delay, times: times)
    }

    /// Stubs a JSON response, encoded with ``jsonManager``.
    ///
    /// ```swift
    /// server.stub(.get, "https://api.example.com/users/1", json: User(id: 1))
    /// ```
    ///
    /// - Parameters:
    ///   - method: The HTTP method. `.get` by default.
    ///   - url: The absolute URL.
    ///   - json: The value to encode as the body. `Content-Type` is set to `application/json`.
    ///   - status: The status code. `200` by default.
    ///   - headers: More response headers.
    ///   - delay: How long to wait before answering. No delay by default.
    ///   - times: How many requests the stub answers before an older stub takes over. Unlimited by default.
    public func stub(
        _ method: HTTPMethod = .get,
        _ url: String,
        json: some Encodable,
        status: Int = 200,
        headers: [String: String] = [:],
        delay: Duration? = nil,
        times: Int? = nil
    ) {
        let body: Data
        do {
            body = try jsonManager.encode(json)
        } catch {
            preconditionFailure("StubServer could not encode the JSON stub for \(url): \(error)")
        }
        stub(method, url, status: status, headers: ["Content-Type": "application/json"].merging(headers) { _, new in new }, body: body, delay: delay, times: times)
    }

    /// Stubs a transport failure.
    ///
    /// ```swift
    /// server.stub(.get, "https://api.example.com/users", error: URLError(.notConnectedToInternet))
    /// ```
    ///
    /// - Parameters:
    ///   - method: The HTTP method. `.get` by default.
    ///   - url: The absolute URL.
    ///   - error: The failure the request ends with. A `URLError` surfaces as
    ///     ``HTTPRequestError/requestFailed(_:)`` with the same code.
    ///   - delay: How long to wait before failing. No delay by default.
    ///   - times: How many requests the stub fails before an older stub takes over. Unlimited by default.
    public func stub(
        _ method: HTTPMethod = .get,
        _ url: String,
        error: any Error,
        delay: Duration? = nil,
        times: Int? = nil
    ) {
        storage.add(method: method, url: url, outcome: .failure(error), delay: delay, times: times)
    }

    /// Stubs a redirect.
    ///
    /// The server answers with `status` and a `Location` header. A client built on
    /// ``configuration`` hands that redirect to its ``RedirectHandler``, which decides whether
    /// to follow it, so a stub for `to` answers the second request.
    ///
    /// ```swift
    /// server.redirect(.get, from: "https://api.example.com/v1/users", to: "https://api.example.com/v2/users")
    /// server.stub(.get, "https://api.example.com/v2/users", json: [User(id: 1)])
    /// ```
    ///
    /// A `301`, `302` or `303` is followed with `GET` and no body, as `URLSession` does; a `307`
    /// or `308` keeps the method and body. `URLSession` drops `Authorization` from the followed
    /// request, and the handler decides whether it comes back.
    ///
    /// - Parameters:
    ///   - method: The HTTP method of the request that is redirected. `.get` by default.
    ///   - url: The absolute URL that redirects.
    ///   - target: The absolute URL the redirect points to.
    ///   - status: The redirect status: `301`, `302`, `303`, `307` or `308`. `302` by default.
    ///   - times: How many requests the stub redirects before an older stub takes over. Unlimited by default.
    public func redirect(
        _ method: HTTPMethod = .get,
        from url: String,
        to target: String,
        status: Int = 302,
        times: Int? = nil
    ) {
        precondition([301, 302, 303, 307, 308].contains(status), "StubServer needs a redirect status (301, 302, 303, 307 or 308), got \(status)")
        guard let location = URL(string: target), location.host != nil else {
            preconditionFailure("StubServer needs an absolute redirect target, got \"\(target)\"")
        }
        storage.add(method: method, url: url, outcome: .redirect(status: status, location: location), delay: nil, times: times)
    }

    // MARK: - Inspection

    /// Every request received, in arrival order, including those that matched no stub.
    public var requests: [RecordedRequest] {
        storage.requests.map { RecordedRequest(request: $0.request, body: $0.body, jsonManager: jsonManager) }
    }

    /// Removes every stub and every recorded request.
    public func reset() {
        storage.reset()
    }

    // MARK: - Clients

    /// A session configuration whose requests this server answers.
    ///
    /// Use it to build your own `URLSession` or ``URLSessionNetworkService``.
    public var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.serverHeader: storage.id]
        return configuration
    }

    /// An engine whose requests this server answers.
    ///
    /// - Returns: A new ``URLSessionNetworkService`` built on ``configuration``.
    public func service() -> URLSessionNetworkService {
        URLSessionNetworkService(configuration: configuration)
    }

    /// A client whose requests this server answers.
    ///
    /// The client has its own empty cache, no logging, and a connected network. Retry delays are
    /// not waited out, so retry tests run instantly; observe them through a monitor.
    ///
    /// ```swift
    /// let netti = server.netti(retryPolicy: RetryPolicy(maxRetries: 3))
    /// ```
    ///
    /// - Parameters:
    ///   - interceptors: Adapt every request and decide retries.
    ///   - retryPolicy: Retries transient failures. `nil`, the default, never retries.
    ///   - validation: Rejects unacceptable responses. `nil`, the default, returns every response.
    ///   - monitors: Observe every request.
    ///   - connectivity: The network state. Defaults to a connected ``StubConnectivity``.
    ///   - deduplicatesRequests: Whether concurrent identical `GET` and `HEAD` requests share one transfer.
    /// - Returns: A new client backed by ``service()`` and this server's ``jsonManager``.
    public func netti(
        interceptors: [any RequestInterceptor] = [],
        retryPolicy: RetryPolicy? = nil,
        validation: ResponseValidation? = nil,
        monitors: [any EventMonitor] = [],
        connectivity: any ConnectivitySource = StubConnectivity(),
        deduplicatesRequests: Bool = true
    ) -> Netti {
        Netti(
            service: service(),
            jsonManager: jsonManager,
            interceptors: interceptors,
            retryPolicy: retryPolicy,
            validation: validation,
            monitors: monitors,
            connectivity: connectivity,
            deduplicatesRequests: deduplicatesRequests,
            cacheDirectory: cacheDirectory,
            sleep: { _ in await Task.yield() }
        )
    }
}

// MARK: - RecordedRequest

/// A request a ``StubServer`` received.
public struct RecordedRequest: Sendable {

    /// The request as it arrived, with its body in `httpBody`.
    public let request: URLRequest

    /// The body, `nil` when the request had none.
    public let body: Data?

    private let jsonManager: JSONManager

    init(request: URLRequest, body: Data?, jsonManager: JSONManager) {
        self.request = request
        self.body = body
        self.jsonManager = jsonManager
    }

    /// The HTTP method.
    public var method: String {
        request.httpMethod ?? HTTPMethod.get.rawValue
    }

    /// The URL, query included.
    public var url: URL? {
        request.url
    }

    /// The request headers.
    public var headers: [String: String] {
        request.allHTTPHeaderFields ?? [:]
    }

    /// Decodes the body as JSON with the server's ``StubServer/jsonManager``.
    ///
    /// ```swift
    /// let sent: NewUser = try server.requests[0].decodedBody()
    /// ```
    ///
    /// - Parameter type: The type to decode. Inferred from the context by default.
    /// - Returns: The decoded body.
    /// - Throws: `DecodingError`, including when the request had no body.
    public func decodedBody<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try jsonManager.decode(type, from: body)
    }
}

// MARK: - Storage

/// The stubs and recordings of one ``StubServer``, shared with ``StubURLProtocol`` by ID.
final class StubStorage: Sendable {

    enum Outcome: Sendable {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(any Error)
        case redirect(status: Int, location: URL)
    }

    struct Stub: Sendable {
        let method: String
        let components: URLComponents
        let outcome: Outcome
        let delay: Duration?
        var remaining: Int?

        func matches(method: String, url: URL) -> Bool {
            guard self.method == method, let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return false
            }
            guard Self.normalized(candidate) == Self.normalized(components) else {
                return false
            }
            guard let items = components.queryItems, items.isEmpty == false else {
                return true
            }
            return Set(items.map(Self.pair)) == Set((candidate.queryItems ?? []).map(Self.pair))
        }

        private static func normalized(_ components: URLComponents) -> [String?] {
            let path = components.path.hasSuffix("/") && components.path.count > 1 ? String(components.path.dropLast()) : components.path
            return [components.scheme?.lowercased(), components.host?.lowercased(), components.port.map(String.init), path]
        }

        private static func pair(_ item: URLQueryItem) -> String {
            "\(item.name)=\(item.value ?? "")"
        }
    }

    struct Received: Sendable {
        let request: URLRequest
        let body: Data?
    }

    private struct State {
        var stubs: [Stub] = []
        var received: [Received] = []
    }

    let id = UUID().uuidString
    private let state = OSAllocatedUnfairLock(initialState: State())

    var requests: [Received] {
        state.withLock { $0.received }
    }

    func add(method: HTTPMethod, url: String, outcome: Outcome, delay: Duration?, times: Int?) {
        guard let components = URLComponents(string: url), components.host != nil else {
            preconditionFailure("StubServer needs an absolute URL, got \"\(url)\"")
        }
        let stub = Stub(method: method.rawValue, components: components, outcome: outcome, delay: delay, remaining: times)
        state.withLock { $0.stubs.append(stub) }
    }

    func reset() {
        state.withLock { $0 = State() }
    }

    /// Records `request` and returns the newest stub that matches it, using up one of its `times`.
    func receive(_ request: URLRequest, body: Data?) -> Stub? {
        state.withLock { state in
            state.received.append(Received(request: request, body: body))
            guard let url = request.url else {
                return nil
            }
            let method = request.httpMethod ?? HTTPMethod.get.rawValue
            guard let index = state.stubs.lastIndex(where: { $0.matches(method: method, url: url) }) else {
                return nil
            }
            let stub = state.stubs[index]
            if let remaining = stub.remaining {
                if remaining <= 1 {
                    state.stubs.remove(at: index)
                } else {
                    state.stubs[index].remaining = remaining - 1
                }
            }
            return stub
        }
    }
}
