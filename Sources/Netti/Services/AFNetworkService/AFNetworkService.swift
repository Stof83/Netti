//
//  AFNetworkService.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Alamofire
import Foundation
import os

/// A ``NetworkService`` built on Alamofire.
///
/// Deprecated: ``URLSessionNetworkService`` is the default engine. This one is kept only so the
/// shared contract suite can prove both engines behave identically before Alamofire is removed.
///
/// - Important: Deprecated. Migrate to ``URLSessionNetworkService``, which takes the same
///   ``ServerTrustPolicy``: `URLSessionNetworkService(trustPolicy: policy)`.
///
/// ```swift
/// let service = AFNetworkService(trustPolicy: ServerTrustPolicy(["api.example.com": .publicKeys(["hashA=", "hashB="])]))
/// ```
///
/// The ``ServerTrustPolicy`` is enforced through Alamofire's trust manager, which delegates every
/// decision to the policy, so pinning gives the same result on both engines. WebSockets are
/// opened by the native engine with the same configuration and policy, because Alamofire's
/// WebSocket API is not public.
@available(*, deprecated, message: "Use URLSessionNetworkService. AFNetworkService is kept only for parity checks and will be removed with Alamofire.")
public final class AFNetworkService: NetworkService {

    // MARK: - Constants

    private static let callbackQueueLabel = "netti.alamofire.callbacks"

    // MARK: - Properties

    private let session: Session
    private let webSocketService: URLSessionNetworkService
    private let callbackQueue = DispatchQueue(label: callbackQueueLabel)

    // MARK: - Initialization

    /// Creates an engine.
    ///
    /// - Parameters:
    ///   - configuration: The session configuration. Defaults to Alamofire's default, which adds
    ///     `Accept-Encoding`, `Accept-Language` and `User-Agent` headers.
    ///   - trustPolicy: The server trust policy. `nil`, the default, leaves trust to the system.
    ///
    /// TLS 1.2 or later is required; a configuration that already requires more keeps it.
    public convenience init(configuration: URLSessionConfiguration = .af.default, trustPolicy: ServerTrustPolicy? = nil) {
        let configuration = configuration.copyRequiringTLS12()
        self.init(
            session: Session(configuration: configuration, serverTrustManager: trustPolicy.map(PolicyServerTrustManager.init)),
            webSocketService: URLSessionNetworkService(configuration: configuration, trustPolicy: trustPolicy)
        )
    }

    /// Creates an engine from a 1.x configuration. Only its `serverTrustManager` is used:
    /// encoding and caching moved to ``Netti``.
    ///
    /// - Important: Deprecated. Use ``init(configuration:trustPolicy:)`` with a ``ServerTrustPolicy``,
    ///   or better, ``URLSessionNetworkService/init(configuration:trustPolicy:redirectHandler:maxConnectionsPerHost:maximumResponseSize:maximumRequestDuration:)``.
    ///
    /// - Parameter configuration: The 1.x configuration.
    @available(*, deprecated, message: "Use init(configuration:trustPolicy:) with a ServerTrustPolicy.")
    public convenience init(configuration: AFConfiguration) {
        let sessionConfiguration = URLSessionConfiguration.af.default.copyRequiringTLS12()
        let webSocketDelegate = SessionDelegate(trustEvaluator: configuration.serverTrustManager.map(TrustManagerEvaluator.init))
        self.init(
            session: Session(configuration: sessionConfiguration, serverTrustManager: configuration.serverTrustManager),
            webSocketService: URLSessionNetworkService(configuration: sessionConfiguration, delegate: webSocketDelegate)
        )
    }

    private init(session: Session, webSocketService: URLSessionNetworkService) {
        self.session = session
        self.webSocketService = webSocketService
    }

    /// The configuration of the underlying session.
    var sessionConfiguration: URLSessionConfiguration {
        session.session.configuration
    }

    // MARK: - NetworkService

    /// Asynchronously sends `request` with Alamofire and returns the whole response body.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: The response; a non-2xx status is returned, not thrown.
    /// - Throws: ``HTTPRequestError`` when no response is received.
    public func data(for request: URLRequest) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        try checkCancellation()
        return try await response(of: session.request(request), for: request)
    }

    /// Asynchronously uploads `source` as the body of `request` with Alamofire.
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

        let uploadRequest = switch source {
            case .data(let data):
                session.upload(data, with: request)
            case .file(let fileURL):
                session.upload(fileURL, with: request)
            case .stream(let makeStream):
                session.upload(makeStream(), with: request)
        }
        let reporter = ProgressReporter(progress)
        if let reporter {
            uploadRequest.uploadProgress(queue: callbackQueue) { progress in
                reporter.report(completed: progress.completedUnitCount, total: progress.totalUnitCount)
            }
        }
        let response = try await response(of: uploadRequest, for: request)
        reporter?.finish(completed: uploadRequest.task?.countOfBytesSent ?? 0)
        return response
    }

    /// Asynchronously downloads the response body of `request` with Alamofire to a temporary file.
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
        let destination: DownloadRequest.Destination = { temporaryURL, _ in
            ((try? DownloadDirectory.newFileURL()) ?? temporaryURL.appendingPathExtension(UUID().uuidString), [])
        }
        let downloadRequest = ResumeData.usable(resumeData, for: request.url).map { session.download(resumingWith: $0, to: destination) }
            ?? session.download(request, to: destination)
        let reporter = ProgressReporter(progress)
        if let reporter {
            downloadRequest.downloadProgress(queue: callbackQueue) { progress in
                reporter.report(completed: progress.completedUnitCount, total: progress.totalUnitCount)
            }
        }

        let response = await withTaskCancellationHandler {
            await downloadRequest.serializingDownloadedFileURL(automaticallyCancelling: false).response
        } onCancel: {
            downloadRequest.cancel(producingResumeData: true)
        }

        switch response.result {
            case .success(let fileURL):
                reporter?.finish(completed: downloadRequest.task?.countOfBytesReceived ?? 0)
                return HTTPDownloadResponse(request: request, response: response.response, fileURL: fileURL, metrics: response.metrics)
            case .failure(let error):
                return HTTPDownloadResponse(
                    request: request,
                    response: response.response,
                    fileURL: nil,
                    resumeData: response.resumeData,
                    error: Self.requestError(error, for: request),
                    metrics: response.metrics
                )
        }
    }

    /// Asynchronously sends `request` with Alamofire and returns once the response headers arrive.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: The response, whose ``HTTPStreamResponse/body`` yields chunks as they arrive.
    /// - Throws: ``HTTPRequestError`` when no response headers are received.
    public func bytes(for request: URLRequest) async throws(HTTPRequestError) -> HTTPStreamResponse {
        try checkCancellation()
        let streamRequest = session.streamRequest(request)
        let (body, bodyContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        // Capturing the session keeps it alive while the body is consumed: Alamofire traps if a
        // session is released with a request still running, and the body outlives this call.
        bodyContinuation.onTermination = { [session] termination in
            withExtendedLifetime(session) {
                if case .cancelled = termination {
                    streamRequest.cancel()
                }
            }
        }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<HTTPURLResponse?, HTTPRequestError>, Never>) in
                let pending = OSAllocatedUnfairLock<CheckedContinuation<Result<HTTPURLResponse?, HTTPRequestError>, Never>?>(initialState: continuation)
                let resumeOnce: @Sendable (Result<HTTPURLResponse?, HTTPRequestError>) -> Void = { result in
                    pending.withLock { pending in
                        defer { pending = nil }
                        return pending
                    }?.resume(returning: result)
                }
                streamRequest
                    .onHTTPResponse(on: callbackQueue) { response in
                        resumeOnce(.success(response))
                    }
                    .responseStream(on: callbackQueue) { stream in
                        switch stream.event {
                            case .stream(let chunk):
                                bodyContinuation.yield(chunk.get())
                            case .complete(let completion):
                                guard let error = completion.error else {
                                    resumeOnce(.success(completion.response))
                                    bodyContinuation.finish()
                                    return
                                }
                                let failure = Self.requestError(error, for: request)
                                resumeOnce(.failure(failure))
                                bodyContinuation.finish(throwing: failure)
                        }
                    }
            }
        } onCancel: {
            streamRequest.cancel()
        }
        return HTTPStreamResponse(request: request, response: try result.get(), body: body)
    }

    /// Asynchronously opens a WebSocket with the native `URLSession` engine, returning once the handshake succeeds.
    ///
    /// - Parameter request: The `ws` or `wss` request, with any headers to send in the handshake.
    /// - Returns: The open connection.
    /// - Throws: ``HTTPRequestError`` when the handshake fails.
    public func webSocket(for request: URLRequest) async throws(HTTPRequestError) -> any WebSocketTransport {
        try await webSocketService.webSocket(for: request)
    }
}

// MARK: - Private Methods

@available(*, deprecated)
extension AFNetworkService {
    private func checkCancellation() throws(HTTPRequestError) {
        if Task.isCancelled {
            throw .cancelled
        }
    }

    private func response(of dataRequest: DataRequest, for request: URLRequest) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        let response = await dataRequest.serializingResponse(using: RawDataSerializer()).response
        switch response.result {
            case .success(let body):
                return HTTPResponse(request: request, response: response.response, data: body, rawData: body, metrics: response.metrics)
            case .failure(let error):
                throw Self.requestError(error, for: request)
        }
    }

    /// Maps an Alamofire error to the error the native engine throws in the same situation.
    static func requestError(_ error: AFError, for request: URLRequest) -> HTTPRequestError {
        switch error {
            case .explicitlyCancelled:
                return .cancelled
            case .sessionTaskFailed(let underlyingError):
                return .transport(underlyingError)
            case .serverTrustEvaluationFailed(let reason):
                if case .customEvaluationFailed(let policyError as HTTPRequestError) = reason {
                    return policyError
                }
                return .serverTrustEvaluationFailed(host: request.url?.host ?? "", reason: error.localizedDescription)
            case .createUploadableFailed(let underlyingError), .downloadedFileMoveFailed(let underlyingError, _, _):
                return .fileSystem(underlyingError)
            case .invalidURL:
                return .invalidURL
            default:
                return .requestFailed(URLError(.unknown, userInfo: [NSUnderlyingErrorKey: error]))
        }
    }
}

// MARK: - RawDataSerializer

/// Returns the body as received (empty when there is none) and never validates the status,
/// matching the native engine.
private struct RawDataSerializer: DataResponseSerializerProtocol {
    func serialize(request: URLRequest?, response: HTTPURLResponse?, data: Data?, error: (any Error)?) throws -> Data {
        if let error {
            throw error
        }
        return data ?? Data()
    }
}
