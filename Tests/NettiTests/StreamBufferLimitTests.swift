import Foundation
import Testing

@testable import Netti

/// TM-09: byte-stream and WebSocket receive buffers fail instead of growing without bound when the
/// consumer falls behind.
@Suite("Stream buffer limits", .timeLimit(.minutes(1)))
struct StreamBufferLimitTests {

    // MARK: - Meter

    @Test("given elements yielded and consumed, when recorded, then only the unread bytes count")
    func meter_countsUnreadBytes() {
        var meter = StreamBufferMeter()

        #expect(meter.record(size: 10, bufferedCount: 1) == 10)
        #expect(meter.record(size: 20, bufferedCount: 2) == 30)
        #expect(meter.record(size: 5, bufferedCount: 1) == 5)
        #expect(meter.record(size: 7, bufferedCount: 0) == 0)
        #expect(meter.record(size: 3, bufferedCount: 1) == 3)
    }

    @Test("given many elements, when the consumer keeps up, then the meter stays at zero")
    func meter_compacts() {
        var meter = StreamBufferMeter()

        for _ in 0..<10_000 {
            #expect(meter.record(size: 100, bufferedCount: 1) == 100)
        }
        #expect(meter.record(size: 1, bufferedCount: 0) == 0)
    }

    @Test("given the defaults, then streams buffer at most 8 MB and WebSockets 1,000 messages")
    func defaults() {
        #expect(StreamBufferMeter.defaultByteLimit == 8 * 1024 * 1024)
        #expect(StreamBufferMeter.defaultMessageLimit == 1_000)
    }

    // MARK: - Byte Stream

    @Test("given a reader that does not consume, when the body outruns the buffer limit, then the stream fails with dataLengthExceedsMaximum")
    func bytes_slowReader_fails() async throws {
        // Four times the buffer limit, and no last chunk: the body never completes on its own, so the
        // only way the server sees a disconnect is the client cancelling at the cap. A finite body could
        // reach a slow client in one delivery, whole, before the cap is checked.
        let server = try await LocalHTTPServer.start { _ in
            .unterminatedChunks(Array(repeating: String(repeating: "x", count: 1024), count: 16))
        }
        defer { server.stop() }
        let delegate = SessionDelegate(trustEvaluator: nil, maximumBufferedStreamBytes: 4 * 1024)
        let service = URLSessionNetworkService(configuration: .ephemeral, delegate: delegate)

        let stream = try await service.bytes(for: URLRequest(url: server.url("/")))
        #expect(await server.wait { $0.disconnects == 1 })

        var received = 0
        let error = await expectRequestError { () async throws(HTTPRequestError) in
            do {
                for try await chunk in stream.body {
                    received += chunk.count
                }
            } catch let error as HTTPRequestError {
                throw error
            } catch {
                Issue.record("Unexpected error \(error)")
            }
        }

        #expect(error?.urlErrorCode == .dataLengthExceedsMaximum)
        #expect(received < 64 * 1024)
    }

    // MARK: - WebSocket

    @Test("given a reader that does not consume, when more messages arrive than the limit, then messages fail with dataLengthExceedsMaximum")
    func webSocket_messageLimit_fails() async throws {
        try await Self.expectOverflow(messageCount: 20, payload: "m", messageLimit: 10, byteLimit: .max)
    }

    @Test("given a reader that does not consume, when more bytes arrive than the limit, then messages fail with dataLengthExceedsMaximum")
    func webSocket_byteLimit_fails() async throws {
        try await Self.expectOverflow(messageCount: 20, payload: String(repeating: "b", count: 100), messageLimit: 1_000, byteLimit: 500)
    }
}

// MARK: - Helpers

private extension StreamBufferLimitTests {
    static func expectOverflow(
        messageCount: Int,
        payload: String,
        messageLimit: Int,
        byteLimit: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let server = try await LocalWebSocketServer.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: server.url)
        task.resume()
        let transport = URLSessionWebSocketTransport(task: task, maximumBufferedMessages: messageLimit, maximumBufferedBytes: byteLimit)

        for _ in 0..<messageCount {
            // The connection closes on overflow, so later sends may fail.
            try? await transport.send(.text(payload))
        }
        #expect(await eventually { task.state != .running }, "the connection was not closed on overflow", sourceLocation: sourceLocation)

        var received = 0
        do {
            for try await _ in transport.messages {
                received += 1
            }
            Issue.record("Expected the messages to fail", sourceLocation: sourceLocation)
        } catch let error as HTTPRequestError {
            #expect(error.urlErrorCode == .dataLengthExceedsMaximum, sourceLocation: sourceLocation)
        }
        #expect(received < messageCount, sourceLocation: sourceLocation)
    }
}
