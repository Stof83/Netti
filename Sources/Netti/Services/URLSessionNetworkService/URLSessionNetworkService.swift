//
//  URLSessionNetworkService.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 05/05/25.
//

import Foundation

/// The default ``NetworkService``, built on `URLSession` with no third-party dependency.
///
/// ```swift
/// let service = URLSessionNetworkService()
/// let pinned = URLSessionNetworkService(trustPolicy: ServerTrustPolicy(["api.example.com": .publicKeys(["hashA=", "hashB="])]))
/// ```
///
/// One instance owns one `URLSession`; share it rather than creating one per request.
///
/// Secure by default, with no configuration:
/// - TLS 1.2 or later is required; a configuration that already requires more keeps it.
/// - Redirects follow ``RedirectHandler/secure``: no `https` to `http` downgrade, no credentials or
///   body sent to another origin.
/// - A data or upload response body larger than `maximumResponseSize`, 64 MB by default, fails
///   with ``HTTPRequestError/requestFailed(_:)`` carrying `URLError.dataLengthExceedsMaximum`.
/// - A byte stream or WebSocket whose consumer falls more than 8 MB or 1,000 messages behind fails
///   with the same error.
/// - A response to a request carrying `Authorization` is never stored in `URLCache`.
/// - A data or upload request, response included, must finish within `maximumRequestDuration`,
///   300 seconds by default, or it fails with ``HTTPRequestError/requestFailed(_:)`` carrying
///   `URLError.timedOut`, so a server that drips bytes cannot hold it open for days. Byte streams,
///   WebSockets and downloads are exempt.
public final class URLSessionNetworkService: NetworkService {

    // MARK: - Constants

    private static let delegateQueueName = "netti.session.delegate"

    // MARK: - Properties

    private let session: URLSession
    private let delegate: SessionDelegate

    // MARK: - Initialization

    /// Creates an engine.
    ///
    /// - Parameters:
    ///   - configuration: The session configuration. Defaults to `.default`. The engine uses a copy
    ///     whose TLS minimum is raised to 1.2; everything else, `timeoutIntervalForResource`
    ///     included, is kept as given. A `timeoutIntervalForResource` you set applies to every task,
    ///     streams and WebSockets included.
    ///   - trustPolicy: The server trust policy, applied to every request and WebSocket.
    ///     `nil`, the default, leaves trust to the system.
    ///   - redirectHandler: Decides what happens on a redirect. `nil`, the default, uses
    ///     ``RedirectHandler/secure``; pass ``RedirectHandler/follow`` to follow every redirect unchanged.
    ///   - maxConnectionsPerHost: The most simultaneous connections to one host. `nil`, the default,
    ///     keeps the configuration's value.
    ///   - maximumResponseSize: The most bytes a data or upload response body may have; 64 MB by
    ///     default, `nil` for no limit. Downloads and byte streams are not limited.
    ///   - maximumRequestDuration: The most time a data or upload request may take from start to
    ///     end, response body included; 300 seconds by default. A request still running at this
    ///     deadline is cancelled and fails with ``HTTPRequestError/requestFailed(_:)`` carrying
    ///     `URLError.timedOut`. It is a total time, unlike `URLRequest.timeoutInterval`, which is an
    ///     idle timeout that a server sending one byte at a time keeps resetting. Byte streams,
    ///     WebSockets and downloads have no deadline, so a live feed stays open. Pass a longer
    ///     duration for large uploads on slow networks, or `nil` for no limit.
    public convenience init(
        configuration: URLSessionConfiguration = .default,
        trustPolicy: ServerTrustPolicy? = nil,
        redirectHandler: RedirectHandler? = nil,
        maxConnectionsPerHost: Int? = nil,
        maximumResponseSize: Int? = 64 * 1024 * 1024,
        maximumRequestDuration: Duration? = .seconds(300)
    ) {
        let configuration = configuration.copyRequiringTLS12()
        if let maxConnectionsPerHost {
            configuration.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        }
        self.init(
            configuration: configuration,
            delegate: SessionDelegate(
                trustEvaluator: trustPolicy,
                redirectHandler: redirectHandler,
                maximumResponseSize: maximumResponseSize,
                maximumRequestDuration: maximumRequestDuration
            )
        )
    }

    init(configuration: URLSessionConfiguration, delegate: SessionDelegate) {
        let delegateQueue = OperationQueue()
        delegateQueue.name = Self.delegateQueueName
        delegateQueue.maxConcurrentOperationCount = 1
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    }

    /// The configuration of the underlying session.
    var sessionConfiguration: URLSessionConfiguration {
        session.configuration
    }

    /// The most bytes a data or upload response body may have; `nil` is unlimited.
    var maximumResponseSize: Int? {
        delegate.maximumResponseSize
    }

    /// The total time a data or upload request may take; `nil` is unlimited.
    var maximumRequestDuration: Duration? {
        delegate.maximumRequestDuration
    }

    deinit {
        // The session retains its delegate until invalidated; running tasks still finish.
        session.finishTasksAndInvalidate()
    }

    // MARK: - NetworkService

    /// Asynchronously sends `request` with `URLSession` and returns the whole response body.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: The response; a non-2xx status is returned, not thrown.
    /// - Throws: ``HTTPRequestError`` when no response is received.
    public func data(for request: URLRequest) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        try checkCancellation()
        return try await delegate.data(session.dataTask(with: request), request: request)
    }

    /// Asynchronously uploads `source` as the body of `request` with `URLSession`.
    ///
    /// - Parameters:
    ///   - request: The request to send. Its `httpBody` is ignored.
    ///   - source: The body: in-memory data, a file, or a stream.
    ///   - progress: Called as the body is sent. Optional.
    /// - Returns: The response; a non-2xx status is returned, not thrown.
    /// - Throws: ``HTTPRequestError/fileSystem(_:)`` before any network traffic when a file source
    ///   cannot be read; otherwise ``HTTPRequestError`` when no response is received.
    public func upload(
        for request: URLRequest,
        from source: UploadSource,
        progress: ProgressHandler?
    ) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        try checkCancellation()
        try source.validate()

        let reporter = ProgressReporter(progress)
        switch source {
            case .data(let data):
                return try await delegate.data(session.uploadTask(with: request, from: data), request: request, progress: reporter)
            case .file(let fileURL):
                return try await delegate.data(session.uploadTask(with: request, fromFile: fileURL), request: request, progress: reporter)
            case .stream(let makeStream):
                return try await delegate.data(
                    session.uploadTask(withStreamedRequest: request),
                    request: request,
                    progress: reporter,
                    bodyStream: makeStream
                )
        }
    }

    /// Asynchronously downloads the response body of `request` with `URLSession` to a temporary file.
    ///
    /// - Parameters:
    ///   - request: The request to send. When `resumeData` continues a download of the same URL,
    ///     the request embedded in the resume data is sent instead, with its original headers.
    ///   - resumeData: Data from a previous ``HTTPDownloadResponse/resumeData`` to continue from.
    ///     Discarded, so the download starts fresh, when its URL differs from `request`'s or
    ///     cannot be read.
    ///   - progress: Called as the body is received. Optional.
    /// - Returns: On success, a response whose `fileURL` is a temporary file the caller moves or
    ///   deletes; on failure, a response whose `error` holds the ``HTTPRequestError``.
    public func download(
        for request: URLRequest,
        resumeData: Data?,
        progress: ProgressHandler?
    ) async -> HTTPDownloadResponse<URL> {
        guard Task.isCancelled == false else {
            return HTTPDownloadResponse(request: request, response: nil, fileURL: nil, resumeData: resumeData, error: HTTPRequestError.cancelled)
        }
        let task = ResumeData.usable(resumeData, for: request.url).map(session.downloadTask(withResumeData:))
            ?? session.downloadTask(with: request)
        return await delegate.download(task, request: request, progress: ProgressReporter(progress))
    }

    /// Asynchronously sends `request` with `URLSession` and returns once the response headers arrive.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: The response, whose ``HTTPStreamResponse/body`` yields chunks as they arrive.
    /// - Throws: ``HTTPRequestError`` when no response headers are received.
    public func bytes(for request: URLRequest) async throws(HTTPRequestError) -> HTTPStreamResponse {
        try checkCancellation()
        return try await delegate.stream(session.dataTask(with: request), request: request)
    }

    /// Asynchronously opens a WebSocket with `URLSession`, returning once the handshake succeeds.
    ///
    /// - Parameter request: The `ws` or `wss` request, with any headers to send in the handshake.
    /// - Returns: The open connection.
    /// - Throws: ``HTTPRequestError`` when the handshake fails.
    public func webSocket(for request: URLRequest) async throws(HTTPRequestError) -> any WebSocketTransport {
        try checkCancellation()
        let task = session.webSocketTask(with: request)
        try await delegate.open(task, request: request)
        return URLSessionWebSocketTransport(task: task)
    }

    // MARK: - Private Helpers

    private func checkCancellation() throws(HTTPRequestError) {
        if Task.isCancelled {
            throw .cancelled
        }
    }
}

// MARK: - URLSessionConfiguration

extension URLSessionConfiguration {
    /// A copy that negotiates TLS 1.2 or later, keeping a stricter minimum already set.
    func copyRequiringTLS12() -> URLSessionConfiguration {
        let configuration = copy() as? URLSessionConfiguration ?? self
        if configuration.tlsMinimumSupportedProtocolVersion.rawValue < tls_protocol_version_t.TLSv12.rawValue {
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        }
        return configuration
    }
}
