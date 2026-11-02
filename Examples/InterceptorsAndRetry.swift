//
//  InterceptorsAndRetry.swift
//  Netti
//

import Foundation
import NettiTesting

/// Adapting every request, retrying transient failures, a custom retrier and a per-endpoint
/// override.
///
/// Runs offline. `StubServer` clients skip retry delays, so the retries below finish instantly;
/// the delays are still reported through a monitor.
func interceptorsAndRetryExample() async throws {
    let url = "https://api.example.com/v1/users/1"

    // MARK: - Adapt every request

    let adaptServer = StubServer()
    adaptServer.stub(.get, url, json: User(id: 1, name: "Ada"))
    let adapted = adaptServer.netti(interceptors: [AppHeadersInterceptor()])
    try await adapted.get(UserAPI.user(1))
    let headers = adaptServer.requests.last?.headers ?? [:]
    report("adapt    -> X-Client: \(headers["X-Client"] ?? "nil")")
    try expect(headers["X-Client"] == "ios/5.0", "the adapter did not run")

    // MARK: - Retry transient failures

    // Two 503s, then a 200: the default policy retries idempotent methods on 503.
    let retryServer = StubServer()
    retryServer.stub(.get, url, json: User(id: 1, name: "Ada"))
    retryServer.stub(.get, url, status: 503, times: 2)
    let delays = Recorder<Duration>()
    let retried = retryServer.netti(retryPolicy: RetryPolicy(), monitors: [RetryMonitor(delays: delays)])
    let response: HTTPResponse<User> = try await retried.get(UserAPI.user(1))
    report("retry    -> status \(response.statusCode ?? 0) after \(retryServer.requests.count) attempts, \(delays.values.count) retry delays")
    try expect(response.statusCode == 200 && retryServer.requests.count == 3, "expected success on the third attempt")

    // MARK: - Retry limit

    let downServer = StubServer()
    downServer.stub(.get, url, status: 503)
    let exhausted = downServer.netti(retryPolicy: RetryPolicy(maxRetries: 1))
    do {
        try await exhausted.get(UserAPI.user(1))
        report("limit    -> no error")
    } catch .retryLimitExceeded(let attempts, _) {
        report("limit    -> retryLimitExceeded after \(attempts) attempts")
    } catch {
        report("limit    -> unexpected error \(error)")
    }

    // MARK: - POST is never retried by default

    let postServer = StubServer()
    postServer.stub(.post, "https://api.example.com/v1/users", status: 503)
    let post = postServer.netti(retryPolicy: RetryPolicy())
    let postResponse = try await post.post(UserAPI.users, body: NewUser(name: "Ada"))
    report("post     -> status \(postResponse.statusCode ?? 0), attempts \(postServer.requests.count) (not retried)")
    try expect(postServer.requests.count == 1, "POST must not be retried by default")

    // MARK: - Custom retrier

    let dropServer = StubServer()
    dropServer.stub(.get, url, json: User(id: 1, name: "Ada"))
    dropServer.stub(.get, url, error: URLError(.networkConnectionLost), times: 1)
    let reconnecting = dropServer.netti(interceptors: [ReconnectRetrier()])
    let reconnected = try await reconnecting.get(UserAPI.user(1))
    report("retrier  -> status \(reconnected.statusCode ?? 0) after a dropped connection")
    try expect(reconnected.statusCode == 200, "the custom retrier did not retry")

    // MARK: - Per-endpoint override

    let disabledServer = StubServer()
    disabledServer.stub(.get, "https://api.example.com/v1/payments", status: 503)
    let always = disabledServer.netti(retryPolicy: RetryPolicy())
    let payment = try await always.get(PaymentAPI.pay)
    report("endpoint -> status \(payment.statusCode ?? 0), attempts \(disabledServer.requests.count) (retryPolicy: .disabled)")
    try expect(disabledServer.requests.count == 1, "the endpoint override should disable retries")
}

// MARK: - Helpers

/// Sets headers every request needs; for a credential, prefer `AuthenticationInterceptor`.
private struct AppHeadersInterceptor: RequestInterceptor {
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        request.setValue("ios/5.0", forHTTPHeaderField: "X-Client")
        return request
    }
}

/// Retries once, after two seconds, when the connection is lost.
private struct ReconnectRetrier: RequestInterceptor {
    func retry(_ context: RetryContext) async -> RetryDecision {
        guard case .requestFailed(let error) = context.error,
              error.code == .networkConnectionLost,
              context.retryCount < 1 else {
            return .doNotRetry
        }
        return .retryAfter(.seconds(2))
    }
}

private struct RetryMonitor: EventMonitor {
    let delays: Recorder<Duration>

    func requestWillRetry(_ request: URLRequest, retryCount: Int, delay: Duration) {
        delays.append(delay)
    }
}

private enum PaymentAPI: HTTPRequest {
    case pay

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String { "payments" }
    var headers: HTTPHeaders { [.accept("application/json")] }
    var retryPolicy: RetryPolicy? { .disabled }
}
