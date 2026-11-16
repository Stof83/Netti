import Foundation
import Testing

@testable import Netti
import NettiTesting

@Suite("Sample data")
struct SampleDataTests {

    // MARK: - Helpers

    private func makeEndpoint(status: Int = 200, body: some Encodable = Widget(id: 1, name: "sample")) throws -> TestEndpoint {
        var endpoint = TestEndpoint()
        endpoint.sampleData = try JSONEncoder().encode(body)
        endpoint.sampleStatusCode = status
        return endpoint
    }

    private func transport() -> StubNetworkService {
        StubNetworkService { try .json(for: $0, Widget(id: 2, name: "network")) }
    }

    // MARK: - Switch

    @Test("given usesSampleData is off, when an endpoint has sample data, then the transport answers")
    func off_hitsTransport() async throws {
        let service = transport()
        let netti = makeNetti(service: service)

        let response: HTTPResponse<Widget> = try await netti.get(try makeEndpoint())

        #expect(response.data == Widget(id: 2, name: "network"))
        #expect(service.requests.count == 1)
    }

    @Test("given usesSampleData is on, when an endpoint has sample data, then the sample answers and the transport is skipped")
    func on_skipsTransport() async throws {
        let service = transport()
        let netti = makeNetti(service: service)
        netti.usesSampleData = true

        let response: HTTPResponse<Widget> = try await netti.get(try makeEndpoint())

        #expect(response.data == Widget(id: 1, name: "sample"))
        #expect(response.statusCode == 200)
        #expect(response.response?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(service.requests.isEmpty)
    }

    @Test("given usesSampleData is on, when an endpoint has no sample data, then the transport answers")
    func on_withoutSample_hitsTransport() async throws {
        let service = transport()
        let netti = makeNetti(service: service)
        netti.usesSampleData = true

        let response: HTTPResponse<Widget> = try await netti.get(TestEndpoint())

        #expect(response.data == Widget(id: 2, name: "network"))
        #expect(service.requests.count == 1)
    }

    // MARK: - Status Codes

    @Test("given a 404 sample and validation, when sent, then the validation error is thrown")
    func status404_withValidation_throws() async throws {
        let netti = makeNetti(validation: ResponseValidation())
        netti.usesSampleData = true
        let endpoint = try makeEndpoint(status: 404, body: ErrorEnvelope(message: "missing"))

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<ErrorEnvelope> in
            try await netti.get(endpoint)
        }

        guard case .unacceptableStatusCode(let status, _)? = error else {
            Issue.record("Expected unacceptableStatusCode, got \(String(describing: error))")
            return
        }
        #expect(status == 404)
    }

    @Test("given a 404 sample and no validation, when sent, then the 404 response is returned")
    func status404_withoutValidation_returnsResponse() async throws {
        let netti = makeNetti()
        netti.usesSampleData = true
        let endpoint = try makeEndpoint(status: 404, body: ErrorEnvelope(message: "missing"))

        let response: HTTPResponse<ErrorEnvelope> = try await netti.get(endpoint)

        #expect(response.statusCode == 404)
        #expect(response.data == ErrorEnvelope(message: "missing"))
    }

    // MARK: - Pipeline

    @Test("given a monitor, when a sample is sent, then the monitor sees the request and the response")
    func monitor_seesSample() async throws {
        let monitor = RecordingMonitor()
        let netti = makeNetti(monitors: [monitor])
        netti.usesSampleData = true

        let _: HTTPResponse<Widget> = try await netti.get(try makeEndpoint())

        #expect(monitor.events.values == ["create", "send", "response"])
    }

    @Test("given an interceptor, when a sample is sent, then the sampled request is adapted")
    func interceptor_adaptsSample() async throws {
        let adapter = ClosureAdapter { request in
            var adapted = request
            adapted.setValue("1", forHTTPHeaderField: "X-Adapted")
            return adapted
        }
        let netti = makeNetti(interceptors: [adapter])
        netti.usesSampleData = true

        let response: HTTPResponse<Widget> = try await netti.get(try makeEndpoint())

        #expect(response.request?.value(forHTTPHeaderField: "X-Adapted") == "1")
    }

    @Test("given a retry policy and a 503 sample, when sent, then it is retried until the limit")
    func retry_retriesSampled503() async throws {
        let sleeps = Recorder<Duration>()
        let netti = makeNetti(retryPolicy: RetryPolicy(randomUnit: { 1 }), sleeps: sleeps)
        netti.usesSampleData = true
        let endpoint = try makeEndpoint(status: 503, body: ErrorEnvelope(message: "down"))

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<ErrorEnvelope> in
            try await netti.get(endpoint)
        }

        guard case .retryLimitExceeded(let attempts, _)? = error else {
            Issue.record("Expected retryLimitExceeded, got \(String(describing: error))")
            return
        }
        #expect(attempts == 3)
        #expect(sleeps.values.count == 2)
    }

    // MARK: - Delay

    @Test("given a sample delay, when a sample is sent, then the response arrives after the delay")
    func delay_isWaitedOut() async throws {
        let netti = makeNetti()
        netti.usesSampleData = true
        netti.sampleDelay = .milliseconds(150)
        let endpoint = try makeEndpoint()
        let clock = ContinuousClock()

        let elapsed = try await clock.measure {
            let _: HTTPResponse<Widget> = try await netti.get(endpoint)
        }

        #expect(elapsed >= .milliseconds(140))
    }

    @Test("given a sample delay, when the task is cancelled, then the request is cancelled")
    func delay_isCancellable() async throws {
        let netti = makeNetti()
        netti.usesSampleData = true
        netti.sampleDelay = .seconds(30)
        let endpoint = try makeEndpoint()

        let task = Task { () async throws -> HTTPResponse<Widget> in
            try await netti.get(endpoint)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the request to be cancelled")
        } catch let error as HTTPRequestError {
            guard case .cancelled = error else {
                Issue.record("Expected cancelled, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected HTTPRequestError, got \(error)")
        }
    }

    // MARK: - Cache

    @Test("given a caching endpoint, when a sample is sent, then nothing is written to the cache")
    func cache_isNotWritten() async throws {
        let netti = makeNetti()
        netti.usesSampleData = true
        var endpoint = try makeEndpoint()
        endpoint.cachePolicy = .cache(maxAge: .seconds(60))

        let _: HTTPResponse<Widget> = try await netti.get(endpoint)
        let cached: HTTPResponse<Widget>? = await netti.cachedResponse(for: endpoint)

        #expect(cached == nil)
    }
}
