import Foundation
import os
import Testing

@testable import Netti

@Suite("EventMonitor")
struct EventMonitorTests {
    /// Records the name of every event it receives, tagged with its own label.
    private struct RecordingMonitor: EventMonitor {
        let label: String
        let log: Recorder<String>

        func requestDidCreate(_ request: URLRequest) { log.append("\(label):create") }
        func requestDidAdapt(_ original: URLRequest, to adapted: URLRequest) { log.append("\(label):adapt") }
        func requestDidSend(_ request: URLRequest) { log.append("\(label):send") }
        func requestWillRetry(_ request: URLRequest, retryCount: Int, delay: Duration) { log.append("\(label):retry#\(retryCount)") }
        func requestDidReceiveResponse(_ response: HTTPResponse<Data>) { log.append("\(label):response") }
        func requestDidCollectMetrics(_ metrics: URLSessionTaskMetrics, for request: URLRequest) { log.append("\(label):metrics") }
        func requestDidFail(_ request: URLRequest, error: HTTPRequestError) { log.append("\(label):fail") }
    }

    /// Implements a single event and relies on the defaults for the rest.
    private struct ResponseOnlyMonitor: EventMonitor {
        let received: Counter

        func requestDidReceiveResponse(_ response: HTTPResponse<Data>) { received.increment() }
    }

    private func fire(_ monitor: some EventMonitor) {
        let request = makeURLRequest()
        monitor.requestDidCreate(request)
        monitor.requestDidAdapt(request, to: request)
        monitor.requestDidSend(request)
        monitor.requestWillRetry(request, retryCount: 1, delay: .seconds(1))
        monitor.requestDidReceiveResponse(makeResponse(status: 200))
        monitor.requestDidFail(request, error: .cancelled)
    }

    @Test("given a monitor implementing one event, when every event fires, then only that one is observed")
    func monitor_partialImplementation_isEnough() {
        let received = Counter()

        fire(ResponseOnlyMonitor(received: received))

        #expect(received.value == 1)
    }

    @Test("given two monitors, when events fire, then both receive every event in registration order")
    func composite_forwardsInOrder() {
        let log = Recorder<String>()
        let composite = CompositeEventMonitor([
            RecordingMonitor(label: "A", log: log),
            RecordingMonitor(label: "B", log: log),
        ])

        fire(composite)

        #expect(log.values == [
            "A:create", "B:create",
            "A:adapt", "B:adapt",
            "A:send", "B:send",
            "A:retry#1", "B:retry#1",
            "A:response", "B:response",
            "A:fail", "B:fail",
        ])
    }

    @Test("given a monitor, when metrics are collected, then it receives them with the request")
    func composite_forwardsMetrics() {
        let log = Recorder<String>()
        let composite = CompositeEventMonitor([RecordingMonitor(label: "A", log: log)])

        composite.requestDidCollectMetrics(URLSessionTaskMetrics(), for: makeURLRequest())

        #expect(log.values == ["A:metrics"])
    }

    @Test("given no monitors, when events fire, then nothing happens")
    func composite_empty_isNoOp() {
        fire(CompositeEventMonitor([]))
    }
}

@Suite("NetworkLogger")
struct NetworkLoggerTests {
    private func makeLogger(isEnabled: Bool = true) -> (NetworkLogger, Recorder<String>) {
        let messages = Recorder<String>()
        return (NetworkLogger(isEnabled: isEnabled) { _, message in messages.append(message) }, messages)
    }

    @Test("given a bearer token, when the request is logged, then the log does not contain the token")
    func log_bearerToken_isRedacted() {
        let (logger, messages) = makeLogger()
        let request = makeURLRequest(headers: ["Authorization": "Bearer abc123", "Accept": "application/json"])

        logger.requestDidSend(request)

        let output = messages.values.joined()
        #expect(output.contains("abc123") == false)
        #expect(output.contains("Authorization: \(NetworkLogger.redactionMarker)"))
        #expect(output.contains("Accept: application/json"))
    }

    @Test(
        "given a sensitive header in any letter case, when logged as cURL, then its value is redacted",
        arguments: ["Authorization", "authorization", "Proxy-Authorization", "COOKIE", "Cookie", "Set-Cookie"]
    )
    func asCurl_sensitiveHeaders_redacted(header: String) {
        let request = makeURLRequest(headers: [header: "secret-value"])

        let curl = request.asCurl()

        #expect(curl.contains("secret-value") == false)
        #expect(curl.contains(NetworkLogger.redactionMarker))
    }

    @Test("given a logged request, when rendered, then it is a reproducible cURL command")
    func asCurl_isReproducible() {
        var request = makeURLRequest(method: "POST", headers: ["Content-Type": "application/json"])
        request.httpBody = Data(#"{"a":1}"#.utf8)

        let curl = request.asCurl()

        #expect(curl.contains("-X POST"))
        #expect(curl.contains("-H \"Content-Type: application/json\""))
        #expect(curl.contains("-d '{\"a\":1}'"))
        #expect(curl.contains("\"\(TestURL.api.absoluteString)\""))
    }

    @Test("given a response, when received, then its method, URL and status are logged")
    func log_response_includesStatus() {
        let (logger, messages) = makeLogger()

        logger.requestDidReceiveResponse(makeResponse(status: 404, body: Data(#"{"error":"nope"}"#.utf8)))

        let output = messages.values.joined()
        #expect(output.contains("GET"))
        #expect(output.contains(TestURL.api.absoluteString))
        #expect(output.contains("404"))
    }

    @Test("given a failure, when it is reported, then it is logged as an error")
    func log_failure_isAnError() {
        let levels = Recorder<OSLogType>()
        let logger = NetworkLogger { level, _ in levels.append(level) }

        logger.requestDidFail(makeURLRequest(), error: .cancelled)

        #expect(levels.values == [.error])
    }

    @Test("given logging disabled, when every event fires, then nothing is emitted")
    func log_disabled_emitsNothing() {
        let (logger, messages) = makeLogger(isEnabled: false)
        let request = makeURLRequest(headers: ["Authorization": "Bearer abc123"])

        logger.requestDidSend(request)
        logger.requestDidReceiveResponse(makeResponse(status: 200))
        logger.requestDidFail(request, error: .cancelled)
        logger.log(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")), type: Int.self, data: Data())

        #expect(messages.values.isEmpty)
    }

    @Test("given the logger, when used as a monitor, then it composes with others")
    func logger_isAMonitor() {
        let (logger, messages) = makeLogger()
        let composite = CompositeEventMonitor([logger])

        composite.requestDidSend(makeURLRequest())

        #expect(messages.values.count == 1)
    }
}
