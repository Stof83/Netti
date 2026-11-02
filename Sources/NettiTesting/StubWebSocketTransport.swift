//
//  StubWebSocketTransport.swift
//  NettiTesting
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation
import os

/// An in-memory WebSocket: sent messages are recorded and, when echoing, received back.
///
/// Return one from a ``StubNetworkService`` `webSocket` handler, then drive the server side with
/// ``receive(_:)`` and ``serverClose(throwing:)``.
///
/// ```swift
/// let socket = StubWebSocketTransport(echoes: false)
/// let service = StubNetworkService(webSocket: { _ in socket })
/// socket.receive(.text("hello"))
/// ```
public final class StubWebSocketTransport: WebSocketTransport {

    private struct Recordings {
        var sent: [WebSocketMessage] = []
        var pings = 0
        var closes: [URLSessionWebSocketTask.CloseCode] = []
    }

    /// The incoming messages: those pushed with ``receive(_:)`` and, when echoing, those sent.
    ///
    /// The sequence ends on ``close(with:reason:)`` or ``serverClose(throwing:)``.
    public let messages: AsyncThrowingStream<WebSocketMessage, any Error>

    private let continuation: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation
    private let echoes: Bool
    private let recordings = OSAllocatedUnfairLock(initialState: Recordings())

    /// The messages the client sent, in order.
    public var sent: [WebSocketMessage] {
        recordings.withLock { $0.sent }
    }

    /// How many pings the client sent.
    public var pingCount: Int {
        recordings.withLock { $0.pings }
    }

    /// The close codes the client closed with.
    public var closeCodes: [URLSessionWebSocketTask.CloseCode] {
        recordings.withLock { $0.closes }
    }

    /// Creates an open connection.
    ///
    /// - Parameter echoes: Whether every sent message comes back as a received one. `true` by default.
    public init(echoes: Bool = true) {
        (messages, continuation) = AsyncThrowingStream<WebSocketMessage, any Error>.makeStream()
        self.echoes = echoes
    }

    /// Asynchronously records a message, and echoes it back into ``messages`` when echoing.
    ///
    /// - Parameter message: The message the client sends.
    /// - Throws: Never; the signature matches ``WebSocketTransport/send(_:)``.
    public func send(_ message: WebSocketMessage) async throws(HTTPRequestError) {
        recordings.withLock { $0.sent.append(message) }
        if echoes {
            continuation.yield(message)
        }
    }

    /// Asynchronously records a ping; the pong is immediate.
    ///
    /// - Throws: Never; the signature matches ``WebSocketTransport/sendPing()``.
    public func sendPing() async throws(HTTPRequestError) {
        recordings.withLock { $0.pings += 1 }
    }

    /// Records the close code and ends ``messages`` normally.
    ///
    /// - Parameters:
    ///   - code: The close code, recorded in ``closeCodes``.
    ///   - reason: The close reason. Ignored.
    public func close(with code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        recordings.withLock { $0.closes.append(code) }
        continuation.finish()
    }

    /// Simulates the server pushing a message.
    ///
    /// - Parameter message: The message the client receives next.
    public func receive(_ message: WebSocketMessage) {
        continuation.yield(message)
    }

    /// Simulates the server closing the connection, normally or with a failure.
    ///
    /// - Parameter error: The failure to end the incoming messages with. `nil` ends them normally.
    public func serverClose(throwing error: (any Error)? = nil) {
        continuation.finish(throwing: error)
    }
}
