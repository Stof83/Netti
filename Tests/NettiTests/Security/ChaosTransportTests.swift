import Foundation
import Testing

@testable import Netti
import NettiTesting

/// S.11: hostile and broken servers over real sockets. Each behaviour ends the call with an
/// `HTTPRequestError`, or a response where HTTP allows one, within a bound, and leaves the client
/// able to send its next request.
@Suite("Chaos: transport", .timeLimit(.minutes(1)))
struct ChaosTransportTests {

    /// A broken server behaviour and the outcome HTTP semantics allow for it.
    enum Behaviour: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case closeBeforeHead
        case resetBeforeHead
        case closeMidBody
        case resetMidBody
        case contentLengthLongerThanBody
        case garbageStatusLine
        case nonNumericStatus
        case binaryStatusLine
        case badChunkSize
        case missingChunkCRLF
        case truncatedLastChunk
        case missingTerminalChunk
        case headerFlood
        case headerBlock

        var testDescription: String {
            rawValue
        }

        /// A defect this behaviour exposes, recorded as a known issue until it is fixed.
        var knownIssue: Comment? {
            switch self {
                case .garbageStatusLine, .nonNumericStatus, .binaryStatusLine:
                    "TM-chaos-1: a malformed status line is answered as a synthesized 200 whose body is the raw bytes"
                case .missingTerminalChunk:
                    "TM-chaos-2: a chunked body cut off before its last chunk is returned as a complete 200"
                default:
                    nil
            }
        }

        /// Whether HTTP allows a response: a large but well-formed head parses.
        var isAcceptable: Bool {
            self == .headerFlood || self == .headerBlock
        }

        var response: LocalHTTPServer.Response {
            switch self {
                case .closeBeforeHead:
                    .closeBeforeHead
                case .resetBeforeHead:
                    .resetBeforeHead
                case .closeMidBody:
                    .closeMidBody()
                case .resetMidBody:
                    .resetMidBody()
                case .contentLengthLongerThanBody:
                    .contentLength(declared: LocalHTTPServer.Response.chaosBody.count * 2)
                case .garbageStatusLine:
                    .raw(Data("HTPT/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
                case .nonNumericStatus:
                    .raw(Data("HTTP/1.1 2x0 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
                case .binaryStatusLine:
                    .raw(Data([0x00, 0xFF, 0x13, 0x37, 0x0D, 0x0A, 0x0D, 0x0A]) + Data("ok".utf8))
                case .badChunkSize:
                    .chunked("zz\r\nhello\r\n0\r\n\r\n")
                case .missingChunkCRLF:
                    .chunked("5\r\nhelloXX5\r\nworld\r\n0\r\n\r\n")
                case .truncatedLastChunk:
                    .chunked("5\r\nhello\r\n10\r\nshort")
                case .missingTerminalChunk:
                    .chunked("5\r\nhello\r\n")
                case .headerFlood:
                    .headerFlood(count: 10_000)
                case .headerBlock:
                    .headerBlock(bytes: 1024 * 1024)
            }
        }
    }

    @Test("given a broken server, when a GET is sent, then it ends with a transport error, or a response HTTP allows, within the bound and the next request succeeds", arguments: Behaviour.allCases)
    func brokenServer_failsCleanly(behaviour: Behaviour) async throws {
        let server = try await makeChaosServer { _ in behaviour.response }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let endpoint = ChaosEndpoint(url: server.url("/chaos"))

        let outcome = try #require(await withinBound { await chaosGET(netti, endpoint) })

        if behaviour.isAcceptable {
            #expect(try outcome.get().statusCode == 200)
        } else if let knownIssue = behaviour.knownIssue {
            withKnownIssue(knownIssue) {
                #expect(outcome.failure?.urlErrorCode != nil, "\(behaviour) was accepted with status \(String(describing: try? outcome.get().statusCode))")
            }
        } else {
            #expect(outcome.failure?.urlErrorCode != nil, "\(behaviour) ended with \(String(describing: outcome.failure))")
        }
        await expectClientUsable(netti, on: server)
    }

    @Test("given a Content-Length shorter than the body, when a GET is sent, then exactly the declared bytes are returned and the next request succeeds")
    func contentLengthShorter_returnsDeclaredBytes() async throws {
        let server = try await makeChaosServer { _ in .contentLength(declared: 16) }
        defer { server.stop() }
        let netti = makeChaosNetti()

        let outcome = await withinBound { await chaosGET(netti, ChaosEndpoint(url: server.url("/chaos"))) }

        let response = try #require(try outcome?.get())
        #expect(response.rawData == LocalHTTPServer.Response.chaosBody.prefix(16))
        await expectClientUsable(netti, on: server)
    }

    @Test("given seeded bytes injected into the head or body, when a GET is sent, then the call ends within the bound and the next request succeeds", arguments: ChaosRegion.allCases, 1...6)
    func injectedBytes_neverHang(region: ChaosRegion, seed: Int) async throws {
        let server = try await makeChaosServer { _ in .injected(seed: UInt64(seed), into: region) }
        defer { server.stop() }
        let netti = makeChaosNetti()

        let outcome = await withinBound { await chaosGET(netti, ChaosEndpoint(url: server.url("/chaos"))) }

        #expect(outcome != nil)
        await expectClientUsable(netti, on: server)
    }

    @Test("given a slow drip that keeps arriving inside the timeout, when a GET is sent, then the whole body is returned")
    func slowDrip_insideTimeout_succeeds() async throws {
        let body = Data(LocalHTTPServer.Response.chaosBody.prefix(64))
        let server = try await makeChaosServer { _ in .drip(count: 8, every: .milliseconds(50), body: body) }
        defer { server.stop() }
        let netti = makeChaosNetti()

        let outcome = await withinBound { await chaosGET(netti, ChaosEndpoint(url: server.url("/chaos"), timeoutInterval: 1)) }

        let response = try #require(try outcome?.get())
        #expect(response.rawData == body)
    }

    @Test("given a drip slower than the timeout, when a GET is sent, then it fails with timedOut and the next request succeeds")
    func slowDrip_pastTimeout_timesOut() async throws {
        let server = try await makeChaosServer { _ in .drip(count: 1, every: .seconds(2)) }
        defer { server.stop() }
        let netti = makeChaosNetti()

        let outcome = await withinBound { await chaosGET(netti, ChaosEndpoint(url: server.url("/chaos"), timeoutInterval: 0.5)) }

        #expect(outcome?.failure?.urlErrorCode == .timedOut)
        await expectClientUsable(netti, on: server)
    }

    @Test("given a server that never answers, when a GET is sent, then it fails with timedOut within the bound and the next request succeeds")
    func extremeLatency_timesOut() async throws {
        let server = try await makeChaosServer { _ in .silence }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let start = ContinuousClock.now

        let outcome = await withinBound(.seconds(3)) { await chaosGET(netti, ChaosEndpoint(url: server.url("/chaos"), timeoutInterval: 0.5)) }

        #expect(outcome?.failure?.urlErrorCode == .timedOut)
        #expect(ContinuousClock.now - start < .seconds(3))
        await expectClientUsable(netti, on: server)
    }

    @Test("given a handler that answers only after the timeout, when a GET is sent, then it fails with timedOut")
    func delayedResponse_timesOut() async throws {
        let server = try await makeChaosServer { _ in
            try? await Task.sleep(for: .seconds(2))
            return .text("late")
        }
        defer { server.stop() }
        let netti = makeChaosNetti()

        let outcome = await withinBound(.seconds(3)) { await chaosGET(netti, ChaosEndpoint(url: server.url("/chaos"), timeoutInterval: 0.5)) }

        #expect(outcome?.failure?.urlErrorCode == .timedOut)
        await expectClientUsable(netti, on: server)
    }
}
