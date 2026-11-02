//
//  StubNetworkService.swift
//  NettiTesting
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation
import os

/// A transport that never touches the network: handlers answer, and every call is recorded.
///
/// Use it when a test cares about what reaches the engine rather than about HTTP itself, or when
/// it needs streams, downloads or WebSockets, which ``StubServer`` cannot fake. Every handler has
/// a default, so only the one the test exercises needs replacing.
///
/// ```swift
/// let service = StubNetworkService(data: { try .json(for: $0, ["id": 1]) })
/// let netti = Netti(service: service)
/// netti.isLoggingEnabled = false
/// _ = try await netti.get(UserAPI.list)
/// #expect(service.requests.count == 1)
/// ```
///
/// A handler that throws makes the call fail with that error as an ``HTTPRequestError``: one passes
/// through, and a `URLError` becomes ``HTTPRequestError/requestFailed(_:)``.
public final class StubNetworkService: NetworkService {

    // MARK: - Types

    /// Answers a data, upload or download-less request.
    public typealias DataHandler = @Sendable (URLRequest) async throws -> HTTPResponse<Data>

    /// Answers a download.
    public typealias DownloadHandler = @Sendable (URLRequest, Data?, ProgressHandler?) async -> HTTPDownloadResponse<URL>

    /// Answers a streaming request.
    public typealias BytesHandler = @Sendable (URLRequest) async throws -> HTTPStreamResponse

    /// Opens a WebSocket.
    public typealias WebSocketHandler = @Sendable (URLRequest) async throws -> any WebSocketTransport

    /// An upload the service received.
    public struct Upload: Sendable {
        /// The request.
        public let request: URLRequest
        /// Where the body came from.
        public let source: UploadSource
    }

    /// A download the service received.
    public struct Download: Sendable {
        /// The request.
        public let request: URLRequest
        /// The resume data the caller passed, if any.
        public let resumeData: Data?
    }

    private struct Recordings {
        var requests: [URLRequest] = []
        var uploads: [Upload] = []
        var downloads: [Download] = []
        var webSocketRequests: [URLRequest] = []
    }

    // MARK: - Properties

    private let recordings = OSAllocatedUnfairLock(initialState: Recordings())
    private let dataHandler: DataHandler
    private let downloadHandler: DownloadHandler
    private let bytesHandler: BytesHandler
    private let webSocketHandler: WebSocketHandler

    /// Every request received, whatever its kind, in arrival order.
    public var requests: [URLRequest] {
        recordings.withLock { $0.requests }
    }

    /// The uploads received.
    public var uploads: [Upload] {
        recordings.withLock { $0.uploads }
    }

    /// The downloads received.
    public var downloads: [Download] {
        recordings.withLock { $0.downloads }
    }

    /// The WebSocket handshakes received.
    public var webSocketRequests: [URLRequest] {
        recordings.withLock { $0.webSocketRequests }
    }

    // MARK: - Initialization

    /// Creates a stub transport.
    ///
    /// - Parameters:
    ///   - data: Answers data and upload requests. Defaults to an empty `200`.
    ///   - download: Answers downloads. Defaults to a cancelled download.
    ///   - bytes: Answers streaming requests. Defaults to throwing ``HTTPRequestError/cancelled``.
    ///   - webSocket: Opens WebSockets. Defaults to an echoing ``StubWebSocketTransport``.
    public init(
        data: @escaping DataHandler = { .stub(for: $0) },
        download: @escaping DownloadHandler = { request, _, _ in
            HTTPDownloadResponse(request: request, response: nil, fileURL: nil, error: HTTPRequestError.cancelled)
        },
        bytes: @escaping BytesHandler = { _ in throw HTTPRequestError.cancelled },
        webSocket: @escaping WebSocketHandler = { _ in StubWebSocketTransport() }
    ) {
        self.dataHandler = data
        self.downloadHandler = download
        self.bytesHandler = bytes
        self.webSocketHandler = webSocket
    }

    // MARK: - NetworkService

    /// Asynchronously records `request` and answers it with the `data` handler.
    ///
    /// - Parameter request: The request.
    /// - Returns: The handler's response.
    /// - Throws: The handler's error, as an ``HTTPRequestError``.
    public func data(for request: URLRequest) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        recordings.withLock { $0.requests.append(request) }
        return try await mapped { try await dataHandler(request) }
    }

    /// Asynchronously records the upload, reports full progress once, and answers it with the
    /// `data` handler.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - source: The body, recorded in ``uploads``.
    ///   - progress: Called once with `1.0`. Optional.
    /// - Returns: The handler's response.
    /// - Throws: ``HTTPRequestError/fileSystem(_:)`` when a file source cannot be read, before the
    ///   upload is recorded; otherwise the handler's error, as an ``HTTPRequestError``.
    public func upload(for request: URLRequest, from source: UploadSource, progress: ProgressHandler?) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        try source.validate()
        recordings.withLock {
            $0.uploads.append(Upload(request: request, source: source))
            $0.requests.append(request)
        }
        progress?(TransferProgress(completedUnitCount: 1, totalUnitCount: 1))
        return try await mapped { try await dataHandler(request) }
    }

    /// Asynchronously records the download and answers it with the `download` handler.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - resumeData: The resume data, recorded in ``downloads``.
    ///   - progress: Passed to the handler.
    /// - Returns: The handler's response.
    public func download(for request: URLRequest, resumeData: Data?, progress: ProgressHandler?) async -> HTTPDownloadResponse<URL> {
        recordings.withLock {
            $0.downloads.append(Download(request: request, resumeData: resumeData))
            $0.requests.append(request)
        }
        return await downloadHandler(request, resumeData, progress)
    }

    /// Asynchronously records `request` and answers it with the `bytes` handler.
    ///
    /// - Parameter request: The request.
    /// - Returns: The handler's stream response.
    /// - Throws: The handler's error, as an ``HTTPRequestError``.
    public func bytes(for request: URLRequest) async throws(HTTPRequestError) -> HTTPStreamResponse {
        recordings.withLock { $0.requests.append(request) }
        return try await mapped { try await bytesHandler(request) }
    }

    /// Asynchronously records the handshake in ``webSocketRequests`` and opens the `webSocket`
    /// handler's transport.
    ///
    /// - Parameter request: The handshake request.
    /// - Returns: The handler's transport.
    /// - Throws: The handler's error, as an ``HTTPRequestError``.
    public func webSocket(for request: URLRequest) async throws(HTTPRequestError) -> any WebSocketTransport {
        recordings.withLock { $0.webSocketRequests.append(request) }
        return try await mapped { try await webSocketHandler(request) }
    }

    private func mapped<Value>(_ body: () async throws -> Value) async throws(HTTPRequestError) -> Value {
        do {
            return try await body()
        } catch {
            throw .transport(error)
        }
    }
}

// MARK: - Responses

extension HTTPResponse where T == Data {

    /// A response to `request` with a status, headers and body, for ``StubNetworkService`` handlers.
    ///
    /// - Parameters:
    ///   - request: The request being answered.
    ///   - status: The status code. `200` by default.
    ///   - headers: The response headers.
    ///   - body: The response body.
    ///   - metrics: The task metrics, if the test needs them.
    /// - Returns: The response.
    public static func stub(
        for request: URLRequest,
        status: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data(),
        metrics: URLSessionTaskMetrics? = nil
    ) -> HTTPResponse<Data> {
        let url = request.url ?? URL(fileURLWithPath: "/")
        return HTTPResponse(
            request: request,
            response: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers),
            data: body,
            rawData: body,
            metrics: metrics
        )
    }

    /// A JSON response to `request`, for ``StubNetworkService`` handlers.
    ///
    /// - Parameters:
    ///   - request: The request being answered.
    ///   - status: The status code. `200` by default.
    ///   - value: The value to encode as the body.
    ///   - encoder: Encodes `value`. A default `JSONEncoder` unless given.
    /// - Returns: The response, with `Content-Type: application/json`.
    /// - Throws: `EncodingError` when `value` does not encode.
    public static func json(
        for request: URLRequest,
        status: Int = 200,
        _ value: some Encodable,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> HTTPResponse<Data> {
        stub(for: request, status: status, headers: ["Content-Type": "application/json"], body: try encoder.encode(value))
    }
}
