import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

@Suite("Data-request progress", .timeLimit(.minutes(1)))
struct DataProgressTests {

    // MARK: - Engine: Body Shapes

    @Test("given a fixed-length body in several chunks, when received, then progress grows with the announced total and ends at 1.0")
    func fixedLengthBody() async throws {
        let payload = testPayload(count: 100_000)
        let server = try await Self.server(contentLength: payload.count, body: payload, sliceSize: 10_000)
        defer { server.stop() }
        let recorder = ProgressRecorder()

        let response = try await URLSessionNetworkService(configuration: .ephemeral)
            .data(for: URLRequest(url: server.url("/file")), progress: recorder.handler)

        #expect(response.rawData == payload)
        recorder.expectCompleted(total: 100_000)
        #expect(recorder.updates.count >= 2, "a body in ten chunks reports more than once")
        #expect(recorder.updates.allSatisfy { $0.totalUnitCount == 100_000 })
    }

    @Test("given a chunked body without Content-Length, when received, then the total is unknown until the final 1.0")
    func chunkedBody() async throws {
        let chunk = String(repeating: "a", count: 20_000)
        let server = try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(body: .chunks((0..<5).map { _ in
                LocalHTTPServer.Response.Chunk(chunk, before: { try? await Task.sleep(for: .milliseconds(5)) })
            }))
        }
        defer { server.stop() }
        let recorder = ProgressRecorder()

        _ = try await URLSessionNetworkService(configuration: .ephemeral)
            .data(for: URLRequest(url: server.url("/chunked")), progress: recorder.handler)

        recorder.expectCompleted(total: 100_000)
        #expect(recorder.updates.dropLast().allSatisfy { $0.totalUnitCount == nil }, "\(recorder.updates)")
        #expect(recorder.updates.count >= 2)
    }

    @Test("given a body smaller than 16 KiB, when it completes, then the handler is called once with 1.0")
    func smallBodyReportsOnce() async throws {
        let server = try await Self.server(contentLength: 5_000, body: testPayload(count: 5_000), sliceSize: 1_000)
        defer { server.stop() }
        let recorder = ProgressRecorder()

        _ = try await URLSessionNetworkService(configuration: .ephemeral)
            .data(for: URLRequest(url: server.url("/small")), progress: recorder.handler)

        #expect(recorder.updates == [TransferProgress(completedUnitCount: 5_000, totalUnitCount: 5_000)])
    }

    @Test("given an empty body, when it completes, then the handler is called once with 1.0")
    func emptyBody() async throws {
        let server = try await LocalHTTPServer.start { _ in LocalHTTPServer.Response() }
        defer { server.stop() }
        let recorder = ProgressRecorder()

        _ = try await URLSessionNetworkService(configuration: .ephemeral)
            .data(for: URLRequest(url: server.url("/empty")), progress: recorder.handler)

        #expect(recorder.updates.count == 1)
        #expect(recorder.updates.last?.fractionCompleted == 1)
    }

    @Test("given the connection drops before the body ends, when received, then the request fails and 1.0 is never reported")
    func droppedConnection() async throws {
        let payload = testPayload(count: 100_000)
        let server = try await LocalHTTPServer.start { _ in
            let head = Self.head(contentLength: payload.count)
            return LocalHTTPServer.Response(body: .script([
                .send(head + payload.prefix(30_000)),
                .pause(.milliseconds(100)),
                .reset,
            ]))
        }
        defer { server.stop() }
        let recorder = ProgressRecorder()
        let service = URLSessionNetworkService(configuration: .ephemeral)

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Data> in
            try await service.data(for: URLRequest(url: server.url("/drop")), progress: recorder.handler)
        }

        #expect(error?.urlErrorCode != nil)
        #expect(recorder.updates.contains { $0.fractionCompleted >= 1 } == false, "\(recorder.updates)")
    }

    // MARK: - Engine: Rate Bound

    @Test("given 1 MB in 1 KB chunks, when received, then the handler is called at most 100 times and each step is at least 16 KiB")
    func rateBound() async throws {
        let payload = testPayload(count: 1_048_576)
        let server = try await Self.server(contentLength: payload.count, body: payload, sliceSize: 1_024, interval: .zero)
        defer { server.stop() }
        let recorder = ProgressRecorder()

        let response = try await URLSessionNetworkService(configuration: .ephemeral)
            .data(for: URLRequest(url: server.url("/large")), progress: recorder.handler)

        #expect(response.rawData?.count == payload.count)
        recorder.expectCompleted(total: Int64(payload.count))
        let updates = recorder.updates
        #expect(updates.count <= 100, "\(updates.count) calls")
        let steps = zip([0] + updates.dropLast().map(\.completedUnitCount), updates.dropLast().map(\.completedUnitCount)).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 >= 16 * 1_024 }, "steps \(steps)")
    }

    // MARK: - Delegate: Forged Lengths

    @Test("given a negative or zero announced length, when data arrives, then the total is unknown and the received bytes are reported", arguments: [-5, 0, Int.min])
    func forgedLength(announced: Int) async throws {
        let recorder = ProgressRecorder()

        _ = try await Self.receive(announcing: announced, chunks: [20_000, 20_000], progress: recorder.handler)

        #expect(recorder.updates.map(\.completedUnitCount) == [20_000, 40_000, 40_000], "\(recorder.updates)")
        #expect(recorder.updates.dropLast().allSatisfy { $0.totalUnitCount == nil })
        #expect(recorder.updates.last?.fractionCompleted == 1)
    }

    @Test("given a length smaller than the bytes that arrive, when data arrives, then the total is treated as unknown")
    func understatedLength() async throws {
        let recorder = ProgressRecorder()

        _ = try await Self.receive(announcing: 10, chunks: [20_000, 20_000], progress: recorder.handler)

        #expect(recorder.updates.dropLast().allSatisfy { $0.totalUnitCount == nil }, "\(recorder.updates)")
        #expect(recorder.updates.map(\.completedUnitCount) == [20_000, 40_000, 40_000])
        #expect(recorder.updates.allSatisfy { $0.fractionCompleted <= 1 })
    }

    @Test("given a failing task, when it completes with an error, then 1.0 is never reported")
    func failedTaskNeverFinishes() async throws {
        let recorder = ProgressRecorder()

        let result = try await Self.receive(announcing: 100_000, chunks: [20_000], failing: true, progress: recorder.handler)

        guard case .failure = result else {
            Issue.record("Expected a failure, got \(result)")
            return
        }
        #expect(recorder.updates.contains { $0.fractionCompleted >= 1 } == false)
    }

    @Test("given an upload with a progress handler, when the response body arrives, then the body does not feed upload progress")
    func uploadProgressIgnoresResponseBody() async throws {
        let server = try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(body: .data(testPayload(count: 100_000)))
        }
        defer { server.stop() }
        let recorder = ProgressRecorder()

        _ = try await URLSessionNetworkService(configuration: .ephemeral)
            .upload(for: Self.post(server.url("/up")), from: .data(Data("tiny".utf8)), progress: recorder.handler)

        #expect(recorder.updates.map(\.completedUnitCount).max() == 4, "\(recorder.updates)")
    }

    // MARK: - Pipeline: Sharing

    @Test("given two identical in-flight GETs and a handler on one, when sent, then each gets its own transfer and both return the response")
    func handlerOptsOutOfSharing() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let seen = Recorder<Bool>()
        let engine = ProgressEngine { request, progress in
            seen.append(progress != nil)
            for await _ in gate {
                break
            }
            progress?(TransferProgress(completedUnitCount: 7, totalUnitCount: 7))
            return .stub(for: request, body: Data("payload".utf8))
        }
        let netti = makeNetti(service: engine)
        let recorder = ProgressRecorder()

        let plain = Task { try await netti.get(TestEndpoint()) }
        #expect(await eventually { seen.values.count == 1 })
        let observed = Task { try await netti.get(TestEndpoint(), progress: recorder.handler) }
        #expect(await eventually { seen.values.count == 2 }, "the handler's request joined the in-flight transfer")
        release.yield()
        release.yield()

        _ = try await plain.value
        _ = try await observed.value
        #expect(seen.values.sorted { $0 == false && $1 } == [false, true])
        recorder.expectCompleted(total: 7)
    }

    @Test("given identical in-flight GETs without handlers, when sent, then they still share one transfer")
    func withoutHandlerStillShares() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let calls = Recorder<Void>()
        let engine = ProgressEngine { request, _ in
            calls.append(())
            for await _ in gate {
                break
            }
            return .stub(for: request)
        }
        let netti = makeNetti(service: engine)
        let key = try netti.buildRequest(TestEndpoint(), method: .get).deduplicationKey

        let tasks = (0..<3).map { _ in Task { try await netti.get(TestEndpoint()) } }
        #expect(await eventually { netti.deduplicator?.waiterCount(for: key) == 3 })
        release.yield()
        for task in tasks {
            _ = try await task.value
        }

        #expect(calls.values.count == 1)
    }

    // MARK: - Pipeline: Retries

    @Test("given a retry after a partial body, when the second attempt succeeds, then counts never decrease and the last call is 1.0")
    func retryAfterPartialBody() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let engine = ProgressEngine { request, progress in
            let attempt = attempts.withLock { attempts in
                attempts += 1
                return attempts
            }
            if attempt == 1 {
                progress?(TransferProgress(completedUnitCount: 50_000, totalUnitCount: 100_000))
                throw HTTPRequestError.requestFailed(URLError(.networkConnectionLost))
            }
            for completed in [20_000, 60_000] as [Int64] {
                progress?(TransferProgress(completedUnitCount: completed, totalUnitCount: 100_000))
            }
            progress?(TransferProgress(completedUnitCount: 100_000, totalUnitCount: 100_000))
            return .stub(for: request, body: testPayload(count: 100_000))
        }
        let netti = makeNetti(service: engine, retryPolicy: RetryPolicy(maxRetries: 2))
        let recorder = ProgressRecorder()

        _ = try await netti.get(TestEndpoint(), progress: recorder.handler)

        #expect(attempts.withLock { $0 } == 2)
        #expect(recorder.updates.map(\.completedUnitCount) == [50_000, 60_000, 100_000], "\(recorder.updates)")
        recorder.expectCompleted(total: 100_000)
    }

    @Test("given a retryable status on the first attempt, when the second attempt succeeds, then only the successful attempt reports 1.0")
    func retryableStatusDoesNotReportCompletion() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let engine = ProgressEngine { request, progress in
            let attempt = attempts.withLock { attempts in
                attempts += 1
                return attempts
            }
            let size = attempt == 1 ? 10 : 500
            progress?(TransferProgress(completedUnitCount: Int64(size), totalUnitCount: Int64(size)))
            return .stub(for: request, status: attempt == 1 ? 503 : 200, body: testPayload(count: size))
        }
        let netti = makeNetti(service: engine, retryPolicy: RetryPolicy(maxRetries: 2))
        let recorder = ProgressRecorder()

        _ = try await netti.get(TestEndpoint(), progress: recorder.handler)

        let completions = recorder.updates.filter { $0.fractionCompleted >= 1 }
        #expect(completions == [TransferProgress(completedUnitCount: 500, totalUnitCount: 500)], "\(recorder.updates)")
        #expect(recorder.updates.last?.fractionCompleted == 1)
    }

    @Test("given a request that fails for good, when sent, then the handler is never called with 1.0")
    func failureNeverCompletes() async throws {
        let engine = ProgressEngine { _, progress in
            progress?(TransferProgress(completedUnitCount: 10, totalUnitCount: 100))
            throw HTTPRequestError.requestFailed(URLError(.networkConnectionLost))
        }
        let netti = makeNetti(service: engine)
        let recorder = ProgressRecorder()

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint(), progress: recorder.handler)
        }

        #expect(error != nil)
        #expect(recorder.updates.contains { $0.fractionCompleted >= 1 } == false)
    }

    // MARK: - Custom Engines

    @Test("given a custom engine without progress support, when a handler is passed, then the request succeeds and the handler is called once with 1.0")
    func engineWithoutProgress() async throws {
        let netti = makeNetti(service: DataOnlyEngine(StubNetworkService { try .json(for: $0, Widget(id: 1, name: "a")) }))
        let recorder = ProgressRecorder()

        let response: HTTPResponse<Widget> = try await netti.get(TestEndpoint(), progress: recorder.handler)

        #expect(response.data == Widget(id: 1, name: "a"))
        #expect(recorder.updates.count == 1)
        #expect(recorder.updates.first?.fractionCompleted == 1)
        #expect(recorder.updates.first?.completedUnitCount == response.rawData.map { Int64($0.count) })
    }

    @Test("given a custom engine without progress support, when it throws, then the handler is never called")
    func engineWithoutProgressFailing() async throws {
        let engine = DataOnlyEngine(StubNetworkService { _ in throw HTTPRequestError.requestFailed(URLError(.notConnectedToInternet)) })
        let recorder = ProgressRecorder()

        _ = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Data> in
            try await engine.data(for: URLRequest(url: TestURL.api), progress: recorder.handler)
        }

        #expect(recorder.updates.isEmpty)
    }

    // MARK: - Verbs

    @Test("given each body-returning verb, when called with a handler, then the handler reaches the engine and ends at 1.0")
    func everyVerbAcceptsProgress() async throws {
        let handlers = Recorder<Bool>()
        let engine = ProgressEngine { request, progress in
            handlers.append(progress != nil)
            progress?(TransferProgress(completedUnitCount: 2, totalUnitCount: 2))
            return try .json(for: request, Widget(id: 1, name: "a"))
        }
        let netti = makeNetti(service: engine, deduplicatesRequests: false)
        let endpoint = TestEndpoint()
        let recorders = (0..<10).map { _ in ProgressRecorder() }

        let _: HTTPResponse<Widget> = try await netti.get(endpoint, progress: recorders[0].handler)
        let _: HTTPResponse<Widget> = try await netti.post(endpoint, progress: recorders[1].handler)
        let _: HTTPResponse<Widget> = try await netti.put(endpoint, progress: recorders[2].handler)
        let _: HTTPResponse<Widget> = try await netti.patch(endpoint, progress: recorders[3].handler)
        let _: HTTPResponse<Widget> = try await netti.delete(endpoint, progress: recorders[4].handler)
        try await netti.get(endpoint, progress: recorders[5].handler)
        try await netti.post(endpoint, progress: recorders[6].handler)
        try await netti.put(endpoint, progress: recorders[7].handler)
        try await netti.patch(endpoint, progress: recorders[8].handler)
        try await netti.delete(endpoint, progress: recorders[9].handler)

        #expect(handlers.values == Array(repeating: true, count: 10))
        for recorder in recorders {
            recorder.expectCompleted()
        }
    }

    @Test("given a call without a handler, when sent, then the engine receives no handler")
    func noHandlerNoChange() async throws {
        let handlers = Recorder<Bool>()
        let engine = ProgressEngine { request, progress in
            handlers.append(progress != nil)
            return try .json(for: request, Widget(id: 1, name: "a"))
        }

        let response: HTTPResponse<Widget> = try await makeNetti(service: engine).get(TestEndpoint())

        #expect(response.data == Widget(id: 1, name: "a"))
        #expect(handlers.values == [false])
    }

    // MARK: - Local Responses

    @Test("given sample data and a handler, when sent, then the handler is called once with 1.0 and no transport call is made")
    func sampleData_reportsCompletion() async throws {
        let service = StubNetworkService()
        var endpoint = TestEndpoint()
        let sample = try JSONEncoder().encode(Widget(id: 1, name: "sample"))
        endpoint.sampleData = sample
        let recorder = ProgressRecorder()

        let response: HTTPResponse<Widget> = try await makeNetti(service: service).get(endpoint, progress: recorder.handler)

        #expect(response.data == Widget(id: 1, name: "sample"))
        #expect(recorder.updates == [TransferProgress(completedUnitCount: Int64(sample.count), totalUnitCount: Int64(sample.count))])
        #expect(service.requests.isEmpty)
    }

    @Test("given a cached response and no connectivity, when sent with a handler, then the handler is called once with 1.0")
    func offlineCache_reportsCompletion() async throws {
        let connectivity = StubConnectivity(.connected)
        let service = StubNetworkService { request in
            if connectivity.currentStatus == .disconnected {
                throw URLError(.notConnectedToInternet)
            }
            return try .json(for: request, Widget(id: 1, name: "cached"))
        }
        let netti = makeNetti(service: service, connectivity: connectivity)
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache
        let _: HTTPResponse<Widget> = try await netti.get(endpoint)
        connectivity.set(.disconnected)
        let recorder = ProgressRecorder()

        let response: HTTPResponse<Widget> = try await netti.get(endpoint, progress: recorder.handler)

        #expect(response.data?.name == "cached")
        recorder.expectCompleted()
        #expect(recorder.updates.count == 1)
        #expect(service.requests.count == 1)
    }

    // MARK: - Helpers

    private static func head(contentLength: Int) -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Length: \(contentLength)\r\nConnection: close\r\n\r\n".utf8)
    }

    /// A server that announces `contentLength` and sends `body` in `sliceSize` pieces.
    private static func server(
        contentLength: Int,
        body: Data,
        sliceSize: Int,
        interval: Duration = .milliseconds(5)
    ) async throws -> LocalHTTPServer {
        try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(body: .script([
                .send(head(contentLength: contentLength)),
                .drip(body, count: sliceSize, interval: interval),
            ]))
        }
    }

    private static func post(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        return request
    }

    /// Drives a data task through the delegate as if a server announced `announced` bytes and then
    /// sent `chunks`, without a socket, so forged `Content-Length` values can be tested.
    private static func receive(
        announcing announced: Int,
        chunks: [Int],
        failing: Bool = false,
        progress: @escaping ProgressHandler
    ) async throws -> Result<HTTPResponse<Data>, HTTPRequestError> {
        let delegate = SessionDelegate(trustEvaluator: nil)
        let session = URLSession(configuration: .ephemeral)
        let url = try #require(URL(string: "https://api.test/forged"))
        let task = session.dataTask(with: url)
        return await withCheckedContinuation { continuation in
            delegate.register(task, TaskState(
                request: URLRequest(url: url),
                completion: .data(continuation),
                receiveProgress: ProgressReporter(progress)
            ))
            let response = URLResponse(url: url, mimeType: nil, expectedContentLength: announced, textEncodingName: nil)
            delegate.urlSession(session, dataTask: task, didReceive: response) { _ in }
            for count in chunks {
                delegate.urlSession(session, dataTask: task, didReceive: Data(count: count))
            }
            delegate.urlSession(session, task: task, didCompleteWithError: failing ? URLError(.networkConnectionLost) : nil)
        }
    }
}

// MARK: - Engines

/// An engine whose data handler sees the progress handler it was given.
private struct ProgressEngine: NetworkService {
    typealias Handler = @Sendable (URLRequest, ProgressHandler?) async throws -> HTTPResponse<Data>

    let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        try await run(request, nil)
    }

    func data(for request: URLRequest, progress: ProgressHandler?) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        try await run(request, progress)
    }

    private func run(_ request: URLRequest, _ progress: ProgressHandler?) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        do {
            return try await handler(request, progress)
        } catch let error as HTTPRequestError {
            throw error
        } catch {
            throw .requestFailed(URLError(.unknown))
        }
    }

    func upload(for request: URLRequest, from source: UploadSource, progress: ProgressHandler?) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        throw .cancelled
    }

    func download(for request: URLRequest, resumeData: Data?, progress: ProgressHandler?) async -> HTTPDownloadResponse<URL> {
        HTTPDownloadResponse(request: request, response: nil, fileURL: nil, error: HTTPRequestError.cancelled)
    }

    func bytes(for request: URLRequest) async throws(HTTPRequestError) -> HTTPStreamResponse {
        throw .cancelled
    }

    func webSocket(for request: URLRequest) async throws(HTTPRequestError) -> any WebSocketTransport {
        throw .cancelled
    }
}

/// A custom engine written against the 3.0 contract: it has no `data(for:progress:)` of its own, so
/// the protocol's default applies.
private struct DataOnlyEngine: NetworkService {
    let inner: StubNetworkService

    init(_ inner: StubNetworkService) {
        self.inner = inner
    }

    func data(for request: URLRequest) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        try await inner.data(for: request)
    }

    func upload(for request: URLRequest, from source: UploadSource, progress: ProgressHandler?) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        try await inner.upload(for: request, from: source, progress: progress)
    }

    func download(for request: URLRequest, resumeData: Data?, progress: ProgressHandler?) async -> HTTPDownloadResponse<URL> {
        await inner.download(for: request, resumeData: resumeData, progress: progress)
    }

    func bytes(for request: URLRequest) async throws(HTTPRequestError) -> HTTPStreamResponse {
        try await inner.bytes(for: request)
    }

    func webSocket(for request: URLRequest) async throws(HTTPRequestError) -> any WebSocketTransport {
        try await inner.webSocket(for: request)
    }
}
