import Foundation
import Testing

@testable import Netti

/// TM-07: data-task bodies are capped by `maximumResponseSize`; downloads and byte streams are not.
@Suite("Response size limit", .timeLimit(.minutes(1)))
struct ResponseSizeLimitTests {

    private static let limit = 1024

    @Test("given the public initializer, when no limit is given, then data responses are capped at 64 MB")
    func defaultLimit_is64MB() {
        #expect(URLSessionNetworkService().maximumResponseSize == 64 * 1024 * 1024)
        #expect(URLSessionNetworkService(maximumResponseSize: nil).maximumResponseSize == nil)
    }

    @Test("given a declared Content-Length over the limit, when requested, then the call fails before the body arrives")
    func declaredLength_overLimit_failsBeforeBody() async throws {
        let server = try await LocalHTTPServer.start { _ in
            // URLSession reports the response with the first body byte; one byte is far under the
            // limit, so only the declared length can fail the call.
            LocalHTTPServer.Response(headers: ["Content-Type": "application/octet-stream"], body: .stall(prefix: Data("x".utf8), contentLength: Self.limit + 1))
        }
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumResponseSize: Self.limit)

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await service.data(for: URLRequest(url: server.url("/")))
        }

        #expect(error?.urlErrorCode == .dataLengthExceedsMaximum)
        #expect(await server.wait { $0.disconnects == 1 })
    }

    @Test("given a chunked body that grows past the limit, when requested, then the task is cancelled and the call fails")
    func chunked_overLimit_fails() async throws {
        // Four times the limit, and no last chunk: the body never completes on its own, so the only way
        // the server sees a disconnect is the client cancelling at the cap. A finite body could be sent
        // whole before a slow client reacts, and its close would not count as a disconnect.
        let server = try await LocalHTTPServer.start { _ in
            .unterminatedChunks(Array(repeating: String(repeating: "x", count: 256), count: 16))
        }
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumResponseSize: Self.limit)

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await service.data(for: URLRequest(url: server.url("/")))
        }

        #expect(error?.urlErrorCode == .dataLengthExceedsMaximum)
        #expect(await server.wait { $0.disconnects == 1 })
    }

    @Test("given a body at the limit, declared or chunked, when requested, then it is returned whole", arguments: [false, true])
    func atLimit_succeeds(chunked: Bool) async throws {
        let body = String(repeating: "x", count: Self.limit)
        let server = try await LocalHTTPServer.start { _ in
            chunked ? LocalHTTPServer.Response(body: .chunks([.init(String(body.prefix(512))), .init(String(body.suffix(512)))])) : .text(body)
        }
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumResponseSize: Self.limit)

        let response = try await service.data(for: URLRequest(url: server.url("/")))

        #expect(response.rawData == Data(body.utf8))
    }

    @Test("given an upload whose response is over the limit, when sent, then the call fails")
    func uploadResponse_overLimit_fails() async throws {
        let server = try await LocalHTTPServer.start { _ in .text(String(repeating: "x", count: Self.limit * 4)) }
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumResponseSize: Self.limit)
        var request = URLRequest(url: server.url("/"))
        request.httpMethod = "POST"

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await service.upload(for: request, from: .data(Data("body".utf8)), progress: nil)
        }

        #expect(error?.urlErrorCode == .dataLengthExceedsMaximum)
    }

    @Test("given no limit, when a large body arrives, then it is returned whole")
    func noLimit_unbounded() async throws {
        let body = String(repeating: "x", count: Self.limit * 4)
        let server = try await LocalHTTPServer.start { _ in .text(body) }
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumResponseSize: nil)

        let response = try await service.data(for: URLRequest(url: server.url("/")))

        #expect(response.rawData?.count == Self.limit * 4)
    }

    @Test("given a download over the limit, when downloaded, then the limit does not apply")
    func download_notLimited() async throws {
        let server = try await LocalHTTPServer.start { _ in .text(String(repeating: "x", count: Self.limit * 4)) }
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumResponseSize: Self.limit)

        let response = await service.download(for: URLRequest(url: server.url("/")), resumeData: nil, progress: nil)
        defer { response.fileURL.map { try? FileManager.default.removeItem(at: $0) } }

        #expect(response.error == nil)
        let fileURL = try #require(response.fileURL)
        #expect(try Data(contentsOf: fileURL).count == Self.limit * 4)
    }

    @Test("given a byte stream over the limit, when read, then the limit does not apply")
    func bytes_notLimited() async throws {
        let server = try await LocalHTTPServer.start { _ in .text(String(repeating: "x", count: Self.limit * 4)) }
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, maximumResponseSize: Self.limit)

        let stream = try await service.bytes(for: URLRequest(url: server.url("/")))
        var received = 0
        for try await chunk in stream.body {
            received += chunk.count
        }

        #expect(received == Self.limit * 4)
    }
}
