//
//  Observability.swift
//  Netti
//

import Foundation
import NettiTesting

/// Watching the request lifecycle with an `EventMonitor`, and what the logger redacts.
///
/// Runs offline: a `StubServer` answers, and the monitor records each event in order. The
/// built-in logger writes to the unified system log (subsystem `Netti`), so it is turned off here.
func observabilityExample() async throws {
    let server = StubServer()
    let url = "https://api.example.com/v1/users/1"
    server.stub(.get, url, json: User(id: 1, name: "Ada"))
    server.stub(.get, url, status: 503, times: 1)

    // MARK: - Monitor

    let monitor = LifecycleMonitor()
    let netti = server.netti(
        interceptors: [.idempotencyKey],
        retryPolicy: RetryPolicy(),
        monitors: [monitor]
    )
    let response: HTTPResponse<User> = try await netti.get(UserAPI.user(1))
    report("events   -> \(monitor.events.values.joined(separator: " > "))")
    report("response -> status \(response.statusCode ?? 0), metrics collected: \(response.metrics != nil)")
    try expect(monitor.events.values.contains("retry"), "expected a retry event")
    try expect(monitor.events.values.contains("response"), "expected a response event")

    // MARK: - Redaction

    // Descriptions of headers hide credentials; so does the logger, and so does the description
    // of a thrown error. Your own monitors are not redacted: redact before forwarding anything.
    let headers: HTTPHeaders = [.authorization(bearerToken: "example-token-do-not-use"), .accept("application/json")]
    let description = "\(headers)"
    report("headers  -> \(description.replacingOccurrences(of: "\n", with: "; "))")
    try expect(description.contains("example-token-do-not-use") == false, "the credential leaked into a description")
}

// MARK: - Helpers

/// Notes the name of every event, in order. Events arrive synchronously on the request's task:
/// keep them cheap and hand heavy work to another task.
private struct LifecycleMonitor: EventMonitor {
    let events = Recorder<String>()

    func requestDidCreate(_ request: URLRequest) { events.append("create") }
    func requestDidAdapt(_ original: URLRequest, to adapted: URLRequest) { events.append("adapt") }
    func requestDidSend(_ request: URLRequest) { events.append("send") }
    func requestWillRetry(_ request: URLRequest, retryCount: Int, delay: Duration) { events.append("retry") }
    func requestDidReceiveResponse(_ response: HTTPResponse<Data>) { events.append("response") }
    func requestDidCollectMetrics(_ metrics: URLSessionTaskMetrics, for request: URLRequest) { events.append("metrics") }
    func requestDidFail(_ request: URLRequest, error: HTTPRequestError) { events.append("fail") }
}
