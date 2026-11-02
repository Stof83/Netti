//
//  Netti.swift
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation
import os

/// A networking client: one method per HTTP verb, plus uploads, downloads, streams and WebSockets.
///
/// Every common case is one line with no configuration:
///
/// ```swift
/// let netti = Netti()
/// let user: User? = try await netti.get(UserAPI.user(id)).data
/// try await netti.delete(UserAPI.user(id))
/// ```
///
/// Everything else is opt-in through properties you set at any time: interceptors, a retry policy,
/// response validation, event monitors, logging, connectivity and the JSON coder.
///
/// ```swift
/// let netti = Netti(service: URLSessionNetworkService(trustPolicy: pinning))
/// netti.interceptors = [AuthenticationInterceptor(bearerToken: token) { _ in try await refresh() }]
/// netti.retryPolicy = RetryPolicy()
/// netti.validation = ResponseValidation()
/// ```
///
/// Each request reads the configuration once, when it starts, so a change applies to the next
/// request and never to one in flight. Every request runs through one pipeline — encode, adapt,
/// send, validate, retry, cache, decode — so every feature works the same for every kind of
/// request and on every ``NetworkService``.
public final class Netti: Sendable {

    // MARK: - Types

    /// The configuration one request reads when it starts and keeps until it ends.
    struct Snapshot: Sendable {
        let jsonManager: JSONManager
        let connectivity: any ConnectivitySource
        let logger: NetworkLogger?
        let pipeline: RequestPipeline
    }

    private struct Configuration: Sendable {
        var jsonManager: JSONManager
        var interceptors: [any RequestInterceptor]
        var retryPolicy: RetryPolicy?
        var validation: ResponseValidation?
        var monitors: [any EventMonitor]
        var isLoggingEnabled: Bool
        var connectivity: any ConnectivitySource
    }

    // MARK: - Constants

    /// The logger a new client starts with: a system ``NetworkLogger`` in DEBUG builds, none in
    /// release builds, so request details never reach a shipped app's log unless asked for.
    private static var defaultLogger: NetworkLogger? {
        #if DEBUG
        NetworkLogger()
        #else
        nil
        #endif
    }

    // MARK: - Properties

    let cacheStore: HTTPCacheStore
    let deduplicator: RequestDeduplicator?
    private let service: any NetworkService
    private let logger: NetworkLogger
    private let sleep: RequestPipeline.Sleep
    private let configuration: OSAllocatedUnfairLock<Configuration>

    /// Encodes bodies and query keys, and decodes responses. Converts keys to and from `snake_case`
    /// by default.
    public var jsonManager: JSONManager {
        get { configuration.withLock { $0.jsonManager } }
        set { configuration.withLock { $0.jsonManager = newValue } }
    }

    /// Adapt every request and decide retries, in order. None by default.
    public var interceptors: [any RequestInterceptor] {
        get { configuration.withLock { $0.interceptors } }
        set { configuration.withLock { $0.interceptors = newValue } }
    }

    /// Retries transient failures. `nil`, the default, never retries; an endpoint's
    /// ``HTTPRequest/retryPolicy`` overrides it.
    public var retryPolicy: RetryPolicy? {
        get { configuration.withLock { $0.retryPolicy } }
        set { configuration.withLock { $0.retryPolicy = newValue } }
    }

    /// Rejects unacceptable responses. `nil`, the default, returns every response; an endpoint's
    /// ``HTTPRequest/validation`` overrides it.
    public var validation: ResponseValidation? {
        get { configuration.withLock { $0.validation } }
        set { configuration.withLock { $0.validation = newValue } }
    }

    /// Observe every request, in order, after the built-in logger. None by default.
    public var monitors: [any EventMonitor] {
        get { configuration.withLock { $0.monitors } }
        set { configuration.withLock { $0.monitors = newValue } }
    }

    /// Whether the built-in ``NetworkLogger`` logs requests and responses. `true` by default in
    /// DEBUG builds and `false` in release builds; set it to change that.
    public var isLoggingEnabled: Bool {
        get { configuration.withLock { $0.isLoggingEnabled } }
        set { configuration.withLock { $0.isLoggingEnabled = newValue } }
    }

    /// Decides when cached responses stand in for the network. ``NetworkMonitor/shared`` by default.
    public var connectivity: any ConnectivitySource {
        get { configuration.withLock { $0.connectivity } }
        set { configuration.withLock { $0.connectivity = newValue } }
    }

    /// The configuration as it is now, with the pipeline built from it; read it once per request.
    var snapshot: Snapshot {
        let configuration = configuration.withLock { $0 }
        let logger = configuration.isLoggingEnabled ? logger : nil
        let pipeline = RequestPipeline(
            service: service,
            interceptors: configuration.interceptors,
            retryPolicy: configuration.retryPolicy,
            validation: configuration.validation,
            monitors: (logger.map { [$0] } ?? []) + configuration.monitors,
            deduplicator: deduplicator,
            sleep: sleep
        )
        return Snapshot(
            jsonManager: configuration.jsonManager,
            connectivity: configuration.connectivity,
            logger: logger,
            pipeline: pipeline
        )
    }

    // MARK: - Initialization

    /// Creates a client.
    ///
    /// Every argument has a default, so `Netti()` is a working client. Everything else is a
    /// property you set after creating it:
    ///
    /// ```swift
    /// let netti = Netti(service: URLSessionNetworkService(trustPolicy: pinning))
    /// netti.retryPolicy = RetryPolicy()
    /// ```
    ///
    /// - Parameters:
    ///   - service: The transport engine. Defaults to a new ``URLSessionNetworkService``.
    ///   - deduplicatesRequests: Whether concurrent identical `GET` and `HEAD` requests share one transfer. `true` by default.
    ///   - cacheSizeLimit: The most bytes the response cache keeps on disk. 50 MB by default.
    public convenience init(
        service: any NetworkService = URLSessionNetworkService(),
        deduplicatesRequests: Bool = true,
        cacheSizeLimit: Int = 50 * 1024 * 1024
    ) {
        self.init(
            service: service,
            jsonManager: .init(),
            interceptors: [],
            retryPolicy: nil,
            validation: nil,
            monitors: [],
            logger: Self.defaultLogger,
            connectivity: NetworkMonitor.shared,
            deduplicatesRequests: deduplicatesRequests,
            cacheStore: HTTPCacheStore(diskCache: DiskCache(sizeLimit: cacheSizeLimit)),
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    /// Creates a client for `NettiTesting`: an isolated cache directory, an injectable retry sleep
    /// and logging off.
    package convenience init(
        service: any NetworkService,
        jsonManager: JSONManager,
        interceptors: [any RequestInterceptor],
        retryPolicy: RetryPolicy?,
        validation: ResponseValidation?,
        monitors: [any EventMonitor],
        connectivity: any ConnectivitySource,
        deduplicatesRequests: Bool,
        cacheDirectory: URL,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.init(
            service: service,
            jsonManager: jsonManager,
            interceptors: interceptors,
            retryPolicy: retryPolicy,
            validation: validation,
            monitors: monitors,
            logger: nil,
            connectivity: connectivity,
            deduplicatesRequests: deduplicatesRequests,
            cacheStore: HTTPCacheStore(diskCache: DiskCache(directoryURL: cacheDirectory, sizeLimit: DiskCache.defaultSizeLimit, now: { Date() })),
            sleep: sleep
        )
    }

    /// Creates a client with every dependency injected; tests use it for the cache and the retry clock.
    ///
    /// A `nil` logger turns logging off; turning it back on uses a system ``NetworkLogger``.
    init(
        service: any NetworkService,
        jsonManager: JSONManager,
        interceptors: [any RequestInterceptor],
        retryPolicy: RetryPolicy?,
        validation: ResponseValidation?,
        monitors: [any EventMonitor],
        logger: NetworkLogger?,
        connectivity: any ConnectivitySource,
        deduplicatesRequests: Bool,
        cacheStore: HTTPCacheStore,
        sleep: @escaping RequestPipeline.Sleep
    ) {
        self.service = service
        self.deduplicator = deduplicatesRequests ? RequestDeduplicator() : nil
        self.cacheStore = cacheStore
        self.logger = logger ?? NetworkLogger()
        self.sleep = sleep
        self.configuration = OSAllocatedUnfairLock(initialState: Configuration(
            jsonManager: jsonManager,
            interceptors: interceptors,
            retryPolicy: retryPolicy,
            validation: validation,
            monitors: monitors,
            isLoggingEnabled: logger != nil,
            connectivity: connectivity
        ))
    }

    // MARK: - Raw Requests

    /// Sends a prebuilt request through the pipeline: interceptors, retry, validation, monitoring
    /// and decoding apply; caching and sample data do not.
    ///
    /// ```swift
    /// let user: User? = try await netti.send(URLRequest(url: url)).data
    /// ```
    ///
    /// - Parameter urlRequest: The request to send.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError``.
    public func send<Response: Decodable & Sendable>(
        _ urlRequest: URLRequest
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        let snapshot = self.snapshot
        return try decoded(await snapshot.pipeline.data(urlRequest), using: snapshot)
    }

    /// Sends a prebuilt request and ignores the response body.
    ///
    /// - Parameter urlRequest: The request to send.
    /// - Returns: The response, with an ``Empty`` body.
    /// - Throws: ``HTTPRequestError``.
    @discardableResult
    public func send(_ urlRequest: URLRequest) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        let snapshot = self.snapshot
        return try decoded(await snapshot.pipeline.data(urlRequest), using: snapshot)
    }

    /// Builds the request for an endpoint without sending it.
    ///
    /// Parameters go where `method` places them: the query string for `GET`, `HEAD` and `DELETE`,
    /// a JSON body otherwise. Query keys follow the client's ``JSONManager`` key strategy.
    /// Interceptors do not run.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - parameters: The query or body parameters. Optional.
    ///   - method: The HTTP method.
    /// - Returns: The request.
    /// - Throws: ``HTTPRequestError/invalidURL`` or ``HTTPRequestError/encodingFailed(_:)``.
    public func buildRequest(
        _ endpoint: some HTTPRequest,
        parameters: (some Encodable & Sendable)? = Empty?.none,
        method: HTTPMethod
    ) throws(HTTPRequestError) -> URLRequest {
        try buildRequest(endpoint, parameters: parameters, method: method, jsonManager: jsonManager)
    }

    // MARK: - Decoding

    /// Decodes raw data into a response without any network exchange, for sample data, fixtures
    /// or cached payloads.
    ///
    /// The response carries `request` and a synthesized `200` status.
    ///
    /// - Parameters:
    ///   - data: The JSON data.
    ///   - request: The originating request, if any.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError/decodingFailed(_:response:)`` when the data does not decode.
    public func decode<Response: Decodable & Sendable>(
        _ data: Data,
        request: URLRequest?
    ) throws(HTTPRequestError) -> HTTPResponse<Response> {
        try decode(data, request: request, using: snapshot)
    }
}

// MARK: - Pipeline

extension Netti {
    /// Sends an endpoint: sample data, then the offline cache, then the network through the
    /// pipeline, caching a successful response before returning it.
    func send<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        method: HTTPMethod,
        parameters: (some Encodable & Sendable)?
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        let snapshot = self.snapshot
        if let sampleData = endpoint.sampleData {
            return try decode(sampleData, request: try? endpoint.asURLRequest(for: method), using: snapshot)
        }

        let urlRequest = try buildRequest(endpoint, parameters: parameters, method: method, jsonManager: snapshot.jsonManager)
        let cachePolicy = endpoint.cachePolicy
        if cachePolicy.isCaching,
           snapshot.connectivity.currentStatus == .disconnected,
           let cachedData = await cacheStore.read(key: urlRequest.cacheKey, maxAge: cachePolicy.maxAge) {
            return try decode(cachedData, request: urlRequest, using: snapshot)
        }

        let response = try await snapshot.pipeline.data(urlRequest, validation: endpoint.validation, retryPolicy: endpoint.retryPolicy)
        if cachePolicy.isCaching, let statusCode = response.statusCode, (200..<300).contains(statusCode), let rawData = response.rawData {
            // Awaited, so the entry is readable as soon as this call returns.
            try? await cacheStore.write(rawData, key: urlRequest.cacheKey)
        }
        return try decoded(response, using: snapshot)
    }

    /// Builds the request for an endpoint, encoding parameters and query keys with `jsonManager`.
    func buildRequest(
        _ endpoint: some HTTPRequest,
        parameters: (some Encodable & Sendable)?,
        method: HTTPMethod,
        jsonManager: JSONManager
    ) throws(HTTPRequestError) -> URLRequest {
        let urlRequest = try endpoint.asURLRequest(for: method)
        switch method.defaultParameterDestination {
            case .queryString:
                let keyEncoding = URLEncodedFormEncoder.KeyEncoding(jsonManager.encoder.keyEncodingStrategy)
                return try URLEncodedFormParameterEncoder(encoder: URLEncodedFormEncoder(keyEncoding: keyEncoding))
                    .encode(parameters, into: urlRequest)
            case .httpBody:
                return try JSONParameterEncoder(encoder: jsonManager.encoder).encode(parameters, into: urlRequest)
        }
    }

    /// Decodes raw data into a response with a synthesized `200` status.
    func decode<Response: Decodable & Sendable>(
        _ data: Data,
        request: URLRequest?,
        using snapshot: Snapshot
    ) throws(HTTPRequestError) -> HTTPResponse<Response> {
        let response = HTTPResponse<Data>(
            request: request,
            response: HTTPURLResponse(
                url: request?.url ?? URL(fileURLWithPath: "/"),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ),
            data: data,
            rawData: data
        )
        return try decoded(response, using: snapshot)
    }

    /// Decodes a raw response, logging a decoding failure with the raw body.
    func decoded<Response: Decodable & Sendable>(
        _ response: HTTPResponse<Data>,
        using snapshot: Snapshot
    ) throws(HTTPRequestError) -> HTTPResponse<Response> {
        do {
            return try response.decoded(using: snapshot.jsonManager)
        } catch {
            if case .decodingFailed(let decodingError as DecodingError, _) = error, let rawData = response.rawData {
                snapshot.logger?.log(decodingError, type: Response.self, data: rawData)
            }
            throw error
        }
    }
}
