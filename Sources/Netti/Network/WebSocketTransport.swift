//
//  WebSocketTransport.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation

/// A WebSocket message.
public enum WebSocketMessage: Sendable, Equatable {
    /// A UTF-8 text frame.
    case text(String)
    /// A binary frame.
    case data(Data)
}

/// An open WebSocket connection, as returned by ``NetworkService/webSocket(for:)``.
///
/// This is the engine-level transport. Apps use ``WebSocketConnection``, returned by
/// ``Netti/webSocket(_:pingInterval:)``,
/// which adds `Codable` messages, an incoming-message sequence and keep-alive pings on top of it.
public protocol WebSocketTransport: Sendable {
    /// Sends a message.
    ///
    /// - Parameter message: The text or binary message.
    /// - Throws: ``HTTPRequestError/requestFailed(_:)`` when the connection is closed or fails.
    func send(_ message: WebSocketMessage) async throws(HTTPRequestError)

    /// The incoming messages, in arrival order.
    ///
    /// The engine reads continuously from the moment the connection opens, buffering messages
    /// until they are consumed, so control frames such as pongs are processed even while nobody
    /// iterates. The sequence ends when the connection closes normally (close code `1000` or
    /// `1001`) and throws ``HTTPRequestError`` when it closes abnormally or fails.
    ///
    /// Iterate it from one task only.
    var messages: AsyncThrowingStream<WebSocketMessage, any Error> { get }

    /// Sends a ping and waits for the pong.
    ///
    /// - Throws: ``HTTPRequestError/cancelled`` when the calling task is cancelled first, or
    ///   ``HTTPRequestError`` when the connection fails before the pong arrives.
    func sendPing() async throws(HTTPRequestError)

    /// Closes the connection with a close code and an optional reason.
    ///
    /// - Parameters:
    ///   - code: The close code sent to the server.
    ///   - reason: The UTF-8 reason, at most 123 bytes.
    func close(with code: URLSessionWebSocketTask.CloseCode, reason: Data?)
}
