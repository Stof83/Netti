//
//  WebSocketConnection.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation

/// An open WebSocket connection, returned by ``Netti/webSocket(_:pingInterval:)``.
///
/// ```swift
/// let socket = try await netti.webSocket(ChatAPI.room(id))
/// try await socket.send(ChatMessage(text: "Hi"))
/// for try await message in socket.messages(as: ChatMessage.self) { show(message) }
/// ```
///
/// The connection closes when ``close(_:reason:)`` is called or the connection is released.
public actor WebSocketConnection {

    // MARK: - Properties

    /// The incoming messages, in arrival order.
    ///
    /// The sequence ends when the connection closes normally and throws ``HTTPRequestError`` when
    /// it closes abnormally. Iterate it, or ``messages(as:)``, from one task only.
    public nonisolated let messages: AsyncThrowingStream<WebSocketMessage, any Error>

    private let transport: any WebSocketTransport
    private let jsonManager: JSONManager
    private var keepAlive: Task<Void, Never>?

    // MARK: - Initialization

    /// Wraps an open transport, pinging it every `pingInterval` when one is given.
    init(transport: any WebSocketTransport, jsonManager: JSONManager, pingInterval: Duration?) {
        self.transport = transport
        self.jsonManager = jsonManager
        self.messages = transport.messages
        self.keepAlive = pingInterval.map { interval in
            Task { [transport] in
                while Task.isCancelled == false {
                    do {
                        try await Task.sleep(for: interval)
                        try await transport.sendPing()
                    } catch {
                        return
                    }
                }
            }
        }
    }

    deinit {
        keepAlive?.cancel()
    }

    // MARK: - Sending

    /// Sends a message.
    ///
    /// - Parameter message: The text or binary message.
    /// - Throws: ``HTTPRequestError`` when the connection is closed or fails.
    public func send(_ message: WebSocketMessage) async throws(HTTPRequestError) {
        try await transport.send(message)
    }

    /// Sends a text frame.
    ///
    /// - Parameter text: The frame's text.
    /// - Throws: ``HTTPRequestError`` when the connection is closed or fails.
    public func send(_ text: String) async throws(HTTPRequestError) {
        try await transport.send(.text(text))
    }

    /// Sends a binary frame.
    ///
    /// - Parameter data: The frame's bytes.
    /// - Throws: ``HTTPRequestError`` when the connection is closed or fails.
    public func send(_ data: Data) async throws(HTTPRequestError) {
        try await transport.send(.data(data))
    }

    /// Sends a value encoded as JSON in a text frame.
    ///
    /// - Parameter value: The value, encoded with the client's ``JSONManager``.
    /// - Throws: ``HTTPRequestError/encodingFailed(_:)`` when the value does not encode; otherwise
    ///   as ``send(_:)-(WebSocketMessage)``.
    public func send(_ value: some Encodable & Sendable) async throws(HTTPRequestError) {
        let data: Data
        do {
            data = try jsonManager.encode(value)
        } catch {
            throw .encodingFailed(error)
        }
        try await transport.send(.text(String(decoding: data, as: UTF8.self)))
    }

    // MARK: - Receiving

    /// The incoming messages decoded from JSON, text and binary frames alike.
    ///
    /// - Parameter type: The type of every message.
    /// - Returns: The decoded messages; the sequence throws ``HTTPRequestError/decodingFailed(_:response:)``
    ///   at the first message that does not decode.
    public nonisolated func messages<Message: Decodable & Sendable>(
        as type: Message.Type
    ) -> AsyncThrowingMapSequence<AsyncThrowingStream<WebSocketMessage, any Error>, Message> {
        messages.map { [jsonManager] message in
            let data = switch message {
                case .text(let text): Data(text.utf8)
                case .data(let data): data
            }
            do {
                return try jsonManager.decode(Message.self, from: data)
            } catch {
                throw HTTPRequestError.decodingFailed(error, response: nil)
            }
        }
    }

    // MARK: - Closing

    /// Closes the connection; ``messages`` then ends.
    ///
    /// - Parameters:
    ///   - code: The close code. `normalClosure` by default.
    ///   - reason: A UTF-8 reason of at most 123 bytes. Optional.
    public func close(_ code: URLSessionWebSocketTask.CloseCode = .normalClosure, reason: String? = nil) {
        keepAlive?.cancel()
        keepAlive = nil
        transport.close(with: code, reason: reason.map { Data($0.utf8) })
    }
}
