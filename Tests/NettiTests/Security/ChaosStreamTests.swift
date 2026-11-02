import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

/// S.11: streamed bodies over a drip that stops dead. The sequence throws or finishes; it never hangs.
@Suite("Chaos: streams", .timeLimit(.minutes(1)))
struct ChaosStreamTests {

    @Test("given a dripped body that closes before its Content-Length, when read as bytes, then the stream throws networkConnectionLost after the bytes sent")
    func bytes_dripThenClose_throws() async throws {
        let consumed = OSAllocatedUnfairLock(initialState: 0)
        let server = try await makeChaosServer { _ in
            .drip(count: 64, every: .milliseconds(10), closeAfter: 1024) { consumed.withLock { $0 } >= 1024 }
        }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let stream = try await netti.stream(ChaosEndpoint(url: server.url("/chaos")))

        let read = try #require(await withinBound { await Self.drain(stream.body, counting: consumed) })

        #expect(read.count == 1024)
        #expect((read.error as? HTTPRequestError)?.urlErrorCode == .networkConnectionLost, "\(String(describing: read.error))")
        await expectClientUsable(netti, on: server)
    }

    @Test("given dripped lines that close before their Content-Length, when read as lines, then the sequence throws after the complete lines")
    func lines_dripThenClose_throws() async throws {
        let text = Data((0..<100).map { "line \($0)\n" }.joined().utf8)
        // Past URLSession's 512-byte content sniffing, so the head is delivered before the close.
        let server = try await makeChaosServer { _ in .drip(count: 7, every: .milliseconds(2), body: text, closeAfter: 600) }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let stream = try await netti.stream(ChaosEndpoint(url: server.url("/chaos")))

        let read = try #require(await withinBound { await Self.drainLines(stream.lines) })

        #expect(read.count > 0)
        #expect(read.count < 100)
        #expect((read.error as? HTTPRequestError)?.urlErrorCode == .networkConnectionLost, "\(String(describing: read.error))")
        await expectClientUsable(netti, on: server)
    }

    @Test("given dripped chunks that stop without the last chunk, when read as bytes, then the stream ends within the bound and reports the truncation")
    func bytes_chunkedDripThenClose_ends() async throws {
        let server = try await makeChaosServer { _ in .chunkedDrip(chunks: 8, every: .milliseconds(10)) }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let stream = try await netti.stream(ChaosEndpoint(url: server.url("/chaos")))

        let read = try #require(await withinBound { await Self.drain(stream.body) })

        #expect(read.count == 8 * 16)
        withKnownIssue("TM-chaos-2: a chunked body cut off before its last chunk ends the stream as if complete") {
            #expect(read.error is HTTPRequestError)
        }
        await expectClientUsable(netti, on: server)
    }

    @Test("given a drip that closes before URLSession has sniffed the body, when the stream is opened, then opening fails with networkConnectionLost within the bound")
    func open_dripClosedBeforeHeadDelivered_throws() async throws {
        let server = try await makeChaosServer { _ in .drip(count: 7, every: .milliseconds(5), closeAfter: 140) }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let endpoint = ChaosEndpoint(url: server.url("/chaos"))

        let outcome = try #require(await withinBound { await Self.open(netti, endpoint) })

        #expect(outcome.failure?.urlErrorCode == .networkConnectionLost, "\(outcome)")
        await expectClientUsable(netti, on: server)
    }

    @Test("given a drip slower than the timeout after the head, when read as bytes, then the stream throws timedOut")
    func bytes_dripPastTimeout_throws() async throws {
        let body = LocalHTTPServer.Response.chaosBody
        let head = LocalHTTPServer.Response.rawHead([("Content-Length", "\(body.count)"), ("Connection", "close")])
        let server = try await makeChaosServer { _ in
            .script(.send(head + body.prefix(1024)), .drip(body.dropFirst(1024), count: 1, interval: .seconds(2)))
        }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let stream: HTTPStreamResponse
        do {
            stream = try await netti.stream(ChaosEndpoint(url: server.url("/chaos"), timeoutInterval: 0.5))
        } catch {
            // On a slow machine (sanitizer builds) the idle timeout can fire before the head is delivered.
            #expect((error as? HTTPRequestError)?.urlErrorCode == .timedOut, "\(error)")
            await expectClientUsable(netti, on: server)
            return
        }

        let read = try #require(await withinBound(.seconds(4)) { await Self.drain(stream.body) })

        #expect((read.error as? HTTPRequestError)?.urlErrorCode == .timedOut, "\(String(describing: read.error))")
        await expectClientUsable(netti, on: server)
    }

    @Test("given a stream reading a slow drip, when its task is cancelled, then iteration ends promptly and the transfer is torn down")
    func bytes_cancelDuringDrip_endsPromptly() async throws {
        let server = try await makeChaosServer { _ in .drip(count: 16, every: .milliseconds(100)) }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let stream = try await netti.stream(ChaosEndpoint(url: server.url("/chaos"), timeoutInterval: 5))
        let task = Task { await Self.drain(stream.body) }
        try await Task.sleep(for: .milliseconds(150))

        let start = ContinuousClock.now
        task.cancel()
        let read = await withinBound(.seconds(2)) { await task.value }

        #expect(read != nil)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await server.wait { $0.disconnects == 1 })
    }
}

// MARK: - Helpers

private extension ChaosStreamTests {
    /// What a stream delivered before it ended: bytes for data, elements otherwise, and the error it threw.
    struct Read: Sendable {
        var count = 0
        var error: (any Error)?
    }

    static func open(_ netti: Netti, _ endpoint: ChaosEndpoint) async -> Result<HTTPStreamResponse, HTTPRequestError> {
        do {
            return .success(try await netti.stream(endpoint))
        } catch {
            return .failure(error)
        }
    }

    /// Reads `body` to its end; `consumed`, when given, tracks the bytes read so far for the server.
    static func drain(_ body: AsyncThrowingStream<Data, any Error>, counting consumed: OSAllocatedUnfairLock<Int>? = nil) async -> Read {
        var read = Read()
        do {
            for try await chunk in body {
                read.count += chunk.count
                consumed?.withLock { $0 += chunk.count }
            }
        } catch {
            read.error = error
        }
        return read
    }

    static func drainLines<Lines: AsyncSequence>(_ lines: Lines) async -> Read {
        var read = Read()
        do {
            for try await _ in lines {
                read.count += 1
            }
        } catch {
            read.error = error
        }
        return read
    }
}
