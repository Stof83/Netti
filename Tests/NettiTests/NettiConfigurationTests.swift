import Foundation
import Testing

@testable import Netti
import NettiTesting

@Suite("Netti configuration", .timeLimit(.minutes(1)))
struct NettiConfigurationTests {

    private struct PageNumber: Codable, Equatable, Sendable {
        let pageNumber: Int
    }

    // MARK: - Set After Init

    @Test("given a client without a retry policy, when retryPolicy is set after init, then the next request is retried")
    func retryPolicy_setAfterInit_appliesToNextRequest() async {
        let service = StubNetworkService { .stub(for: $0, status: 503) }
        let netti = makeNetti(service: service)

        netti.retryPolicy = RetryPolicy(maxRetries: 1)
        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }

        guard case .retryLimitExceeded(let attempts, _)? = error else {
            Issue.record("Expected retryLimitExceeded, got \(String(describing: error))")
            return
        }
        #expect(attempts == 2)
        #expect(service.requests.count == 2)
    }

    @Test("given a client without validation, when validation is set after init, then the next 404 is rejected")
    func validation_setAfterInit_appliesToNextRequest() async {
        let service = StubNetworkService { .stub(for: $0, status: 404) }
        let netti = makeNetti(service: service)

        netti.validation = ResponseValidation()
        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }

        guard case .unacceptableStatusCode(404, _)? = error else {
            Issue.record("Expected unacceptableStatusCode(404), got \(String(describing: error))")
            return
        }
    }

    @Test("given a client without interceptors, when interceptors are set after init, then the next request is adapted")
    func interceptors_setAfterInit_adaptNextRequest() async throws {
        let service = StubNetworkService()
        let netti = makeNetti(service: service)
        let adapter = ClosureAdapter { request in
            var request = request
            request.setValue("1", forHTTPHeaderField: "X-Adapted")
            return request
        }

        try await netti.get(TestEndpoint())
        netti.interceptors = [adapter]
        try await netti.get(TestEndpoint())

        #expect(service.requests.map { $0.value(forHTTPHeaderField: "X-Adapted") } == [nil, "1"])
        #expect(netti.interceptors.count == 1)
    }

    @Test("given a client without monitors, when monitors are set after init, then the next request is observed")
    func monitors_setAfterInit_observeNextRequest() async throws {
        let netti = makeNetti()
        let monitor = RecordingMonitor()

        netti.monitors = [monitor]
        try await netti.get(TestEndpoint())

        #expect(monitor.events.values == ["create", "send", "response"])
        #expect(netti.monitors.count == 1)
    }

    @Test("given a default-keys JSONManager, when a snake case manager is set after init, then the next query is snake cased")
    func jsonManager_setAfterInit_encodesNextRequest() async throws {
        let service = StubNetworkService()
        let netti = makeNetti(service: service, jsonManager: JSONManager(keyStrategy: .useDefaultKeys))

        try await netti.get(TestEndpoint(), query: PageNumber(pageNumber: 2))
        netti.jsonManager = JSONManager()
        try await netti.get(TestEndpoint(), query: PageNumber(pageNumber: 2))

        #expect(service.requests.map(\.url?.query) == ["pageNumber=2", "page_number=2"])
    }

    @Test("given a cached response, when a disconnected source is set as connectivity after init, then the next request is served from the cache")
    func connectivity_setAfterInit_appliesToNextRequest() async throws {
        let service = StubNetworkService { try .json(for: $0, Widget(id: 1, name: "network")) }
        let netti = makeNetti(service: service, connectivity: StubConnectivity(.connected))
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache
        let _: HTTPResponse<Widget> = try await netti.get(endpoint)

        netti.connectivity = StubConnectivity(.disconnected)
        let cached: HTTPResponse<Widget> = try await netti.get(endpoint)

        #expect(cached.data == Widget(id: 1, name: "network"))
        #expect(service.requests.count == 1)
        #expect(netti.connectivity.currentStatus == .disconnected)
    }

    @Test("given a logging client, when isLoggingEnabled is toggled after init, then only requests sent while enabled are logged")
    func isLoggingEnabled_toggledAfterInit_appliesToNextRequest() async throws {
        let output = Recorder<String>()
        let netti = makeNetti(logger: NetworkLogger { _, message in output.append(message) })
        #expect(netti.isLoggingEnabled)

        netti.isLoggingEnabled = false
        try await netti.get(TestEndpoint())
        let loggedWhileDisabled = output.values.count
        netti.isLoggingEnabled = true
        try await netti.get(TestEndpoint())

        #expect(loggedWhileDisabled == 0)
        #expect(output.values.contains { $0.hasPrefix("curl") })
    }

    @Test("given a client created without a logger, when built, then logging is reported off")
    func isLoggingEnabled_withoutLogger_isOff() {
        #expect(makeNetti().isLoggingEnabled == false)
    }

    // MARK: - In-Flight Snapshot

    @Test("given a request in flight, when retryPolicy is set, then that request keeps its policy and the next one uses the new policy")
    func retryPolicy_setDuringFlight_appliesOnlyToNextRequest() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let attempts = Counter()
        let service = StubNetworkService { request in
            if attempts.increment() == 1 {
                for await _ in gate {
                    break
                }
            }
            return .stub(for: request, status: 503)
        }
        let netti = makeNetti(service: service, deduplicatesRequests: false)

        let inFlight = Task { () async throws -> Int? in try await netti.get(TestEndpoint()).statusCode }
        #expect(await eventually { service.requests.count == 1 })
        netti.retryPolicy = RetryPolicy(maxRetries: 2)
        release.yield()

        #expect(try await inFlight.value == 503)
        #expect(service.requests.count == 1)

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }
        guard case .retryLimitExceeded(let count, _)? = error else {
            Issue.record("Expected retryLimitExceeded, got \(String(describing: error))")
            return
        }
        #expect(count == 3)
    }

    @Test("given a request in flight, when jsonManager is set, then that request decodes with the manager it was built with")
    func jsonManager_setDuringFlight_decodesWithSnapshot() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let service = StubNetworkService { request in
            for await _ in gate {
                break
            }
            return .stub(for: request, body: Data(#"{"page_number":7}"#.utf8))
        }
        let netti = makeNetti(service: service, jsonManager: JSONManager())

        let inFlight = Task { () async throws -> PageNumber? in try await netti.get(TestEndpoint()).data }
        #expect(await eventually { service.requests.count == 1 })
        netti.jsonManager = JSONManager(keyStrategy: .useDefaultKeys)
        release.yield()

        #expect(try await inFlight.value == PageNumber(pageNumber: 7))
    }

    // MARK: - Concurrency

    @Test("given 100 concurrent requests, when every property is mutated meanwhile, then all requests complete")
    func concurrentRequests_whileMutating_allComplete() async throws {
        let netti = makeNetti(logger: NetworkLogger(isEnabled: false) { _, _ in })
        let completed = Counter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<200 {
                    let isEven = index.isMultiple(of: 2)
                    netti.retryPolicy = isEven ? RetryPolicy() : nil
                    netti.validation = isEven ? ResponseValidation() : nil
                    netti.interceptors = isEven ? [ClosureAdapter { $0 }] : []
                    netti.monitors = isEven ? [RecordingMonitor()] : []
                    netti.jsonManager = isEven ? JSONManager() : JSONManager(keyStrategy: .useDefaultKeys)
                    netti.isLoggingEnabled = isEven
                    netti.connectivity = StubConnectivity(.connected)
                    await Task.yield()
                }
            }
            for _ in 0..<100 {
                group.addTask {
                    try await netti.get(TestEndpoint())
                    completed.increment()
                }
            }
            try await group.waitForAll()
        }

        #expect(completed.value == 100)
    }
}
