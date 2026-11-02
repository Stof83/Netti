import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

// MARK: - Seeded Random

/// SplitMix64: a deterministic generator, so every chaos run injects the same bytes.
struct ChaosRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

// MARK: - Chaos Responses

/// Hostile server behaviours, written byte for byte on the socket.
extension LocalHTTPServer.Response {
    /// A well-formed body every chaos response is cut from.
    static let chaosBody = testPayload(count: 4096)

    /// A raw response head; `headers` are written in order, exactly as given.
    static func rawHead(statusLine: String = "HTTP/1.1 200 OK", _ headers: [(String, String)]) -> Data {
        let lines = [statusLine] + headers.map { "\($0.0): \($0.1)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// A complete, valid response with `Content-Length`.
    static func validRaw(_ body: Data = chaosBody) -> Data {
        rawHead([("Content-Length", "\(body.count)"), ("Connection", "close")]) + body
    }

    static func script(_ steps: LocalHTTPServer.Response.Step...) -> LocalHTTPServer.Response {
        LocalHTTPServer.Response(body: .script(steps))
    }

    /// Reads the request, then closes without sending a byte.
    static let closeBeforeHead = script()

    /// Reads the request, then tears the connection down without a graceful close.
    static let resetBeforeHead = script(.reset)

    /// Declares the whole body, sends `sending` bytes of it, then closes.
    static func closeMidBody(sending: Int = 1024) -> LocalHTTPServer.Response {
        script(.send(rawHead([("Content-Length", "\(chaosBody.count)"), ("Connection", "close")]) + chaosBody.prefix(sending)))
    }

    /// Declares the whole body, sends `sending` bytes, then resets the connection.
    static func resetMidBody(sending: Int = 1024) -> LocalHTTPServer.Response {
        script(.send(rawHead([("Content-Length", "\(chaosBody.count)"), ("Connection", "close")]) + chaosBody.prefix(sending)), .pause(.milliseconds(20)), .reset)
    }

    /// Declares `declared` bytes, sends `body`, then closes.
    static func contentLength(declared: Int, body: Data = chaosBody) -> LocalHTTPServer.Response {
        script(.send(rawHead([("Content-Length", "\(declared)"), ("Connection", "close")]) + body))
    }

    /// Sends the head, then the body `count` bytes per `interval`; with `closeAfter`, declares the
    /// whole body but closes once that many bytes are out.
    ///
    /// With `closeWhen`, the close waits until it holds. `URLSession` discards bytes it has read but
    /// not yet handed to its delegate when the connection ends early, so a test that counts the bytes
    /// before the close holds the close until the client has read them.
    static func drip(
        count: Int,
        every interval: Duration,
        body: Data = chaosBody,
        closeAfter: Int? = nil,
        closeWhen: (@Sendable () -> Bool)? = nil
    ) -> LocalHTTPServer.Response {
        let head = rawHead([("Content-Length", "\(body.count)"), ("Connection", "close")])
        let steps: [LocalHTTPServer.Response.Step] = [.send(head), .drip(body.prefix(closeAfter ?? body.count), count: count, interval: interval)]
        return LocalHTTPServer.Response(body: .script(steps + (closeWhen.map { [.waitUntil($0)] } ?? [])))
    }

    /// A chunked head, then `chunks` 16-byte chunks, one per `interval`, then a close with no last chunk.
    static func chunkedDrip(chunks: Int, every interval: Duration) -> LocalHTTPServer.Response {
        let framing = (0..<chunks).map { "10\r\n\(String(format: "%016d", $0))\r\n" }.joined()
        let head = rawHead([("Transfer-Encoding", "chunked"), ("Connection", "close")])
        return script(.send(head), .drip(Data(framing.utf8), count: 22, interval: interval))
    }

    /// A chunked head followed by `framing`, written as is, then a close.
    static func chunked(_ framing: String) -> LocalHTTPServer.Response {
        script(.send(rawHead([("Transfer-Encoding", "chunked"), ("Connection", "close")]) + Data(framing.utf8)))
    }

    /// `count` distinct headers before an otherwise valid response.
    static func headerFlood(count: Int) -> LocalHTTPServer.Response {
        let flood = (0..<count).map { ("X-Flood-\($0)", "v") }
        return script(.send(rawHead(flood + [("Content-Length", "2"), ("Connection", "close")]) + Data("ok".utf8)))
    }

    /// One header whose value is `bytes` long.
    static func headerBlock(bytes: Int) -> LocalHTTPServer.Response {
        let value = String(repeating: "a", count: bytes)
        return script(.send(rawHead([("X-Block", value), ("Content-Length", "2"), ("Connection", "close")]) + Data("ok".utf8)))
    }

    /// A valid response with bytes of the head or body overwritten by `seed`-determined values.
    static func injected(seed: UInt64, into region: ChaosRegion, count: Int = 4) -> LocalHTTPServer.Response {
        var random = ChaosRandom(seed: seed)
        var bytes = [UInt8](validRaw())
        let headLength = validRaw(Data()).count
        let range = region == .head ? 0..<headLength : headLength..<bytes.count
        for _ in 0..<count {
            bytes[Int.random(in: range, using: &random)] = UInt8.random(in: .min ... .max, using: &random)
        }
        return script(.send(Data(bytes)))
    }

    /// Reads the request and answers nothing until the client gives up.
    static let silence = script(.waitForDisconnect)

    /// Sends `bytes` as the whole response, then closes.
    static func raw(_ bytes: Data) -> LocalHTTPServer.Response {
        script(.send(bytes))
    }
}

enum ChaosRegion: String, Sendable, CaseIterable {
    case head
    case body
}

// MARK: - Client

/// An endpoint on a chaos server, with a short timeout so a stalled call fails fast.
struct ChaosEndpoint: HTTPRequest {
    let url: URL
    var headers: HTTPHeaders = [:]
    var timeoutInterval: TimeInterval = 2
    var retryPolicy: RetryPolicy?

    var baseURL: URL? { url }
    var basePath: String { "" }
    var path: String { "" }
    var requestURL: URL { url }
}

/// A chaos server: `/ok` always answers `ok`; every other path is answered by `chaos`.
func makeChaosServer(_ chaos: @escaping LocalHTTPServer.Handler) async throws -> LocalHTTPServer {
    try await LocalHTTPServer.start { request in
        request.path == "/ok" ? .text("ok") : await chaos(request)
    }
}

/// A real `URLSession` client with retry sleeps recorded instead of slept.
func makeChaosNetti(
    service: URLSessionNetworkService = URLSessionNetworkService(configuration: .ephemeral),
    retryPolicy: RetryPolicy? = nil,
    deduplicatesRequests: Bool = true
) -> Netti {
    makeNetti(service: service, retryPolicy: retryPolicy, deduplicatesRequests: deduplicatesRequests)
}

/// Runs `operation` and returns its result, or records a hang and returns `nil` once `limit`
/// passes; a hung operation is cancelled and left behind, so the test never blocks on it.
func withinBound<Value: Sendable>(
    _ limit: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: @escaping @Sendable () async -> Value
) async -> Value? {
    let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
    let task = Task {
        let value = await operation()
        result.withLock { $0 = value }
    }
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if let value = result.withLock({ $0 }) {
            return value
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if let value = result.withLock({ $0 }) {
        return value
    }
    task.cancel()
    Issue.record("Operation did not finish within \(limit)", sourceLocation: sourceLocation)
    return nil
}

/// Sends a `GET` and returns the outcome; never throws.
func chaosGET(_ netti: Netti, _ endpoint: ChaosEndpoint) async -> Result<HTTPResponse<Empty>, HTTPRequestError> {
    do {
        return .success(try await netti.get(endpoint))
    } catch {
        return .failure(error)
    }
}

/// Records an issue unless `netti` still completes a plain `GET` on `server`.
func expectClientUsable(_ netti: Netti, on server: LocalHTTPServer, sourceLocation: SourceLocation = #_sourceLocation) async {
    let endpoint = ChaosEndpoint(url: server.url("/ok"))
    let outcome = await withinBound(sourceLocation: sourceLocation) { await chaosGET(netti, endpoint) }
    switch outcome {
        case .success(let response):
            #expect(response.statusCode == 200, sourceLocation: sourceLocation)
            #expect(response.rawData == Data("ok".utf8), sourceLocation: sourceLocation)
        case .failure(let error):
            Issue.record("Client wedged after chaos: \(error)", sourceLocation: sourceLocation)
        case nil:
            break
    }
}

/// A weak reference that can cross concurrency domains, for deallocation checks.
final class WeakReference<Object: AnyObject>: @unchecked Sendable {
    weak var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}

extension Result where Failure == HTTPRequestError {
    var failure: HTTPRequestError? {
        guard case .failure(let error) = self else {
            return nil
        }
        return error
    }
}
