import Foundation
import os
import Testing

@testable import Netti

/// The engine contract. Every test runs against both engines; passing on both is the evidence of
/// parity required before Alamofire is removed.
@Suite("Network service contract", .timeLimit(.minutes(1)))
struct NetworkServiceContractTests {

    enum UploadKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case data, file, stream

        var testDescription: String {
            rawValue
        }
    }

    private static let streamingHeaders = ["Content-Type": "application/octet-stream", "X-Content-Type-Options": "nosniff"]

    // MARK: - Data

    @Test("given a request, when sent, then status, headers, body, request and metrics are returned", arguments: EngineKind.allCases)
    func data_returnsResponse(engine: EngineKind) async throws {
        let server = try await LocalHTTPServer.start { _ in .text("hello", headers: ["X-Test": "1"]) }
        defer { server.stop() }
        var request = URLRequest(url: server.url("/items?page=2"))
        request.httpMethod = "POST"
        request.httpBody = Data("ping".utf8)

        let response = try await engine.makeService().data(for: request)

        #expect(response.statusCode == 200)
        #expect(response.rawData == Data("hello".utf8))
        #expect(response.data == response.rawData)
        #expect(response.response?.value(forHTTPHeaderField: "X-Test") == "1")
        #expect(response.request?.url == request.url)
        #expect(response.metrics != nil)
        let received = try #require(server.requests.first)
        #expect(received.method == "POST")
        #expect(received.target == "/items?page=2")
        #expect(received.body == Data("ping".utf8))
    }

    @Test("given a non-2xx status, when sent, then the response is returned, not thrown", arguments: EngineKind.allCases)
    func data_non2xx_isReturned(engine: EngineKind) async throws {
        let server = try await LocalHTTPServer.start { _ in .text("missing", status: 404) }
        defer { server.stop() }

        let response = try await engine.makeService().data(for: URLRequest(url: server.url("/")))

        #expect(response.statusCode == 404)
        #expect(response.rawData == Data("missing".utf8))
    }

    @Test("given an empty body, when sent, then the body is empty data", arguments: EngineKind.allCases)
    func data_emptyBody_isEmptyData(engine: EngineKind) async throws {
        let server = try await LocalHTTPServer.start { _ in LocalHTTPServer.Response(status: 204) }
        defer { server.stop() }

        let response = try await engine.makeService().data(for: URLRequest(url: server.url("/")))

        #expect(response.statusCode == 204)
        #expect(response.rawData == Data())
    }

    @Test("given an unreachable host, when sent, then requestFailed is thrown", arguments: EngineKind.allCases)
    func data_connectionRefused_throwsRequestFailed(engine: EngineKind) async throws {
        let url = try await SessionDelegateTests.refusedURL()

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await engine.makeService().data(for: URLRequest(url: url))
        }

        #expect(error?.urlErrorCode == .cannotConnectToHost)
    }

    @Test("given a request in flight, when the calling task is cancelled, then cancelled is thrown", arguments: EngineKind.allCases)
    func data_cancelled_throwsCancelled(engine: EngineKind) async throws {
        let server = try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(body: .stall(prefix: Data(), contentLength: 10))
        }
        defer { server.stop() }
        let service = engine.makeService()
        let url = server.url("/")

        let task = Task { () async -> Result<HTTPResponse<Data>, HTTPRequestError> in
            do throws(HTTPRequestError) {
                return .success(try await service.data(for: URLRequest(url: url)))
            } catch {
                return .failure(error)
            }
        }
        #expect(await server.wait { $0.requests.isNotEmpty })
        task.cancel()

        let error = await expectRequestError { () async throws(HTTPRequestError) in try await task.value.get() }
        #expect(error?.isCancelled == true)
        #expect(await server.wait { $0.disconnects == 1 })
    }

    // MARK: - Upload

    @Test("given an upload source, when uploaded, then the server receives it and progress ends at 1.0", arguments: EngineKind.allCases, UploadKind.allCases)
    func upload_sendsBodyAndReportsProgress(engine: EngineKind, kind: UploadKind) async throws {
        let server = try await LocalHTTPServer.start { request in .text("\(request.body.count)", status: 201) }
        defer { server.stop() }
        let payload = testPayload(count: 256 * 1024)
        let source: UploadSource
        switch kind {
            case .data:
                source = .data(payload)
            case .file:
                let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("netti-upload-\(UUID().uuidString)")
                try payload.write(to: fileURL)
                source = .file(fileURL)
            case .stream:
                source = .stream { InputStream(data: payload) }
        }
        var request = URLRequest(url: server.url("/upload"))
        request.httpMethod = "POST"
        let recorder = ProgressRecorder()

        let response = try await engine.makeService().upload(for: request, from: source, progress: recorder.handler)

        if case .file(let fileURL) = source {
            try? FileManager.default.removeItem(at: fileURL)
        }
        #expect(response.statusCode == 201)
        #expect(server.requests.first?.body == payload)
        recorder.expectCompleted(total: Int64(payload.count))
    }

    @Test("given a missing file, when uploaded, then fileSystem is thrown before any traffic", arguments: EngineKind.allCases)
    func upload_missingFile_throwsFileSystem(engine: EngineKind) async throws {
        let server = try await LocalHTTPServer.start { _ in .text("") }
        defer { server.stop() }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("netti-missing-\(UUID().uuidString)")
        let url = server.url("/upload")

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await engine.makeService().upload(for: URLRequest(url: url), from: .file(missing), progress: nil)
        }

        #expect(error?.isFileSystem == true)
        #expect(server.requests.isEmpty)
    }

    // MARK: - Download

    @Test("given a download, when it completes, then the file holds the body and progress ends at 1.0", arguments: EngineKind.allCases)
    func download_writesFileAndReportsProgress(engine: EngineKind) async throws {
        let payload = testPayload(count: 512 * 1024)
        let server = try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(headers: Self.streamingHeaders, body: .data(payload))
        }
        defer { server.stop() }
        let recorder = ProgressRecorder()

        let response = await engine.makeService().download(for: URLRequest(url: server.url("/file")), resumeData: nil, progress: recorder.handler)

        let fileURL = try #require(response.fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        #expect(response.error == nil)
        #expect(response.statusCode == 200)
        #expect(try Data(contentsOf: fileURL) == payload)
        #expect(fileURL.deletingLastPathComponent().lastPathComponent == "netti.downloads")
        recorder.expectCompleted(total: Int64(payload.count))
    }

    @Test("given a cancelled download, when resumed with its resume data, then it continues from the partial content", arguments: EngineKind.allCases)
    func download_cancelThenResume_continues(engine: EngineKind) async throws {
        let payload = testPayload(count: 512 * 1024)
        let half = payload.count / 2
        let server = try await LocalHTTPServer.start { request in
            var headers = Self.streamingHeaders
            headers["ETag"] = "\"v1\""
            headers["Last-Modified"] = "Mon, 26 Oct 2026 10:00:00 GMT"
            headers["Accept-Ranges"] = "bytes"
            guard let range = request.header("range"), let start = Int(range.dropFirst("bytes=".count).prefix { $0 != "-" }) else {
                return LocalHTTPServer.Response(headers: headers, body: .stall(prefix: payload.prefix(half), contentLength: payload.count))
            }
            headers["Content-Range"] = "bytes \(start)-\(payload.count - 1)/\(payload.count)"
            return LocalHTTPServer.Response(status: 206, headers: headers, body: .data(Data(payload[start...])))
        }
        defer { server.stop() }
        let service = engine.makeService()
        let request = URLRequest(url: server.url("/file"))
        // The server stalls after `half`, but the transport may never report that last write while it
        // stalls (seen with plain URLSession under load), so the first report is the sync point.
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()

        let firstAttempt = Task {
            await service.download(for: request, resumeData: nil) { progress in
                if progress.completedUnitCount > 0 {
                    startedContinuation.yield()
                }
            }
        }
        for await _ in started {
            break
        }
        firstAttempt.cancel()
        let cancelled = await firstAttempt.value

        #expect(cancelled.fileURL == nil)
        #expect((cancelled.error as? HTTPRequestError)?.isCancelled == true)
        let resumeData = try #require(cancelled.resumeData)

        let resumed = await service.download(for: request, resumeData: resumeData, progress: nil)

        let fileURL = try #require(resumed.fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        #expect(resumed.statusCode == 206)
        #expect(try Data(contentsOf: fileURL) == payload)
        let range = try #require(server.requests.last?.header("range"))
        let start = try #require(Int(range.dropFirst("bytes=".count).dropLast()))
        #expect(range == "bytes=\(start)-")
        #expect((1...half).contains(start), "the resume must reuse the partial content, not restart")
    }

    @Test("given an unreachable host, when downloading, then the error is returned, not thrown", arguments: EngineKind.allCases)
    func download_connectionRefused_returnsError(engine: EngineKind) async throws {
        let url = try await SessionDelegateTests.refusedURL()

        let response = await engine.makeService().download(for: URLRequest(url: url), resumeData: nil, progress: nil)

        #expect(response.fileURL == nil)
        #expect((response.error as? HTTPRequestError)?.urlErrorCode == .cannotConnectToHost)
    }

    // MARK: - Bytes

    @Test("given a streamed body, when consumed, then each chunk arrives before the next is sent", arguments: EngineKind.allCases)
    func bytes_chunksArriveIncrementally(engine: EngineKind) async throws {
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let openGate: @Sendable () async -> Void = {
            for await _ in gate {
                break
            }
        }
        let server = try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(headers: Self.streamingHeaders, body: .chunks([.init("one"), .init("two", before: openGate), .init("three", before: openGate)]))
        }
        defer { server.stop() }

        let response = try await engine.makeService().bytes(for: URLRequest(url: server.url("/events")))

        #expect(response.statusCode == 200)
        var received: [String] = []
        for try await chunk in response.body {
            received.append(String(decoding: chunk, as: UTF8.self))
            gateContinuation.yield()
        }
        #expect(received == ["one", "two", "three"])
    }

    @Test("given a stream, when the consumer stops early, then the transfer is cancelled", arguments: EngineKind.allCases)
    func bytes_earlyExit_cancelsTransfer(engine: EngineKind) async throws {
        let chunks = (0..<200).map { index in
            LocalHTTPServer.Response.Chunk("chunk \(index)") {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let server = try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(headers: Self.streamingHeaders, body: .chunks(chunks))
        }
        defer { server.stop() }
        let service = engine.makeService()

        do {
            let response = try await service.bytes(for: URLRequest(url: server.url("/events")))
            for try await _ in response.body {
                break
            }
        }

        #expect(await server.wait { $0.disconnects == 1 })
    }

    @Test("given an unreachable host, when streaming, then requestFailed is thrown", arguments: EngineKind.allCases)
    func bytes_connectionRefused_throwsRequestFailed(engine: EngineKind) async throws {
        let url = try await SessionDelegateTests.refusedURL()

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await engine.makeService().bytes(for: URLRequest(url: url))
        }

        #expect(error?.urlErrorCode == .cannotConnectToHost)
    }

    // MARK: - WebSocket

    @Test("given an open WebSocket, when messages and a ping are sent, then the echoes are received", arguments: EngineKind.allCases)
    func webSocket_roundTrip(engine: EngineKind) async throws {
        let server = try await LocalWebSocketServer.start()
        defer { server.stop() }

        let socket = try await engine.makeService().webSocket(for: URLRequest(url: server.url))
        defer { socket.close(with: .normalClosure, reason: nil) }
        var messages = socket.messages.makeAsyncIterator()

        try await socket.send(.text("hello"))
        #expect(try await messages.next() == .text("hello"))
        try await socket.send(.data(Data([1, 2, 3])))
        #expect(try await messages.next() == .data(Data([1, 2, 3])))
        try await socket.sendPing()
    }

    @Test("given the server closes with 1000, when receiving, then the messages end without an error", arguments: EngineKind.allCases)
    func webSocket_normalClose_endsWithoutError(engine: EngineKind) async throws {
        let server = try await LocalWebSocketServer.start()
        defer { server.stop() }
        let socket = try await engine.makeService().webSocket(for: URLRequest(url: server.url))

        try await socket.send(.text(LocalWebSocketServer.closeCommandPrefix + "1000"))

        var received: [WebSocketMessage] = []
        for try await message in socket.messages {
            received.append(message)
        }
        #expect(received.isEmpty)
    }

    @Test("given the server closes with 1011, when receiving, then an error is thrown", arguments: EngineKind.allCases)
    func webSocket_abnormalClose_throws(engine: EngineKind) async throws {
        let server = try await LocalWebSocketServer.start()
        defer { server.stop() }
        let socket = try await engine.makeService().webSocket(for: URLRequest(url: server.url))

        try await socket.send(.text(LocalWebSocketServer.closeCommandPrefix + "1011"))

        await #expect(throws: HTTPRequestError.self) {
            for try await _ in socket.messages {}
        }
    }

    @Test("given an unreachable host, when opening a WebSocket, then requestFailed is thrown", arguments: EngineKind.allCases)
    func webSocket_connectionRefused_throws(engine: EngineKind) async throws {
        let server = try await LocalWebSocketServer.start()
        server.stop()
        let url = server.url

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await engine.makeService().webSocket(for: URLRequest(url: url))
        }

        #expect(error?.urlErrorCode != nil)
    }
}
