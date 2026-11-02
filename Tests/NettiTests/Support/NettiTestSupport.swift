import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

// MARK: - Endpoint

/// An endpoint whose every requirement is settable.
struct TestEndpoint: HTTPRequest {
    var baseURL: URL? = URL(string: "https://api.test")
    var basePath = "v1"
    var path = "items"
    var headers: HTTPHeaders = [:]
    var sampleData: Data?
    var cachePolicy = HTTPCachePolicy.none
    var validation: ResponseValidation?
    var retryPolicy: RetryPolicy?
}

/// An endpoint whose full URL, query included, is given; points tests at the loopback servers.
struct URLEndpoint: HTTPRequest {
    let url: URL
    var headers: HTTPHeaders = [:]
    var validation: ResponseValidation?

    init(_ url: URL, headers: HTTPHeaders = [:], validation: ResponseValidation? = nil) {
        self.url = url
        self.headers = headers
        self.validation = validation
    }

    var baseURL: URL? { url }
    var basePath: String { "" }
    var path: String { "" }
    var requestURL: URL { url }
}

struct Widget: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

struct ErrorEnvelope: Codable, Equatable, Sendable {
    let message: String
}

// MARK: - Monitor

/// Records the name of every event, in order.
final class RecordingMonitor: EventMonitor {
    let events = Recorder<String>()
    let metrics = Recorder<URLSessionTaskMetrics>()

    func requestDidCreate(_ request: URLRequest) { events.append("create") }
    func requestDidAdapt(_ original: URLRequest, to adapted: URLRequest) { events.append("adapt") }
    func requestDidSend(_ request: URLRequest) { events.append("send") }
    func requestWillRetry(_ request: URLRequest, retryCount: Int, delay: Duration) { events.append("retry") }
    func requestDidReceiveResponse(_ response: HTTPResponse<Data>) { events.append("response") }
    func requestDidCollectMetrics(_ metrics: URLSessionTaskMetrics, for request: URLRequest) {
        events.append("metrics")
        self.metrics.append(metrics)
    }
    func requestDidFail(_ request: URLRequest, error: HTTPRequestError) { events.append("fail") }
}

/// An adapter built from a closure.
struct ClosureAdapter: RequestInterceptor {
    let body: @Sendable (URLRequest) async throws -> URLRequest

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        try await body(urlRequest)
    }
}

// MARK: - Client

/// A cache store in a new temporary directory.
func makeCacheStore(sizeLimit: Int = DiskCache.defaultSizeLimit, now: @escaping @Sendable () -> Date = { Date() }) -> HTTPCacheStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-cache-\(UUID().uuidString)", isDirectory: true)
    return HTTPCacheStore(diskCache: DiskCache(directoryURL: directory, sizeLimit: sizeLimit, now: now), now: now)
}

/// A client on a stub transport, with an isolated cache, no logging, and retry delays recorded
/// instead of slept.
func makeNetti(
    service: any NetworkService = StubNetworkService(),
    jsonManager: JSONManager = JSONManager(keyStrategy: .useDefaultKeys),
    interceptors: [any RequestInterceptor] = [],
    retryPolicy: RetryPolicy? = nil,
    validation: ResponseValidation? = nil,
    monitors: [any EventMonitor] = [],
    logger: NetworkLogger? = nil,
    connectivity: any ConnectivitySource = StubConnectivity(),
    deduplicatesRequests: Bool = true,
    cacheStore: HTTPCacheStore = makeCacheStore(),
    sleeps: Recorder<Duration> = Recorder()
) -> Netti {
    Netti(
        service: service,
        jsonManager: jsonManager,
        interceptors: interceptors,
        retryPolicy: retryPolicy,
        validation: validation,
        monitors: monitors,
        logger: logger,
        connectivity: connectivity,
        deduplicatesRequests: deduplicatesRequests,
        cacheStore: cacheStore,
        sleep: { sleeps.append($0) }
    )
}

/// Waits until `condition` holds, polling every few milliseconds; `false` on timeout.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
