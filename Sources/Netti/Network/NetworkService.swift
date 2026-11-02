//
//  NetworkService.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation

/// A transport engine: it executes fully built `URLRequest`s and nothing else.
///
/// Encoding, adapting, validation, retry, caching and decoding all happen in ``Netti`` before and
/// after the engine runs, so every engine gets them for free. An engine only moves bytes, reports
/// progress, collects metrics and enforces its ``ServerTrustPolicy``.
///
/// Netti ships two engines:
/// - ``URLSessionNetworkService``, the default, built on `URLSession`.
/// - ``AFNetworkService``, deprecated, built on Alamofire and kept only to prove parity.
///
/// Both pass the same contract suite, so swapping one for the other never changes behavior.
///
/// Contract shared by every method:
/// - Non-2xx responses are *returned*, never thrown. Status validation is the caller's decision.
/// - Failures throw ``HTTPRequestError``: ``HTTPRequestError/requestFailed(_:)`` for transport
///   errors, ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)`` when the trust policy
///   rejects the host, ``HTTPRequestError/cancelled`` when the calling task is cancelled.
/// - Cancelling the calling task cancels the underlying transfer.
/// - Progress handlers are called on a background queue, in order, with increasing values, and
///   at least once with a fraction of `1.0` when the transfer succeeds.
///
/// ```swift
/// let service = URLSessionNetworkService()
/// let response = try await service.data(for: URLRequest(url: url))
/// ```
public protocol NetworkService: Sendable {
    /// Sends `request` and returns the whole response body.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: The response; `rawData` and `data` hold the body, empty when there is none.
    /// - Throws: ``HTTPRequestError`` when no response is received.
    func data(for request: URLRequest) async throws(HTTPRequestError) -> HTTPResponse<Data>

    /// Uploads `source` as the body of `request` and returns the server's response.
    ///
    /// - Parameters:
    ///   - request: The request to send. Its `httpBody` is ignored.
    ///   - source: The body: in-memory data, a file, or a stream.
    ///   - progress: Called as the body is sent. Optional.
    /// - Returns: The response, as for ``data(for:)``.
    /// - Throws: ``HTTPRequestError/fileSystem(_:)`` before any network traffic when a file
    ///   source cannot be read; otherwise as for ``data(for:)``.
    func upload(
        for request: URLRequest,
        from source: UploadSource,
        progress: ProgressHandler?
    ) async throws(HTTPRequestError) -> HTTPResponse<Data>

    /// Downloads the response body of `request` to a temporary file.
    ///
    /// The download never throws: a failure is reported in the returned response's `error`, next
    /// to the `resumeData` that continues it when the server supports resumption. This keeps the
    /// resume data of a cancelled or failed transfer available to the caller.
    ///
    /// - Parameters:
    ///   - request: The request to send. Ignored when `resumeData` is given.
    ///   - resumeData: Data from a previous ``HTTPDownloadResponse/resumeData`` to continue from.
    ///   - progress: Called as the body is received. Optional.
    /// - Returns: On success, a response whose `fileURL` is a new file in the temporary directory
    ///   that the caller moves or deletes. On failure, `fileURL` is `nil` and `error` holds the
    ///   ``HTTPRequestError``.
    func download(
        for request: URLRequest,
        resumeData: Data?,
        progress: ProgressHandler?
    ) async -> HTTPDownloadResponse<URL>

    /// Sends `request` and returns as soon as the response headers arrive, streaming the body.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: The response, whose ``HTTPStreamResponse/body`` yields chunks as they arrive.
    ///   Ending the iteration early cancels the transfer.
    /// - Throws: ``HTTPRequestError`` when no response headers are received.
    func bytes(for request: URLRequest) async throws(HTTPRequestError) -> HTTPStreamResponse

    /// Opens a WebSocket connection, returning once the handshake succeeds.
    ///
    /// - Parameter request: The `ws` or `wss` request, with any headers to send in the handshake.
    /// - Returns: The open connection.
    /// - Throws: ``HTTPRequestError`` when the handshake fails, including
    ///   ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)`` when pinning rejects the host.
    func webSocket(for request: URLRequest) async throws(HTTPRequestError) -> any WebSocketTransport
}
