import Foundation
import Testing

@testable import Netti

@Suite("Interceptors")
struct InterceptorTests {
    private struct HeaderAdapter: RequestAdapter {
        let name: String
        let value: String

        func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
            var request = urlRequest
            request.setValue(value, forHTTPHeaderField: name)
            return request
        }
    }

    private struct AppendAdapter: RequestAdapter {
        let suffix: String

        func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
            var request = urlRequest
            let current = request.value(forHTTPHeaderField: "X-Trail") ?? ""
            request.setValue(current + suffix, forHTTPHeaderField: "X-Trail")
            return request
        }
    }

    private struct FailingAdapter: RequestAdapter {
        struct Failure: Error {}

        func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
            throw Failure()
        }
    }

    private struct FixedRetrier: RequestRetrier {
        let decision: RetryDecision
        var calls: Counter?

        func retry(_ context: RetryContext) async -> RetryDecision {
            calls?.increment()
            return decision
        }
    }

    private struct PassThrough: RequestInterceptor {}

    // MARK: - Adapters

    @Test("given an adapter that adds a header, when a request is adapted, then it carries the header")
    func adapt_headerInjection_addsHeader() async throws {
        let composite = CompositeInterceptor(adapters: [HeaderAdapter(name: "X-App-Version", value: "5.0")])

        let adapted = try await composite.adapt(makeURLRequest())

        #expect(adapted.value(forHTTPHeaderField: "X-App-Version") == "5.0")
    }

    @Test("given several adapters, when a request is adapted, then they run in registration order")
    func adapt_severalAdapters_runInOrder() async throws {
        let composite = CompositeInterceptor(adapters: [AppendAdapter(suffix: "a"), AppendAdapter(suffix: "b"), AppendAdapter(suffix: "c")])

        let adapted = try await composite.adapt(makeURLRequest())

        #expect(adapted.value(forHTTPHeaderField: "X-Trail") == "abc")
    }

    @Test("given an adapter that throws, when the pipeline adapts, then the error is wrapped in HTTPRequestError")
    func adapted_adapterThrows_wrapsError() async {
        let composite = CompositeInterceptor(adapters: [FailingAdapter()])

        let error = await expectRequestError { () async throws(HTTPRequestError) -> URLRequest in
            try await composite.adapted(makeURLRequest())
        }

        guard case .requestFailed(let urlError) = error else {
            Issue.record("Expected requestFailed, got \(String(describing: error))")
            return
        }
        #expect(urlError.userInfo[NSUnderlyingErrorKey] is FailingAdapter.Failure)
    }

    @Test("given an adapter, when it fails, then later adapters do not run")
    func adapt_failure_stopsTheChain() async {
        let composite = CompositeInterceptor(adapters: [FailingAdapter(), HeaderAdapter(name: "X-Late", value: "1")])

        await #expect(throws: FailingAdapter.Failure.self) {
            try await composite.adapt(makeURLRequest())
        }
    }

    // MARK: - Retriers

    @Test("given a retrier answering retry after a delay, when asked, then the delay is returned")
    func retry_afterDelay_returnsDelay() async {
        let composite = CompositeInterceptor(retriers: [FixedRetrier(decision: .retryAfter(.seconds(1)))])

        let decision = await composite.retry(makeContext(status: 503))

        #expect(decision == .retryAfter(.seconds(1)))
    }

    @Test("given several retriers, when the first declines, then the next one decides")
    func retry_firstDeclines_nextDecides() async {
        let composite = CompositeInterceptor(retriers: [FixedRetrier(decision: .doNotRetry), FixedRetrier(decision: .retry)])

        #expect(await composite.retry(makeContext(status: 503)) == .retry)
    }

    @Test("given several retriers, when the first asks for a retry, then later retriers are not asked")
    func retry_firstRetries_shortCircuits() async {
        let later = Counter()
        let composite = CompositeInterceptor(retriers: [
            FixedRetrier(decision: .retry),
            FixedRetrier(decision: .doNotRetry, calls: later),
        ])

        _ = await composite.retry(makeContext(status: 503))

        #expect(later.value == 0)
    }

    @Test("given a retrier at its limit and another declining, when asked, then the limit decision wins")
    func retry_limitExceeded_beatsDoNotRetry() async {
        let composite = CompositeInterceptor(retriers: [FixedRetrier(decision: .retryLimitExceeded), FixedRetrier(decision: .doNotRetry)])

        #expect(await composite.retry(makeContext(status: 503)) == .retryLimitExceeded)
    }

    @Test("given a retrier at its limit and another asking for a retry, when asked, then the retry wins")
    func retry_limitExceeded_losesToRetry() async {
        let composite = CompositeInterceptor(retriers: [FixedRetrier(decision: .retryLimitExceeded), FixedRetrier(decision: .retry)])

        #expect(await composite.retry(makeContext(status: 503)) == .retry)
    }

    @Test("given no retriers, when asked, then the answer is do not retry")
    func retry_noRetriers_doesNotRetry() async {
        #expect(await CompositeInterceptor().retry(makeContext(status: 503)) == .doNotRetry)
    }

    // MARK: - Defaults

    @Test("given an interceptor implementing nothing, when used, then requests pass through and are not retried")
    func interceptor_defaults_passThrough() async throws {
        let request = makeURLRequest(headers: ["X-Keep": "1"])

        let adapted = try await PassThrough().adapt(request)
        let decision = await PassThrough().retry(makeContext(status: 503))

        #expect(adapted == request)
        #expect(decision == .doNotRetry)
    }

    @Test("given interceptors, when combined, then each acts as adapter and retrier")
    func composite_fromInterceptors_actsAsBoth() async throws {
        struct Both: RequestInterceptor {
            func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
                var request = urlRequest
                request.setValue("1", forHTTPHeaderField: "X-Both")
                return request
            }

            func retry(_ context: RetryContext) async -> RetryDecision {
                .retry
            }
        }
        let composite = CompositeInterceptor([Both()])

        let adapted = try await composite.adapt(makeURLRequest())

        #expect(adapted.value(forHTTPHeaderField: "X-Both") == "1")
        #expect(await composite.retry(makeContext(status: 500)) == .retry)
    }
}
