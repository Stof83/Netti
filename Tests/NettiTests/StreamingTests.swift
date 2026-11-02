import Foundation
import Testing

@testable import Netti
import NettiTesting

@Suite("Streaming", .timeLimit(.minutes(1)))
struct StreamingTests {

    // MARK: - Lines

    @Test("given a line split across chunks, when read as lines, then it is yielded once, whole")
    func lines_spanChunks() async throws {
        let lines = try await collect(AsyncLineSequence(chunks("hel", "lo\n")))

        #expect(lines == ["hello"])
    }

    @Test("given LF and CRLF terminators and a final unterminated line, when read as lines, then every line is yielded without terminators")
    func lines_handleTerminators() async throws {
        let lines = try await collect(AsyncLineSequence(chunks("one\r\ntwo\n\nthr", "ee\r", "\nlast")))

        #expect(lines == ["one", "two", "", "three", "last"])
    }

    @Test("given a multi-byte character split across chunks, when read as lines, then it decodes intact")
    func lines_keepUTF8Intact() async throws {
        let bytes = Data("café\n".utf8)
        let lines = try await collect(AsyncLineSequence(chunks(bytes.prefix(4), bytes.dropFirst(4))))

        #expect(lines == ["café"])
    }

    // MARK: - Bounds

    @Test("given 10 MB in one-byte chunks without a line break, when read as lines, then it throws at the cap in linear time")
    func lines_slowDrip_throwsAtCapInLinearTime() async {
        let clock = ContinuousClock()
        let start = clock.now
        var thrown: (any Error)?
        do {
            for try await _ in AsyncLineSequence(OneByteChunks(count: 10_000_000)) {}
        } catch {
            thrown = error
        }

        #expect((thrown as? HTTPRequestError)?.urlErrorCode == .dataLengthExceedsMaximum)
        // Linear work at the cap is milliseconds; the quadratic rescan this guards against takes hours.
        // The bound is loose so that sanitizer builds, which run several times slower, still pass.
        #expect(clock.now - start < .seconds(20))
    }

    @Test("given a line of exactly the maximum length, when read as lines, then it is yielded")
    func lines_atCap_isYielded() async throws {
        let lines = try await collect(AsyncLineSequence(chunks("abcd\r\n", "efgh"), maximumLineLength: 4))

        #expect(lines == ["abcd", "efgh"])
    }

    @Test("given a line one byte over the maximum, complete or not, when read as lines, then it throws", arguments: [
        ["abcde\n"], ["ab", "cde"], ["ok\nabcde"],
    ])
    func lines_overCap_throws(parts: [String]) async {
        var thrown: (any Error)?
        do {
            _ = try await collect(AsyncLineSequence(chunks(parts.map { Data($0.utf8) }), maximumLineLength: 4))
        } catch {
            thrown = error
        }

        #expect((thrown as? HTTPRequestError)?.urlErrorCode == .dataLengthExceedsMaximum)
    }

    @Test("given the default line sequence, when read, then its cap is 1 MB")
    func lines_defaultCap() {
        #expect(AsyncLineSequence(chunks([Data]())).maximumLineLength == 1_048_576)
    }

    // MARK: - Netti

    @Test("given a streaming endpoint, when streamed through Netti, then adapters apply and the server-sent events arrive")
    func stream_throughPipeline() async throws {
        let service = StubNetworkService(bytes: { request in
            HTTPStreamResponse(
                request: request,
                response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"]),
                body: chunks("data: one\n\n", "event: tick\ndata: two\n\n")
            )
        })
        let adapter = ClosureAdapter { request in
            var request = request
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            return request
        }

        let stream = try await makeNetti(service: service, interceptors: [adapter]).stream(TestEndpoint())
        let events = try await collect(stream.serverSentEvents)

        #expect(events == [ServerSentEvent(data: "one"), ServerSentEvent(event: "tick", data: "two")])
        #expect(service.requests.first?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(service.requests.first?.httpMethod == "GET")
    }

    @Test("given validation and a 503 stream response, when streamed, then unacceptableStatusCode is thrown before the body is read")
    func stream_validatesStatus() async {
        let service = StubNetworkService(bytes: { request in
            HTTPStreamResponse(
                request: request,
                response: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil),
                body: chunks("unavailable")
            )
        })

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPStreamResponse in
            try await makeNetti(service: service, validation: ResponseValidation()).stream(TestEndpoint())
        }

        guard case .unacceptableStatusCode(503, _)? = error else {
            Issue.record("Expected unacceptableStatusCode(503), got \(String(describing: error))")
            return
        }
    }

    @Test("given a chunked server, when its lines are consumed, then each line arrives before the next chunk is sent")
    func stream_linesArriveIncrementally() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let server = try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(
                headers: ["Content-Type": "text/plain", "X-Content-Type-Options": "nosniff"],
                body: .chunks([
                    .init("first\n"),
                    .init("second\n") {
                        for await _ in gate {
                            break
                        }
                    },
                ])
            )
        }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))

        var received: [String] = []
        for try await line in try await netti.stream(URLEndpoint(server.url("/lines"))).lines {
            received.append(line)
            if received == ["first"] {
                release.yield()
            }
        }

        #expect(received == ["first", "second"])
    }

    @Test("given a stream, when the consumer stops after the first line, then the transfer is cancelled")
    func stream_earlyExitCancels() async throws {
        let server = try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(
                headers: ["Content-Type": "application/octet-stream", "X-Content-Type-Options": "nosniff"],
                body: .stall(prefix: Data("first\n".utf8), contentLength: 1_000_000)
            )
        }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))

        try await Task {
            for try await _ in try await netti.stream(URLEndpoint(server.url("/stall"))).lines {
                break
            }
        }.value

        #expect(await server.wait { $0.disconnects == 1 })
    }

    // MARK: - Helpers

    private func collect<S: AsyncSequence>(_ sequence: S) async throws -> [S.Element] {
        var elements: [S.Element] = []
        for try await element in sequence {
            elements.append(element)
        }
        return elements
    }
}

/// A finished stream of the given chunks.
func chunks(_ parts: String...) -> AsyncThrowingStream<Data, any Error> {
    chunks(parts.map { Data($0.utf8) })
}

func chunks(_ parts: Data...) -> AsyncThrowingStream<Data, any Error> {
    chunks(parts)
}

func chunks(_ parts: [Data]) -> AsyncThrowingStream<Data, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    parts.forEach { continuation.yield($0) }
    continuation.finish()
    return stream
}

/// `count` chunks of one byte each, made on demand, with no line break.
private struct OneByteChunks: AsyncSequence, Sendable {
    typealias Element = Data

    let count: Int

    func makeAsyncIterator() -> Iterator {
        Iterator(remaining: count)
    }

    struct Iterator: AsyncIteratorProtocol {
        var remaining: Int

        mutating func next() async -> Data? {
            guard remaining > 0 else {
                return nil
            }
            remaining -= 1
            return Data([UInt8(ascii: "a")])
        }
    }
}
