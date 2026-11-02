//
//  Netti+Streaming.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation

/// Streamed responses and WebSockets.
///
/// ```swift
/// for try await event in try await netti.stream(FeedAPI.live).serverSentEvents { … }
/// let socket = try await netti.webSocket(ChatAPI.room(id))
/// ```
extension Netti {

    // MARK: - Streaming

    /// Sends a `GET` request and returns as soon as the response headers arrive, streaming the body.
    ///
    /// Read the body as ``HTTPStreamResponse/body`` chunks, ``HTTPStreamResponse/lines`` or
    /// ``HTTPStreamResponse/serverSentEvents``. Interceptors, retry and status validation apply
    /// before the body starts; cancelling the consuming task cancels the transfer.
    ///
    /// ```swift
    /// let response = try await netti.stream(FeedAPI.live)
    /// for try await event in response.serverSentEvents {
    ///     handle(event.data)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - query: Encoded into the URL query. Optional.
    /// - Returns: The response, with its body still arriving.
    /// - Throws: ``HTTPRequestError`` when no response headers are received or validation rejects them.
    public func stream(
        _ endpoint: some HTTPRequest,
        query: (some Encodable & Sendable)? = Empty?.none
    ) async throws(HTTPRequestError) -> HTTPStreamResponse {
        let snapshot = self.snapshot
        let urlRequest = try buildRequest(endpoint, parameters: query, method: .get, jsonManager: snapshot.jsonManager)
        return try await stream(urlRequest, validation: endpoint.validation, retryPolicy: endpoint.retryPolicy, pipeline: snapshot.pipeline)
    }

    /// Sends a prebuilt request and streams its body; use it for streams that need another method.
    ///
    /// Interceptors and the client's validation and retry policy apply; there is no endpoint, so
    /// no endpoint-level override does.
    ///
    /// ```swift
    /// var request = URLRequest(url: completionsURL)
    /// request.httpMethod = "POST"
    /// for try await line in try await netti.stream(request).lines {
    ///     transcript.append(line)
    /// }
    /// ```
    ///
    /// - Parameter urlRequest: The request to send.
    /// - Returns: The response, with its body still arriving.
    /// - Throws: ``HTTPRequestError``.
    public func stream(_ urlRequest: URLRequest) async throws(HTTPRequestError) -> HTTPStreamResponse {
        try await stream(urlRequest, validation: nil, retryPolicy: nil, pipeline: snapshot.pipeline)
    }

    // MARK: - WebSocket

    /// Opens a WebSocket connection to an endpoint.
    ///
    /// The endpoint's headers, the client's interceptors and the engine's trust policy apply to the
    /// handshake. An `http` or `https` URL is opened as `ws` or `wss`.
    ///
    /// ```swift
    /// let socket = try await netti.webSocket(ChatAPI.room(id), pingInterval: .seconds(30))
    /// try await socket.send("hello")
    /// for try await message in socket.messages {
    ///     handle(message)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - pingInterval: Sends a keep-alive ping at this interval. `nil`, the default, sends none.
    /// - Returns: The open connection.
    /// - Throws: ``HTTPRequestError`` when the handshake fails, including
    ///   ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)`` when pinning rejects the host.
    public func webSocket(
        _ endpoint: some HTTPRequest,
        pingInterval: Duration? = nil
    ) async throws(HTTPRequestError) -> WebSocketConnection {
        var urlRequest = try endpoint.asURLRequest(for: .get)
        urlRequest.url = urlRequest.url.map(Self.webSocketURL)
        let snapshot = self.snapshot
        let transport = try await snapshot.pipeline.webSocket(urlRequest)
        return WebSocketConnection(transport: transport, jsonManager: snapshot.jsonManager, pingInterval: pingInterval)
    }
}

// MARK: - HTTPStreamResponse

extension HTTPStreamResponse {
    /// The body as text lines, split on LF and CRLF. Iterate one view of the body only.
    public var lines: AsyncLineSequence<AsyncThrowingStream<Data, any Error>> {
        AsyncLineSequence(body)
    }

    /// The body parsed as `text/event-stream` events. Iterate one view of the body only.
    public var serverSentEvents: ServerSentEventSequence<AsyncLineSequence<AsyncThrowingStream<Data, any Error>>> {
        ServerSentEventSequence(lines)
    }
}

// MARK: - Private Helpers

private extension Netti {
    func stream(
        _ urlRequest: URLRequest,
        validation: ResponseValidation?,
        retryPolicy: RetryPolicy?,
        pipeline: RequestPipeline
    ) async throws(HTTPRequestError) -> HTTPStreamResponse {
        let service = pipeline.service
        return try await pipeline.run(urlRequest, validation: validation, retryPolicy: retryPolicy) { sent throws(HTTPRequestError) in
            let stream = try await service.bytes(for: sent)
            let response = HTTPResponse<Data>(request: stream.request, response: stream.response, data: nil, rawData: nil)
            return RequestPipeline.Attempt(output: stream, response: response)
        }
    }

    static func webSocketURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        switch components.scheme?.lowercased() {
            case "http": components.scheme = "ws"
            case "https": components.scheme = "wss"
            default: break
        }
        return components.url ?? url
    }
}
