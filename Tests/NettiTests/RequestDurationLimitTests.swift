import Foundation
import Testing

@testable import Netti

/// TM-06: data and upload requests are bounded by `maximumRequestDuration`, a total deadline, so a
/// server that drips bytes cannot hold them open (slow-loris). Byte streams, WebSockets and downloads
/// are exempt, so a live feed outlives the deadline.
@Suite("Request duration limit", .timeLimit(.minutes(1)))
struct RequestDurationLimitTests {

    private static let deadline = Duration.seconds(1)

    // MARK: - Data and Upload

    @Test("given a server that drips a body, when the deadline passes, then the data request fails with timedOut at the deadline")
    func data_drip_timesOut() async throws {
        let server = try await Self.startDripServer(body: LocalHTTPServer.Response.chaosBody)
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumRequestDuration: Self.deadline)
        let request = URLRequest(url: server.url("/drip"))

        let timed = await Self.timed { () async throws(HTTPRequestError) in
            _ = try await service.data(for: request)
        }
        let outcome = try #require(timed)

        #expect(outcome.error?.urlErrorCode == .timedOut)
        #expect(outcome.elapsed >= .milliseconds(900))
        #expect(await server.wait { $0.disconnects == 1 })
    }

    @Test("given a server that drips the response to an upload, when the deadline passes, then the upload fails with timedOut at the deadline")
    func upload_drip_timesOut() async throws {
        let server = try await Self.startDripServer(body: LocalHTTPServer.Response.chaosBody)
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumRequestDuration: Self.deadline)
        let request = Self.post(server.url("/drip"))

        let timed = await Self.timed { () async throws(HTTPRequestError) in
            _ = try await service.upload(for: request, from: .data(Data("body".utf8)), progress: nil)
        }
        let outcome = try #require(timed)

        #expect(outcome.error?.urlErrorCode == .timedOut)
        #expect(outcome.elapsed >= .milliseconds(900))
        #expect(await server.wait { $0.disconnects == 1 })
    }

    @Test("given a fast request, when it finishes before the deadline, then it succeeds and its deadline cancels nothing later")
    func data_fast_succeedsWithoutStrayCancellation() async throws {
        let slowBody = testPayload(count: 30)
        let slowHead = LocalHTTPServer.Response.rawHead([("Content-Length", "\(slowBody.count)"), ("Connection", "close")])
        let server = try await LocalHTTPServer.start { request in
            request.path == "/slow" ? .script(.send(slowHead), .drip(slowBody, count: 1, interval: .milliseconds(50))) : .text("ok")
        }
        defer { server.stop() }
        let delegate = SessionDelegate(trustEvaluator: nil, maximumRequestDuration: .seconds(2))
        let service = URLSessionNetworkService(configuration: .ephemeral, delegate: delegate)
        let start = ContinuousClock.now

        let fast = try await service.data(for: URLRequest(url: server.url("/fast")))
        try await Task.sleep(until: start + .seconds(1))
        // Runs for about 1.5 s, across the fast request's deadline and well inside its own.
        let slow = try await service.data(for: URLRequest(url: server.url("/slow")))

        #expect(fast.rawData == Data("ok".utf8))
        #expect(slow.rawData == slowBody)
        #expect(ContinuousClock.now - start > .seconds(2))
        #expect(delegate.registeredTaskCount == 0)
    }

    // MARK: - Exempt

    @Test("given a stream that lasts longer than the deadline, when read, then it is read to the end without timedOut")
    func stream_outlivesDeadline() async throws {
        let body = testPayload(count: 40)
        let server = try await Self.startDripServer(
            body: body,
            headers: [("Content-Type", "application/octet-stream"), ("X-Content-Type-Options", "nosniff")]
        )
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumRequestDuration: Self.deadline)
        let netti = makeNetti(service: service)
        let start = ContinuousClock.now

        var received = Data()
        for try await chunk in try await netti.stream(URLEndpoint(server.url("/drip"))).body {
            received.append(chunk)
        }

        #expect(received == body)
        #expect(ContinuousClock.now - start > Self.deadline)
    }

    @Test("given a WebSocket open longer than the deadline, when used after it, then it still sends and receives")
    func webSocket_outlivesDeadline() async throws {
        let server = try await LocalWebSocketServer.start()
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumRequestDuration: Self.deadline)

        let socket = try await service.webSocket(for: URLRequest(url: server.url))
        defer { socket.close(with: .normalClosure, reason: nil) }
        var messages = socket.messages.makeAsyncIterator()
        try await socket.send(.text("before"))
        #expect(try await messages.next() == .text("before"))

        try await Task.sleep(for: Self.deadline + .milliseconds(500))

        try await socket.send(.text("after"))
        #expect(try await messages.next() == .text("after"))
    }
}

// MARK: - Helpers

private extension RequestDurationLimitTests {
    /// The error a call threw, if any, and how long it took.
    struct Outcome: Sendable {
        let error: HTTPRequestError?
        let elapsed: Duration
    }

    /// Declares `body`, then sends it one byte every 50 ms.
    static func startDripServer(body: Data, headers: [(String, String)] = []) async throws -> LocalHTTPServer {
        let head = LocalHTTPServer.Response.rawHead(headers + [("Content-Length", "\(body.count)"), ("Connection", "close")])
        return try await LocalHTTPServer.start { _ in
            .script(.send(head), .drip(body, count: 1, interval: .milliseconds(50)))
        }
    }

    /// A `POST` request to `url`.
    static func post(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        return request
    }

    /// Runs `call` within a 10 s bound and returns what it threw and how long it took.
    static func timed(_ call: @escaping @Sendable () async throws(HTTPRequestError) -> Void) async -> Outcome? {
        await withinBound(.seconds(10)) {
            let start = ContinuousClock.now
            do throws(HTTPRequestError) {
                try await call()
                return Outcome(error: nil, elapsed: ContinuousClock.now - start)
            } catch {
                return Outcome(error: error, elapsed: ContinuousClock.now - start)
            }
        }
    }
}
