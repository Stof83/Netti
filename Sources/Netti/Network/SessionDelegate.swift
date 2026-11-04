//
//  SessionDelegate.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation
import os

/// The `URLSession` delegate behind ``URLSessionNetworkService``.
///
/// It keeps one ``TaskState`` per running task in a lock-protected registry, keyed by
/// `taskIdentifier`, and turns delegate callbacks into the engine contract:
/// - server trust challenges are decided by the ``ServerTrustPolicy``, and a rejection surfaces as
///   ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)`` instead of a cancellation;
/// - client-certificate challenges are answered with the ``ClientIdentity`` when one is configured,
///   and left to the system otherwise; a server that rejects the identity fails the request with
///   `URLError.clientCertificateRejected`, never an anonymous retry;
/// - upload and download progress go through a ``ProgressReporter``, and so does the received
///   body of a data task, rate-bounded by bytes;
/// - redirects go through a ``RedirectHandler``, ``RedirectHandler/secure`` when none is given;
/// - data-task bodies are capped at `maximumResponseSize`, and byte-stream buffers at
///   `maximumBufferedStreamBytes` unread bytes;
/// - data and upload tasks are cancelled with `URLError.timedOut` once `maximumRequestDuration`
///   passes; byte streams, WebSockets and downloads have no deadline;
/// - responses to requests carrying `Authorization` are never stored in `URLCache`;
/// - metrics are attached to the response;
/// - completion resumes the waiting caller exactly once and removes the task from the registry.
///
/// Tasks are registered before they are resumed, so no callback can arrive for an unknown task.
/// The session calls back on a serial queue, so callbacks for one task arrive in order.
final class SessionDelegate: NSObject, Sendable {

    // MARK: - Constants

    /// The longest deadline scheduled; a longer `maximumRequestDuration` is clamped to it.
    private static let longestDeadline = Duration.seconds(Int64(Int32.max))

    /// The fewest bytes a data task's received count advances between two progress reports.
    private static let minimumReportStep: Int64 = 16 * 1_024

    // MARK: - Properties

    private let trustEvaluator: (any ServerTrustEvaluating)?
    private let clientIdentity: ClientIdentity?
    private let redirectHandler: RedirectHandler
    private let maximumBufferedStreamBytes: Int
    private let registry = OSAllocatedUnfairLock<[Int: TaskState]>(initialState: [:])

    /// The most bytes a data or upload task's response body may have; `nil` is unlimited.
    let maximumResponseSize: Int?

    /// The total time a data or upload task may take; `nil` is unlimited.
    let maximumRequestDuration: Duration?

    /// The number of tasks currently tracked; zero once every task has completed.
    var registeredTaskCount: Int {
        registry.withLock { $0.count }
    }

    // MARK: - Initialization

    /// Creates a delegate.
    ///
    /// - Parameters:
    ///   - trustEvaluator: Decides server trust; `nil` leaves it to the system.
    ///   - redirectHandler: Decides redirects; `nil` uses ``RedirectHandler/secure``.
    ///   - maximumResponseSize: The most bytes a data or upload task's body may have; `nil` is unlimited.
    ///   - maximumRequestDuration: The total time a data or upload task may take; `nil` is unlimited.
    ///   - maximumBufferedStreamBytes: The most unread bytes a byte stream may buffer.
    ///   - clientIdentity: Presented on client-certificate challenges; `nil` leaves them to the system.
    init(
        trustEvaluator: (any ServerTrustEvaluating)?,
        redirectHandler: RedirectHandler? = nil,
        maximumResponseSize: Int? = nil,
        maximumRequestDuration: Duration? = nil,
        maximumBufferedStreamBytes: Int = StreamBufferMeter.defaultByteLimit,
        clientIdentity: ClientIdentity? = nil
    ) {
        self.trustEvaluator = trustEvaluator
        self.clientIdentity = clientIdentity
        self.redirectHandler = redirectHandler ?? .secure
        self.maximumResponseSize = maximumResponseSize
        self.maximumRequestDuration = maximumRequestDuration
        self.maximumBufferedStreamBytes = maximumBufferedStreamBytes
    }

    // MARK: - Running Tasks

    /// Runs a data or upload task and returns its buffered response.
    ///
    /// `progress` follows the bytes sent; `receiveProgress` follows the response body. The task
    /// fails with `URLError.timedOut` once `maximumRequestDuration` passes.
    func data(
        _ task: URLSessionTask,
        request: URLRequest,
        progress: ProgressReporter? = nil,
        receiveProgress: ProgressReporter? = nil,
        bodyStream: (@Sendable () -> InputStream)? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        var deadline: Task<Void, Never>?
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start(task, TaskState(
                    request: request,
                    completion: .data(continuation),
                    progress: progress,
                    receiveProgress: receiveProgress,
                    bodyStream: bodyStream
                ))
                // Scheduled once registered, so even an immediate deadline finds the task.
                deadline = scheduleDeadline(for: task)
            }
        } onCancel: {
            task.cancel()
        }
        // Ends the sleep and releases the task as soon as it completes.
        deadline?.cancel()
        return try result.get()
    }

    /// Runs a download task. Cancelling the calling task keeps the resume data.
    func download(
        _ task: URLSessionDownloadTask,
        request: URLRequest,
        progress: ProgressReporter?
    ) async -> HTTPDownloadResponse<URL> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start(task, TaskState(request: request, completion: .download(continuation), progress: progress))
            }
        } onCancel: {
            task.cancel(byProducingResumeData: { _ in })
        }
    }

    /// Runs a data task until its response headers arrive, then streams the body.
    ///
    /// The body fails with `URLError.dataLengthExceedsMaximum` once more than
    /// `maximumBufferedStreamBytes` sit unread in it.
    func stream(_ task: URLSessionDataTask, request: URLRequest) async throws(HTTPRequestError) -> HTTPStreamResponse {
        // `bufferingOldest(.max)` never drops, and its yield result reports how many chunks are unread.
        let (body, bodyContinuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(.max))
        bodyContinuation.onTermination = { termination in
            if case .cancelled = termination {
                task.cancel()
            }
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start(task, TaskState(request: request, completion: .stream(response: continuation, body: bodyContinuation)))
            }
        } onCancel: {
            task.cancel()
        }
        return HTTPStreamResponse(request: request, response: try result.get(), body: body)
    }

    /// Runs a WebSocket task until the handshake completes.
    func open(_ task: URLSessionWebSocketTask, request: URLRequest) async throws(HTTPRequestError) {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start(task, TaskState(request: request, completion: .webSocket(open: continuation)))
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
        try result.get()
    }

    /// Tracks `task` without resuming it; ``start(_:_:)`` registers then resumes.
    func register(_ task: URLSessionTask, _ state: TaskState) {
        let taskIdentifier = task.taskIdentifier
        registry.withLock { $0[taskIdentifier] = state }
    }
}

// MARK: - URLSessionDataDelegate, URLSessionDownloadDelegate, URLSessionWebSocketDelegate

extension SessionDelegate: URLSessionDataDelegate, URLSessionDownloadDelegate, URLSessionWebSocketDelegate {

    // Server trust and client certificates are handled at task level so a rejection can be
    // attributed to its task. With no session-level callback, URLSession delivers connection-level
    // challenges here for data, upload, download, byte-stream and WebSocket tasks alike.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = clientCertificateDisposition(for: challenge, task: task)
            ?? trustDisposition(for: challenge, task: task)
        completionHandler(disposition, credential)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // A later hop is a new connection; an identity shown to an earlier host says nothing about it.
        update(task) { $0.didPresentClientIdentity = false }
        let current = task.currentRequest ?? task.originalRequest
        let hasBody = task is URLSessionUploadTask
            || [task.originalRequest, request].contains { $0?.httpBody != nil || $0?.httpBodyStream != nil }
        switch redirectHandler.outcome(for: request, response: response, current: current, hasBody: hasBody) {
            case .send(let redirected):
                completionHandler(redirected)
            case .stop:
                completionHandler(nil)
            case .fail(let urlError):
                // Recorded first, so it wins over the cancellation that follows.
                update(task) { $0.failure = .requestFailed(urlError) }
                completionHandler(nil)
                task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        let factory = extract(task) { $0.bodyStream }
        completionHandler(factory?())
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        extract(task) { $0.progress }?.report(completed: totalBytesSent, total: totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        update(task) { $0.metrics = metrics }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let httpResponse = response as? HTTPURLResponse
        let limit = maximumResponseSize
        let step = update(dataTask) { state -> ResponseStep in
            state.response = httpResponse
            state.announcedLength = response.expectedContentLength
            guard state.failure == nil else {
                return .cancel
            }
            switch state.completion {
                case .data:
                    if let limit, response.expectedContentLength > limit {
                        state.failure = .requestFailed(URLError(.dataLengthExceedsMaximum))
                        return .cancel
                    }
                    return .allow(nil)
                case .stream(let continuation?, let body):
                    state.completion = .stream(response: nil, body: body)
                    return .allow(continuation)
                default:
                    return .allow(nil)
            }
        }
        switch step {
            case .allow(let responseContinuation):
                responseContinuation?.resume(returning: .success(httpResponse))
                completionHandler(.allow)
            case .cancel:
                completionHandler(.cancel)
            case nil:
                completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let limit = maximumResponseSize
        let minimumStep = Self.minimumReportStep
        let step = update(dataTask) { state -> DataStep in
            guard state.failure == nil else {
                return .drop
            }
            if case .stream(_, let body) = state.completion {
                return .yield(body)
            }
            if let limit, state.data.count + data.count > limit {
                state.data = Data()
                state.failure = .requestFailed(URLError(.dataLengthExceedsMaximum))
                return .cancel
            }
            state.data.append(data)
            guard let report = state.nextReceiveReport(minimumStep: minimumStep) else {
                return .drop
            }
            return .report(report.reporter, completed: report.completed, total: report.total)
        }
        switch step {
            case .yield(let body):
                yield(data, to: body, of: dataTask)
            case .report(let reporter, let completed, let total):
                reporter.report(completed: completed, total: total)
            case .cancel:
                dataTask.cancel()
            case .drop, nil:
                break
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        // URLCache keys by URL alone, so a response to a request carrying any credential header
        // (TM-10, TM-38), set on the request or by the session configuration, could be served to anyone.
        let requestHeaderNames = [dataTask.originalRequest, dataTask.currentRequest].flatMap { request in
            request?.allHTTPHeaderFields.map { Array($0.keys) } ?? []
        }
        let sessionHeaderNames = session.configuration.httpAdditionalHeaders?.keys.compactMap { $0.base as? String } ?? []
        let isAuthenticated = (requestHeaderNames + sessionHeaderNames).contains(where: Redaction.isSensitive)
        completionHandler(isAuthenticated ? nil : proposedResponse)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The session deletes `location` when this method returns, so the file is claimed now.
        let claimed = Result { () throws(HTTPRequestError) in try DownloadDirectory.claim(location) }
        update(downloadTask) { state in
            switch claimed {
                case .success(let fileURL):
                    state.downloadedFileURL = fileURL
                case .failure(let error):
                    state.failure = error
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        extract(downloadTask) { $0.progress }?.report(completed: totalBytesWritten, total: totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        extract(downloadTask) { $0.progress }?.report(completed: fileOffset, total: expectedTotalBytes)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let openContinuation = extract(webSocketTask) { state -> TaskState.WebSocketOpenContinuation? in
            guard case .webSocket(let continuation?) = state.completion else {
                return nil
            }
            state.completion = .webSocket(open: nil)
            return continuation
        }
        openContinuation?.resume(returning: .success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let taskIdentifier = task.taskIdentifier
        guard let state = registry.withLock({ $0.removeValue(forKey: taskIdentifier) }) else {
            return
        }
        complete(task, state: state, error: error)
    }
}

// MARK: - Private Methods

private extension SessionDelegate {
    /// What to do with a data task's response headers.
    enum ResponseStep: Sendable {
        /// Accept them, resuming a stream's waiting caller when there is one.
        case allow(TaskState.StreamResponseContinuation?)
        /// Cancel the task; its recorded failure is reported.
        case cancel
    }

    /// What to do with a received chunk of a data task.
    enum DataStep: Sendable {
        /// Nothing more: buffered, or dropped after a failure.
        case drop
        /// Yield it to a stream's body.
        case yield(AsyncThrowingStream<Data, any Error>.Continuation)
        /// Report the received bytes to the caller's progress handler, outside the lock.
        case report(ProgressReporter, completed: Int64, total: Int64)
        /// Cancel the task; its recorded failure is reported.
        case cancel
    }

    func start(_ task: URLSessionTask, _ state: TaskState) {
        register(task, state)
        task.resume()
    }

    /// Mutates the state of `task` in place under the lock; `nil` when the task is not tracked.
    @discardableResult
    func update<Result: Sendable>(_ task: URLSessionTask, _ body: @Sendable (inout TaskState) -> Result) -> Result? {
        let taskIdentifier = task.taskIdentifier
        return registry.withLock { $0[taskIdentifier]?.apply(body) }
    }

    /// Like ``update(_:_:)`` for a body that returns an optional, flattening the result.
    func extract<Value: Sendable>(_ task: URLSessionTask, _ body: @Sendable (inout TaskState) -> Value?) -> Value? {
        let taskIdentifier = task.taskIdentifier
        return registry.withLock { $0[taskIdentifier]?.apply(body) ?? nil }
    }

    /// Cancels `task` with `URLError.timedOut` once `maximumRequestDuration` passes, unless it
    /// completes first; `nil` when there is no deadline.
    func scheduleDeadline(for task: URLSessionTask) -> Task<Void, Never>? {
        guard let maximumRequestDuration else {
            return nil
        }
        // `Task.sleep` traps on a duration too large for its clock; 68 years is beyond any request.
        let duration = min(maximumRequestDuration, Self.longestDeadline)
        return Task { [weak self] in
            guard (try? await Task.sleep(for: duration)) != nil else {
                return
            }
            self?.expire(task)
        }
    }

    /// Records `URLError.timedOut` as the failure of `task`, then cancels it; nothing when the task
    /// has completed or already failed.
    func expire(_ task: URLSessionTask) {
        let isExpired = update(task) { state -> Bool in
            guard state.failure == nil else {
                return false
            }
            // Recorded first, so it wins over the cancellation that follows.
            state.failure = .requestFailed(URLError(.timedOut))
            return true
        }
        if isExpired == true {
            task.cancel()
        }
    }

    /// Yields `data` to a stream's body, then cancels the task with
    /// `URLError.dataLengthExceedsMaximum` once more than `maximumBufferedStreamBytes` sit unread.
    func yield(_ data: Data, to body: AsyncThrowingStream<Data, any Error>.Continuation, of task: URLSessionTask) {
        guard case .enqueued(let remaining) = body.yield(data) else {
            return
        }
        let limit = maximumBufferedStreamBytes
        let isOverflowing = update(task) { state -> Bool in
            guard state.streamBuffer.record(size: data.count, bufferedCount: .max - remaining) > limit else {
                return false
            }
            state.failure = .requestFailed(URLError(.dataLengthExceedsMaximum))
            return true
        }
        if isOverflowing == true {
            task.cancel()
        }
    }

    /// Answers a client-certificate challenge with the configured identity; `nil` for any other
    /// challenge, or when no identity is configured, so the system keeps handling it.
    ///
    /// With an identity there is no path that answers `.performDefaultHandling`, so the engine never
    /// falls back to an anonymous connection. Server trust has already been decided by the time a
    /// server asks for a certificate.
    func clientCertificateDisposition(
        for challenge: URLAuthenticationChallenge,
        task: URLSessionTask
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
              let clientIdentity
        else {
            return nil
        }
        // A repeated challenge means the server refused the identity once already.
        guard challenge.previousFailureCount == 0 else {
            update(task) { $0.failure = .requestFailed(URLError(.clientCertificateRejected)) }
            return (.cancelAuthenticationChallenge, nil)
        }
        update(task) { $0.didPresentClientIdentity = true }
        return (.useCredential, clientIdentity.credential)
    }

    func trustDisposition(
        for challenge: URLAuthenticationChallenge,
        task: URLSessionTask
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let protectionSpace = challenge.protectionSpace
        guard protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trustEvaluator,
              let trust = protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        do throws(HTTPRequestError) {
            try trustEvaluator.evaluate(trust, forHost: protectionSpace.host)
            return (.useCredential, URLCredential(trust: trust))
        } catch {
            update(task) { $0.failure = error }
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    func complete(_ task: URLSessionTask, state: TaskState, error: (any Error)?) {
        let response = state.response ?? task.response as? HTTPURLResponse
        // A trust or file-system failure explains the cancellation that follows it, so it wins.
        let failure = state.failure
            ?? error.map { state.rejectedClientIdentity(for: $0, hasResponse: response != nil) ?? .transport($0) }

        switch state.completion {
            case .data(let continuation):
                guard let failure else {
                    state.progress?.finish(completed: task.countOfBytesSent)
                    state.receiveProgress?.finish(completed: Int64(state.data.count))
                    let body = state.data
                    continuation.resume(returning: .success(HTTPResponse(request: state.request, response: response, data: body, rawData: body, metrics: state.metrics)))
                    return
                }
                continuation.resume(returning: .failure(failure))

            case .download(let continuation):
                if failure == nil, let fileURL = state.downloadedFileURL {
                    state.progress?.finish(completed: task.countOfBytesReceived)
                    continuation.resume(returning: HTTPDownloadResponse(request: state.request, response: response, fileURL: fileURL, metrics: state.metrics))
                    return
                }
                continuation.resume(returning: HTTPDownloadResponse(
                    request: state.request,
                    response: response,
                    fileURL: nil,
                    resumeData: (error as? URLError)?.downloadTaskResumeData,
                    error: failure ?? .requestFailed(URLError(.cannotWriteToFile)),
                    metrics: state.metrics
                ))

            case .stream(let responseContinuation, let body):
                guard let failure else {
                    responseContinuation?.resume(returning: .success(response))
                    body.finish()
                    return
                }
                responseContinuation?.resume(returning: .failure(failure))
                body.finish(throwing: failure)

            case .webSocket(let openContinuation):
                openContinuation?.resume(returning: .failure(failure ?? .requestFailed(URLError(.networkConnectionLost))))
        }
    }
}

// MARK: - TaskState

/// Everything the delegate tracks for one running task.
struct TaskState: Sendable {

    // MARK: - Types

    typealias DataContinuation = CheckedContinuation<Result<HTTPResponse<Data>, HTTPRequestError>, Never>
    typealias DownloadContinuation = CheckedContinuation<HTTPDownloadResponse<URL>, Never>
    typealias StreamResponseContinuation = CheckedContinuation<Result<HTTPURLResponse?, HTTPRequestError>, Never>
    typealias WebSocketOpenContinuation = CheckedContinuation<Result<Void, HTTPRequestError>, Never>

    /// How the waiting caller is resumed. Optional continuations are cleared once resumed.
    enum Completion: Sendable {
        case data(DataContinuation)
        case download(DownloadContinuation)
        case stream(response: StreamResponseContinuation?, body: AsyncThrowingStream<Data, any Error>.Continuation)
        case webSocket(open: WebSocketOpenContinuation?)
    }

    // MARK: - Properties

    let request: URLRequest
    var completion: Completion
    var progress: ProgressReporter?
    /// Follows the response body of a data task; `progress` follows the bytes an upload sends.
    var receiveProgress: ProgressReporter?
    var bodyStream: (@Sendable () -> InputStream)?
    var response: HTTPURLResponse?
    /// The `Content-Length` the server announced, as received: it may be negative, zero or forged.
    var announcedLength: Int64?
    /// The received count at the last report to `receiveProgress`.
    private var lastReceiveReport: Int64 = 0
    var data = Data()
    /// The unread bytes of a stream's body.
    var streamBuffer = StreamBufferMeter()
    var metrics: URLSessionTaskMetrics?
    /// A failure detected by the delegate that overrides the transport error.
    var failure: HTTPRequestError?
    var downloadedFileURL: URL?
    /// Whether the delegate answered a client-certificate challenge with the configured identity.
    var didPresentClientIdentity = false

    // MARK: - Initialization

    init(
        request: URLRequest,
        completion: Completion,
        progress: ProgressReporter? = nil,
        receiveProgress: ProgressReporter? = nil,
        bodyStream: (@Sendable () -> InputStream)? = nil
    ) {
        self.request = request
        self.completion = completion
        self.progress = progress
        self.receiveProgress = receiveProgress
        self.bodyStream = bodyStream
    }

    // MARK: - Mutation

    /// What to report to `receiveProgress` after a chunk was appended to `data`, or `nil` for nothing.
    ///
    /// Reports only once the received count has advanced by at least `minimumStep` and 1% of the
    /// announced length since the last report, so a server sending tiny chunks cannot flood the
    /// handler. An announced length that is not positive, or that the body has already outgrown,
    /// counts as unknown. Completion is left to ``ProgressReporter/finish(completed:)``, so a
    /// fraction of `1.0` is never reported before the transfer succeeds.
    mutating func nextReceiveReport(minimumStep: Int64) -> (reporter: ProgressReporter, completed: Int64, total: Int64)? {
        guard let reporter = receiveProgress else {
            return nil
        }
        let received = Int64(data.count)
        var total: Int64 = 0
        if let announcedLength, announcedLength > 0, announcedLength >= received {
            guard announcedLength > received else {
                return nil
            }
            total = announcedLength
        }
        guard received - lastReceiveReport >= max(minimumStep, total / 100) else {
            return nil
        }
        lastReceiveReport = received
        return (reporter, received, total)
    }

    /// `URLError.clientCertificateRejected` when `error` is a connection failure that came after the
    /// identity was presented and before any response; `nil` otherwise.
    ///
    /// TLS 1.3 completes the client's handshake before the server judges its certificate, so a
    /// server that rejects the identity usually shows up as a closed connection, not as the alert
    /// that URLSession reports as `clientCertificateRejected`. The original error is kept as the
    /// underlying error.
    func rejectedClientIdentity(for error: any Error, hasResponse: Bool) -> HTTPRequestError? {
        guard didPresentClientIdentity, hasResponse == false, let urlError = error as? URLError else {
            return nil
        }
        switch urlError.code {
            case .clientCertificateRejected, .networkConnectionLost, .secureConnectionFailed:
                return .requestFailed(URLError(.clientCertificateRejected, userInfo: [NSUnderlyingErrorKey: urlError]))
            default:
                return nil
        }
    }

    mutating func apply<Result>(_ body: (inout TaskState) -> Result) -> Result {
        body(&self)
    }
}

// MARK: - StreamBufferMeter

/// Counts the bytes that sit unread in an `AsyncThrowingStream` buffer.
///
/// A stream made with `.bufferingOldest(limit)` reports `.enqueued(remaining:)` on each yield, so
/// `limit - remaining` elements are unread; they are the newest ones. The meter keeps the size of
/// every yielded element and sums the unread ones.
struct StreamBufferMeter: Sendable {

    // MARK: - Constants

    /// The most unread bytes a byte stream or WebSocket buffers by default: 8 MB.
    static let defaultByteLimit = 8 * 1024 * 1024

    /// The most unread messages a WebSocket buffers by default.
    static let defaultMessageLimit = 1_000

    // MARK: - Properties

    private var sizes: [Int] = []
    private var head = 0
    private var bytes = 0

    // MARK: - Recording

    /// Records a yielded element.
    ///
    /// - Parameters:
    ///   - size: The element's size in bytes.
    ///   - bufferedCount: How many elements are unread after the yield.
    /// - Returns: The bytes now unread.
    mutating func record(size: Int, bufferedCount: Int) -> Int {
        sizes.append(size)
        bytes += size
        while sizes.count - head > bufferedCount {
            bytes -= sizes[head]
            head += 1
        }
        if head >= 1_024, head * 2 >= sizes.count {
            sizes.removeFirst(head)
            head = 0
        }
        return bytes
    }
}
