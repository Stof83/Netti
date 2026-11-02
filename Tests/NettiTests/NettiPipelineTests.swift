import Foundation
import Testing

@testable import Netti
import NettiTesting

@Suite("Netti pipeline", .timeLimit(.minutes(1)))
struct NettiPipelineTests {

    // MARK: - Decoding

    @Test("given a 2xx body that does not match the type, when sent, then decodingFailed is thrown, not requestFailed")
    func decodingFailure_isNotRewrapped() async {
        let service = StubNetworkService { .stub(for: $0, body: Data(#"{"unexpected":true}"#.utf8)) }
        let netti = makeNetti(service: service)

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Widget> in
            try await netti.get(TestEndpoint())
        }

        guard case .decodingFailed(_, let response)? = error else {
            Issue.record("Expected decodingFailed, got \(String(describing: error))")
            return
        }
        #expect(response?.statusCode == 200)
    }

    @Test("given a 401 with a JSON envelope and no validation, when sent, then the response is returned with its decoded body")
    func non2xx_isReturnedDecoded() async throws {
        let service = StubNetworkService { try .json(for: $0, status: 401, ErrorEnvelope(message: "expired")) }
        let netti = makeNetti(service: service)

        let response: HTTPResponse<ErrorEnvelope> = try await netti.get(TestEndpoint())

        #expect(response.statusCode == 401)
        #expect(response.data == ErrorEnvelope(message: "expired"))
    }

    @Test("given sample data, when sent, then it is decoded without any transport call")
    func sampleData_skipsTransport() async throws {
        let service = StubNetworkService()
        let netti = makeNetti(service: service)
        var endpoint = TestEndpoint()
        endpoint.sampleData = try JSONEncoder().encode(Widget(id: 1, name: "sample"))

        let response: HTTPResponse<Widget> = try await netti.get(endpoint)

        #expect(response.data == Widget(id: 1, name: "sample"))
        #expect(service.requests.isEmpty)
    }

    @Test("given raw data, when decoded with the utility, then a synthesized 200 response carries the value")
    func decodeUtility_synthesizes200() throws {
        let netti = makeNetti()
        let data = try JSONEncoder().encode(Widget(id: 2, name: "fixture"))

        let response: HTTPResponse<Widget> = try netti.decode(data, request: nil)

        #expect(response.data == Widget(id: 2, name: "fixture"))
        #expect(response.statusCode == 200)
    }

    // MARK: - Errors

    @Test("given an endpoint without a base URL, when sent, then invalidURL is thrown")
    func missingBaseURL_throwsInvalidURL() async {
        var endpoint = TestEndpoint()
        endpoint.baseURL = nil

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await makeNetti().get(endpoint)
        }

        guard case .invalidURL? = error else {
            Issue.record("Expected invalidURL, got \(String(describing: error))")
            return
        }
    }

    @Test("given a request in flight, when the calling task is cancelled, then cancelled is thrown")
    func cancellation_throwsCancelled() async {
        let service = StubNetworkService { request in
            try await Task.sleep(for: .seconds(30))
            return .stub(for: request)
        }
        let netti = makeNetti(service: service)

        let task = Task { () async throws -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }
        _ = await eventually { service.requests.isEmpty == false }
        task.cancel()

        let error = await #expect(throws: HTTPRequestError.self) { try await task.value }
        #expect(error?.isCancelled == true)
    }

    // MARK: - Adapters

    @Test("given a client adapter, when requests are sent, then each carries the adapted header")
    func adapter_addsHeader() async throws {
        let service = StubNetworkService()
        let adapter = ClosureAdapter { request in
            var request = request
            request.setValue("5.0", forHTTPHeaderField: "X-App-Version")
            return request
        }
        let netti = makeNetti(service: service, interceptors: [adapter])

        try await netti.get(TestEndpoint())
        try await netti.post(TestEndpoint(), body: Widget(id: 1, name: "a"))

        #expect(service.requests.map { $0.value(forHTTPHeaderField: "X-App-Version") } == ["5.0", "5.0"])
    }

    @Test("given an adapter that throws, when sent, then nothing is sent and the error is wrapped")
    func adapterFailure_sendsNothing() async {
        struct AdapterError: Error {}
        let service = StubNetworkService()
        let netti = makeNetti(service: service, interceptors: [ClosureAdapter { _ in throw AdapterError() }])

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }

        guard case .requestFailed(let urlError)? = error else {
            Issue.record("Expected requestFailed, got \(String(describing: error))")
            return
        }
        #expect(urlError.userInfo[NSUnderlyingErrorKey] is AdapterError)
        #expect(service.requests.isEmpty)
    }

    // MARK: - Retry

    @Test("given a client without retry policy, when a GET fails with 503, then it is sent once")
    func noRetryByDefault() async throws {
        let service = StubNetworkService { .stub(for: $0, status: 503) }
        let netti = makeNetti(service: service)

        let response = try await netti.get(TestEndpoint())

        #expect(response.statusCode == 503)
        #expect(service.requests.count == 1)
    }

    @Test("given the default retry policy, when a GET fails with 503 three times, then 3 attempts are made and retryLimitExceeded carries the last response")
    func retryPolicy_exhausted() async {
        let attempts = Counter()
        let service = StubNetworkService { request in
            .stub(for: request, status: 503, body: Data("attempt \(attempts.increment())".utf8))
        }
        let sleeps = Recorder<Duration>()
        let netti = makeNetti(service: service, retryPolicy: RetryPolicy(randomUnit: { 1 }), sleeps: sleeps)

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }

        guard case .retryLimitExceeded(let count, _)? = error else {
            Issue.record("Expected retryLimitExceeded, got \(String(describing: error))")
            return
        }
        #expect(count == 3)
        #expect(service.requests.count == 3)
        #expect(error?.response?.statusCode == 503)
        #expect(error?.response?.rawData == Data("attempt 3".utf8))
        #expect(sleeps.values == [.milliseconds(500), .milliseconds(1000)])
    }

    @Test("given the default retry policy, when a POST fails with 503, then it is not retried")
    func retryPolicy_skipsPost() async throws {
        let service = StubNetworkService { .stub(for: $0, status: 503) }
        let netti = makeNetti(service: service, retryPolicy: RetryPolicy())

        let response = try await netti.post(TestEndpoint(), body: Widget(id: 1, name: "a"))

        #expect(response.statusCode == 503)
        #expect(service.requests.count == 1)
    }

    @Test("given a 429 with Retry-After 2, when retried, then the pipeline waits 2 seconds first")
    func retryAfter_isHonoured() async throws {
        let attempts = Counter()
        let service = StubNetworkService { request in
            attempts.increment() == 1 ? .stub(for: request, status: 429, headers: ["Retry-After": "2"]) : .stub(for: request)
        }
        let sleeps = Recorder<Duration>()
        let netti = makeNetti(service: service, retryPolicy: RetryPolicy(), sleeps: sleeps)

        let response = try await netti.get(TestEndpoint())

        #expect(response.statusCode == 200)
        #expect(sleeps.values == [.seconds(2)])
    }

    @Test("given an endpoint that disables retry, when the client retries, then the endpoint is sent once")
    func endpointRetryPolicy_overridesClient() async throws {
        let service = StubNetworkService { .stub(for: $0, status: 503) }
        let netti = makeNetti(service: service, retryPolicy: RetryPolicy())
        var endpoint = TestEndpoint()
        endpoint.retryPolicy = .disabled

        try await netti.get(endpoint)

        #expect(service.requests.count == 1)
    }

    @Test("given an authentication interceptor, when the server answers 401 once, then the credential is refreshed and the retry succeeds")
    func authenticationInterceptor_refreshesAndRetries() async throws {
        let service = StubNetworkService { request in
            let isFresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
            return try .json(for: request, status: isFresh ? 200 : 401, Widget(id: 1, name: isFresh ? "ok" : "denied"))
        }
        let refreshes = Counter()
        let auth = AuthenticationInterceptor(bearerToken: "stale") { _ in
            refreshes.increment()
            return "fresh"
        }
        let netti = makeNetti(service: service, interceptors: [auth])

        let response: HTTPResponse<Widget> = try await netti.get(TestEndpoint())

        #expect(response.statusCode == 200)
        #expect(response.data?.name == "ok")
        #expect(refreshes.value == 1)
        #expect(service.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer stale", "Bearer fresh"])
    }

    // MARK: - Validation

    @Test("given client validation, when the server returns 404, then unacceptableStatusCode carries the raw body")
    func validation_rejects404() async {
        let service = StubNetworkService { .stub(for: $0, status: 404, body: Data("missing".utf8)) }
        let netti = makeNetti(service: service, validation: ResponseValidation())

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }

        guard case .unacceptableStatusCode(404, let response)? = error else {
            Issue.record("Expected unacceptableStatusCode(404), got \(String(describing: error))")
            return
        }
        #expect(response.rawData == Data("missing".utf8))
    }

    @Test("given client validation and an endpoint that disables it, when the server returns 404, then the response is returned")
    func endpointValidation_overridesClient() async throws {
        let service = StubNetworkService { .stub(for: $0, status: 404) }
        let netti = makeNetti(service: service, validation: ResponseValidation())
        var endpoint = TestEndpoint()
        endpoint.validation = .disabled

        let response = try await netti.get(endpoint)

        #expect(response.statusCode == 404)
    }

    // MARK: - Monitoring

    @Test("given two monitors, when a request is adapted, sent and answered, then both receive every event in order")
    func monitors_receiveEveryEvent() async throws {
        let service = StubNetworkService()
        let first = RecordingMonitor()
        let second = RecordingMonitor()
        let netti = makeNetti(service: service, interceptors: [ClosureAdapter { $0 }], monitors: [first, second])

        try await netti.get(TestEndpoint())

        #expect(first.events.values == ["create", "adapt", "send", "response"])
        #expect(second.events.values == first.events.values)
    }

    @Test("given a monitor, when a request is retried and then fails validation, then retry and fail are reported")
    func monitors_receiveRetryAndFailure() async {
        let service = StubNetworkService { .stub(for: $0, status: 503) }
        let monitor = RecordingMonitor()
        let netti = makeNetti(service: service, retryPolicy: RetryPolicy(maxRetries: 1), monitors: [monitor])

        _ = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }

        #expect(monitor.events.values == ["create", "send", "response", "retry", "send", "response", "fail"])
    }

    @Test("given a monitor and a real transfer, when the request completes, then the monitor receives its metrics")
    func monitors_receiveMetrics() async throws {
        let server = try await LocalHTTPServer.start { _ in .text("ok") }
        defer { server.stop() }
        let monitor = RecordingMonitor()
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral), monitors: [monitor])

        try await netti.send(URLRequest(url: server.url("/")))

        #expect(monitor.events.values.contains("metrics"))
        #expect(monitor.metrics.values.first?.transactionMetrics.isEmpty == false)
    }

    @Test("given logging disabled, when a request is sent, then nothing is logged; given it enabled, then the request is logged")
    func logging_canBeDisabled() async throws {
        let silentOutput = Recorder<String>()
        let loudOutput = Recorder<String>()
        let silent = makeNetti(logger: NetworkLogger(isEnabled: false) { _, message in silentOutput.append(message) })
        let loud = makeNetti(logger: NetworkLogger { _, message in loudOutput.append(message) })

        try await silent.get(TestEndpoint())
        try await loud.get(TestEndpoint())

        #expect(silentOutput.values.isEmpty)
        #expect(loudOutput.values.contains { $0.hasPrefix("curl") })
    }

    @Test("given the public initializer with logging off, when built, then the client works with zero other configuration")
    func publicInitializer_zeroConfiguration() async throws {
        let service = StubNetworkService()
        let netti = Netti(service: service)
        netti.isLoggingEnabled = false

        let response = try await netti.get(TestEndpoint())

        #expect(response.statusCode == 200)
        #expect(service.requests.count == 1)
    }
}
