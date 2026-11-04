//
//  RequestPipeline.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation

/// The one path every ``Netti`` request takes once it is built: adapt → transport → validate →
/// retry, with the event monitor observing each stage.
///
/// Encoding, caching and decoding stay in ``Netti``; the pipeline works on built `URLRequest`s, so
/// data, upload, download and stream requests all share it.
struct RequestPipeline: Sendable {

    // MARK: - Types

    /// Waits before a retry; throws when the wait is cancelled.
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// What one attempt produced: the caller's output and the raw response used to validate,
    /// retry and monitor it.
    struct Attempt<Output: Sendable>: Sendable {
        let output: Output
        let response: HTTPResponse<Data>
    }

    // MARK: - Constants

    private static let successStatusCodes = 200..<300

    // MARK: - Properties

    let service: any NetworkService
    let interceptor: (any RequestInterceptor)?
    let retryPolicy: RetryPolicy?
    let validation: ResponseValidation?
    let monitor: any EventMonitor
    let deduplicator: RequestDeduplicator?
    let sleep: Sleep

    // MARK: - Running

    /// Sends `request` until it succeeds, fails for good, or no retrier asks for another attempt.
    ///
    /// An attempt fails when the transport throws, when validation rejects the response, or when the
    /// status is not 2xx. Retriers decide about every failed attempt; when none retries, a thrown or
    /// validation error is thrown, and a non-2xx response is returned as received.
    ///
    /// - Parameters:
    ///   - request: The built request, before adaptation; every attempt adapts it again, keeping
    ///     the `Idempotency-Key` the first attempt was given.
    ///   - validation: The endpoint's validation, overriding the client's.
    ///   - retryPolicy: The endpoint's retry policy, overriding the client's.
    ///   - discard: Releases the output of an attempt that is not returned, such as a downloaded file.
    ///   - transport: Performs one attempt.
    /// - Returns: The output of the attempt that ends the request.
    func run<Output: Sendable>(
        _ request: URLRequest,
        validation endpointValidation: ResponseValidation? = nil,
        retryPolicy endpointRetryPolicy: RetryPolicy? = nil,
        discard: (Output) -> Void = { _ in },
        transport: (URLRequest) async throws(HTTPRequestError) -> Attempt<Output>
    ) async throws(HTTPRequestError) -> Output {
        monitor.requestDidCreate(request)
        let validation = endpointValidation ?? validation
        let retrier = retrier(with: endpointRetryPolicy ?? retryPolicy)
        var retryCount = 0
        var request = request

        while true {
            let sent = try await prepare(request)
            if retryCount == 0 {
                request.keepIdempotencyKey(of: sent)
            }

            var output: Output?
            let response: HTTPResponse<Data>?
            let failure: HTTPRequestError?
            do throws(HTTPRequestError) {
                let attempt = try await transport(sent)
                output = attempt.output
                response = attempt.response
                receive(attempt.response, for: sent)
                failure = validationFailure(of: attempt.response, with: validation)
            } catch {
                response = error.response
                failure = error
            }

            if let output, failure == nil, isSuccess(response) {
                return output
            }
            if case .cancelled = failure {
                output.map(discard)
                throw fail(sent, with: .cancelled)
            }

            let context = RetryContext(request: sent, response: response, error: failure, retryCount: retryCount)
            let delay: Duration
            switch await retrier?.retry(context) ?? .doNotRetry {
                case .retry:
                    delay = .zero
                case .retryAfter(let retryDelay):
                    delay = retryDelay
                case .retryLimitExceeded:
                    output.map(discard)
                    let lastError = failure ?? response.map { .unacceptableStatusCode($0.statusCode ?? 0, response: $0) } ?? .cancelled
                    throw fail(sent, with: .retryLimitExceeded(attempts: retryCount + 1, lastError: lastError))
                case .doNotRetry:
                    // Without a failure the attempt produced an output: a non-2xx response, returned as is.
                    guard let output, failure == nil else {
                        output.map(discard)
                        throw fail(sent, with: failure ?? .cancelled)
                    }
                    return output
            }

            output.map(discard)
            retryCount += 1
            monitor.requestWillRetry(sent, retryCount: retryCount, delay: delay)
            do {
                try await sleep(delay)
            } catch {
                throw fail(sent, with: .cancelled)
            }
        }
    }

    /// Sends a data request, sharing the transfer with identical in-flight `GET` and `HEAD` requests.
    ///
    /// A request with a `progress` handler does not share its transfer, so the handler sees the bytes
    /// of its own request. One reporter serves every attempt: retries never move progress backwards,
    /// and `1.0` is reported once, for the attempt that ends the request.
    func data(
        _ request: URLRequest,
        validation: ResponseValidation? = nil,
        retryPolicy: RetryPolicy? = nil,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        guard let reporter = ProgressReporter(progress) else {
            return try await run(request, validation: validation, retryPolicy: retryPolicy) { sent throws(HTTPRequestError) in
                let response = try await transferData(sent)
                return Attempt(output: response, response: response)
            }
        }
        let service = service
        let handler = Self.attemptHandler(reporting: reporter)
        let response = try await run(request, validation: validation, retryPolicy: retryPolicy) { sent throws(HTTPRequestError) in
            let response = try await service.data(for: sent, progress: handler)
            return Attempt(output: response, response: response)
        }
        reporter.finish(completed: Int64(response.rawData?.count ?? 0))
        return response
    }

    /// Opens a WebSocket for `request` after adapting it.
    func webSocket(_ request: URLRequest) async throws(HTTPRequestError) -> any WebSocketTransport {
        monitor.requestDidCreate(request)
        let sent = try await prepare(request)
        do {
            return try await service.webSocket(for: sent)
        } catch {
            throw fail(sent, with: error)
        }
    }
}

// MARK: - Snapshot

extension RequestPipeline {
    /// Creates a pipeline from a client's configuration: interceptors run as one, in order, and
    /// monitors are observed as one, in order.
    init(
        service: any NetworkService,
        interceptors: [any RequestInterceptor],
        retryPolicy: RetryPolicy?,
        validation: ResponseValidation?,
        monitors: [any EventMonitor],
        deduplicator: RequestDeduplicator?,
        sleep: @escaping Sleep
    ) {
        let interceptor: (any RequestInterceptor)? = switch interceptors.count {
            case 0: nil
            case 1: interceptors[0]
            default: CompositeInterceptor(interceptors)
        }
        self.init(
            service: service,
            interceptor: interceptor,
            retryPolicy: retryPolicy,
            validation: validation,
            monitor: CompositeEventMonitor(monitors),
            deduplicator: deduplicator,
            sleep: sleep
        )
    }
}

// MARK: - Private Helpers

private extension RequestPipeline {
    /// Forwards an attempt's progress to `reporter`, except its completion: an engine reports
    /// `1.0` for any response it returns, including one that is about to be retried, so the
    /// pipeline reports completion itself once the request ends.
    static func attemptHandler(reporting reporter: ProgressReporter) -> ProgressHandler {
        { progress in
            if let total = progress.totalUnitCount, progress.completedUnitCount >= total {
                return
            }
            reporter.report(completed: progress.completedUnitCount, total: progress.totalUnitCount ?? 0)
        }
    }

    /// Checks cancellation, adapts `request`, rejects headers that would split on the wire, and
    /// reports it as sent.
    func prepare(_ request: URLRequest) async throws(HTTPRequestError) -> URLRequest {
        guard Task.isCancelled == false else {
            throw fail(request, with: .cancelled)
        }
        guard let interceptor else {
            try validateHeaders(of: request)
            monitor.requestDidSend(request)
            return request
        }
        let adapted: URLRequest
        do {
            adapted = try await interceptor.adapted(request)
        } catch {
            throw fail(request, with: error)
        }
        monitor.requestDidAdapt(request, to: adapted)
        try validateHeaders(of: adapted)
        monitor.requestDidSend(adapted)
        return adapted
    }

    func validateHeaders(of request: URLRequest) throws(HTTPRequestError) {
        do {
            try request.validateHeaders()
        } catch {
            throw fail(request, with: error)
        }
    }

    func transferData(_ request: URLRequest) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        let method = HTTPMethod(rawValue: request.httpMethod ?? HTTPMethod.get.rawValue)
        guard let deduplicator, method == .get || method == .head else {
            return try await service.data(for: request)
        }
        let service = service
        return try await deduplicator.response(for: request.deduplicationKey) { () async throws(HTTPRequestError) in
            try await service.data(for: request)
        }
    }

    func retrier(with retryPolicy: RetryPolicy?) -> (any RequestRetrier)? {
        switch (interceptor, retryPolicy) {
            case (nil, nil):
                nil
            case (let interceptor?, nil):
                interceptor
            case (nil, let retryPolicy?):
                retryPolicy
            case (let interceptor?, let retryPolicy?):
                CompositeInterceptor(retriers: [interceptor, retryPolicy])
        }
    }

    func receive(_ response: HTTPResponse<Data>, for request: URLRequest) {
        monitor.requestDidReceiveResponse(response)
        if let metrics = response.metrics {
            monitor.requestDidCollectMetrics(metrics, for: request)
        }
    }

    func validationFailure(of response: HTTPResponse<Data>, with validation: ResponseValidation?) -> HTTPRequestError? {
        do {
            try validation?.validate(response)
            return nil
        } catch {
            return error
        }
    }

    /// A response without an HTTP status, such as a sample one, counts as a success.
    func isSuccess(_ response: HTTPResponse<Data>?) -> Bool {
        guard let statusCode = response?.statusCode else {
            return true
        }
        return Self.successStatusCodes.contains(statusCode)
    }

    func fail(_ request: URLRequest, with error: HTTPRequestError) -> HTTPRequestError {
        monitor.requestDidFail(request, error: error)
        return error
    }
}

// MARK: - Idempotency Key

private extension URLRequest {
    /// Copies the `Idempotency-Key` an adapter added on the first attempt, so every retry, which
    /// adapts the original request again, sends the same key.
    mutating func keepIdempotencyKey(of sent: URLRequest) {
        let name = IdempotencyKeyAdapter.headerName
        guard value(forHTTPHeaderField: name) == nil, let key = sent.value(forHTTPHeaderField: name) else {
            return
        }
        setValue(key, forHTTPHeaderField: name)
    }
}
