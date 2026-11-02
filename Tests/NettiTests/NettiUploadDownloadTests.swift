import Foundation
import Testing

@testable import Netti
import NettiTesting

@Suite("Netti upload and download", .timeLimit(.minutes(1)))
struct NettiUploadDownloadTests {

    // MARK: - Upload

    @Test("given in-memory data, when uploaded, then it is the body, POST is used and the response is decoded")
    func uploadData() async throws {
        let service = StubNetworkService { try .json(for: $0, Widget(id: 1, name: "stored")) }
        let recorder = ProgressRecorder()

        let response: HTTPResponse<Widget> = try await makeNetti(service: service).upload(TestEndpoint(), data: Data("payload".utf8), progress: recorder.handler)

        let upload = try #require(service.uploads.first)
        guard case .data(let body) = upload.source else {
            Issue.record("Expected a data source, got \(upload.source)")
            return
        }
        #expect(body == Data("payload".utf8))
        #expect(upload.request.httpMethod == "POST")
        #expect(response.data == Widget(id: 1, name: "stored"))
        recorder.expectCompleted()
    }

    @Test("given a file, when uploaded with PUT, then the file is the source and PUT is used")
    func uploadFile() async throws {
        let service = StubNetworkService()
        let fileURL = try temporaryFile(Data("file body".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await makeNetti(service: service).upload(TestEndpoint(), fileURL: fileURL, method: .put)

        let upload = try #require(service.uploads.first)
        guard case .file(let sentURL) = upload.source else {
            Issue.record("Expected a file source, got \(upload.source)")
            return
        }
        #expect(sentURL == fileURL)
        #expect(upload.request.httpMethod == "PUT")
    }

    @Test("given a missing file, when uploaded, then fileSystem is thrown before any traffic")
    func uploadMissingFile() async {
        let service = StubNetworkService()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await makeNetti(service: service).upload(TestEndpoint(), fileURL: missing)
        }

        #expect(error?.isFileSystem == true)
        #expect(service.requests.isEmpty)
    }

    @Test("given a form with a field and a file, when uploaded, then both parts are sent and the content type carries the boundary")
    func uploadMultipart() async throws {
        let service = StubNetworkService()
        let imageURL = try temporaryFile(Data([0xFF, 0xD8, 0xFF]), name: "avatar.jpg")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        var form = MultipartFormData()
        form.append("Ada", name: "name")
        form.append(fileURL: imageURL, name: "avatar")

        try await makeNetti(service: service).upload(TestEndpoint(), multipart: form, method: .patch)

        let upload = try #require(service.uploads.first)
        guard case .data(let body) = upload.source else {
            Issue.record("Expected an in-memory form, got \(upload.source)")
            return
        }
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#"Content-Disposition: form-data; name="name""#))
        #expect(text.contains(#"Content-Disposition: form-data; name="avatar"; filename="avatar.jpg""#))
        #expect(text.contains("Content-Type: image/jpeg"))
        #expect(upload.request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=\(form.boundary)")
        #expect(upload.request.httpMethod == "PATCH")
    }

    @Test("given a form over 10 MB, when uploaded, then it is sent from a temporary file that is gone afterwards")
    func uploadLargeMultipart() async throws {
        let service = StubNetworkService()
        let largeURL = try temporaryFile(Data(count: 10_500_000))
        defer { try? FileManager.default.removeItem(at: largeURL) }
        var form = MultipartFormData()
        form.append(fileURL: largeURL, name: "video")

        try await makeNetti(service: service).upload(TestEndpoint(), multipart: form)

        let upload = try #require(service.uploads.first)
        guard case .file(let encodedURL) = upload.source else {
            Issue.record("Expected a file-backed form, got \(upload.source)")
            return
        }
        #expect(encodedURL != largeURL)
        #expect(FileManager.default.fileExists(atPath: encodedURL.path) == false)
    }

    // MARK: - Download

    @Test("given a download without destination, when it completes, then the file stays in the temporary directory and progress ends at 1.0")
    func downloadDefaultDestination() async throws {
        let payload = testPayload(count: 256 * 1024)
        let server = try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(headers: ["Content-Type": "application/octet-stream"], body: .data(payload))
        }
        defer { server.stop() }
        let recorder = ProgressRecorder()
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))

        let response = try await netti.download(URLEndpoint(server.url("/file")), progress: recorder.handler)

        let fileURL = try #require(response.fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        #expect(try Data(contentsOf: fileURL) == payload)
        #expect(fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
            || fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        recorder.expectCompleted(total: Int64(payload.count))
    }

    @Test("given a destination in a missing directory, when downloaded, then the directory is created and the file moved there")
    func downloadCreatesDirectories() async throws {
        let service = StubNetworkService(download: Self.downloadReturning(Data("new".utf8)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-\(UUID().uuidString)/nested")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let destination = directory.appendingPathComponent("file.bin")

        let response = try await makeNetti(service: service).download(TestEndpoint(), to: destination)

        #expect(response.fileURL == destination)
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @Test("given an existing destination, when downloaded with replace, then the old file is replaced; without it, fileSystem is thrown")
    func downloadReplacesExisting() async throws {
        let service = StubNetworkService(download: Self.downloadReturning(Data("new".utf8)))
        let destination = try temporaryFile(Data("old".utf8))
        defer { try? FileManager.default.removeItem(at: destination) }
        let netti = makeNetti(service: service)

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPDownloadResponse<URL> in
            try await netti.download(TestEndpoint(), to: destination)
        }
        #expect(error?.isFileSystem == true)
        #expect(try Data(contentsOf: destination) == Data("old".utf8))

        try await netti.download(TestEndpoint(), to: destination, options: [.removePreviousFile])

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @Test("given a cancelled download, when resumed with the error's resume data, then it continues from the partial content")
    func downloadResume() async throws {
        let payload = testPayload(count: 512 * 1024)
        let half = payload.count / 2
        let server = try await LocalHTTPServer.start { request in
            var headers = ["Content-Type": "application/octet-stream", "ETag": "\"v1\"", "Accept-Ranges": "bytes"]
            headers["Last-Modified"] = "Mon, 26 Oct 2026 10:00:00 GMT"
            guard let range = request.header("range"), let start = Int(range.dropFirst("bytes=".count).prefix { $0 != "-" }) else {
                return LocalHTTPServer.Response(headers: headers, body: .stall(prefix: payload.prefix(half), contentLength: payload.count))
            }
            headers["Content-Range"] = "bytes \(start)-\(payload.count - 1)/\(payload.count)"
            return LocalHTTPServer.Response(status: 206, headers: headers, body: .data(Data(payload[start...])))
        }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))
        let endpoint = URLEndpoint(server.url("/file"))
        // The server stalls after `half`, but the transport may never report that last write while it
        // stalls (seen with plain URLSession under load), so the first report is the sync point.
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()

        let firstAttempt = Task {
            try await netti.download(endpoint) { progress in
                if progress.completedUnitCount > 0 {
                    startedContinuation.yield()
                }
            }
        }
        for await _ in started {
            break
        }
        firstAttempt.cancel()
        let error = await #expect(throws: HTTPRequestError.self) { try await firstAttempt.value }

        guard case .downloadFailed(let underlying, let resumeData)? = error else {
            Issue.record("Expected downloadFailed, got \(String(describing: error))")
            return
        }
        #expect(underlying.isCancelled)

        let resumed = try await netti.download(endpoint, resumeData: resumeData)

        let fileURL = try #require(resumed.fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        #expect(resumed.statusCode == 206)
        #expect(try Data(contentsOf: fileURL) == payload)
    }

    @Test("given a download rejected by validation, when it completes, then the temporary file is deleted")
    func downloadValidationFailureDeletesFile() async throws {
        let fileURL = try temporaryFile(Data("error page".utf8))
        let service = StubNetworkService(download: { request, _, _ in
            HTTPDownloadResponse(
                request: request,
                response: HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil),
                fileURL: fileURL
            )
        })
        var endpoint = TestEndpoint()
        endpoint.validation = ResponseValidation()

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPDownloadResponse<URL> in
            try await makeNetti(service: service).download(endpoint)
        }

        guard case .unacceptableStatusCode(500, _)? = error else {
            Issue.record("Expected unacceptableStatusCode(500), got \(String(describing: error))")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    // MARK: - Resume Data For Another URL (TM-39)

    @Test("given resume data from another URL, when an endpoint is downloaded with it, then the resume data is discarded and the endpoint downloads fresh")
    func downloadResume_otherURL_startsFresh() async throws {
        let payload = testPayload(count: 512 * 1024)
        let other = Data("other endpoint".utf8)
        let server = try await LocalHTTPServer.start { request in
            guard request.path == "/file" else {
                return LocalHTTPServer.Response(headers: ["Content-Type": "application/octet-stream"], body: .data(other))
            }
            return LocalHTTPServer.Response(
                headers: ["Content-Type": "application/octet-stream", "ETag": "\"v1\"", "Accept-Ranges": "bytes"],
                body: .stall(prefix: payload.prefix(payload.count / 2), contentLength: payload.count)
            )
        }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))
        let resumeData = try await partialResumeData(netti: netti, endpoint: URLEndpoint(server.url("/file")))

        let resumed = try await netti.download(URLEndpoint(server.url("/other")), resumeData: resumeData)

        let fileURL = try #require(resumed.fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        #expect(resumed.statusCode == 200)
        #expect(try Data(contentsOf: fileURL) == other)
        let last = try #require(server.requests.last)
        #expect(last.path == "/other")
        #expect(last.header("range") == nil)
    }

    @Test("given resume data that does not parse, when an endpoint is downloaded with it, then the endpoint downloads fresh")
    func downloadResume_unreadableResumeData_startsFresh() async throws {
        let body = Data("fresh".utf8)
        let server = try await LocalHTTPServer.start { _ in
            LocalHTTPServer.Response(headers: ["Content-Type": "application/octet-stream"], body: .data(body))
        }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))

        let response = try await netti.download(URLEndpoint(server.url("/file")), resumeData: Data("not resume data".utf8))

        let fileURL = try #require(response.fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        #expect(response.statusCode == 200)
        #expect(try Data(contentsOf: fileURL) == body)
    }

    // MARK: - Helpers

    /// Starts downloading `endpoint`, whose server stalls mid-body, cancels it once bytes arrived,
    /// and returns the resume data of the failure.
    private func partialResumeData(netti: Netti, endpoint: URLEndpoint) async throws -> Data {
        // The transport may never report the stalled write, so the first report is the sync point.
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let attempt = Task {
            try await netti.download(endpoint) { progress in
                if progress.completedUnitCount > 0 {
                    startedContinuation.yield()
                }
            }
        }
        for await _ in started {
            break
        }
        attempt.cancel()
        let error = await #expect(throws: HTTPRequestError.self) { try await attempt.value }
        guard case .downloadFailed(_, let resumeData)? = error else {
            throw ResumeDataMissing()
        }
        return resumeData
    }

    private struct ResumeDataMissing: Error {}

    private func temporaryFile(_ data: Data, name: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A download handler that writes `data` to a new temporary file and returns it with a 200.
    private static func downloadReturning(_ data: Data) -> @Sendable (URLRequest, Data?, ProgressHandler?) async -> HTTPDownloadResponse<URL> {
        { request, _, _ in
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("netti-download-\(UUID().uuidString)")
            try? data.write(to: fileURL)
            return HTTPDownloadResponse(
                request: request,
                response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil),
                fileURL: fileURL
            )
        }
    }
}
