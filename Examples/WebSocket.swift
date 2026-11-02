//
//  WebSocket.swift
//  Netti
//

import Foundation
import NettiTesting

/// Opening a WebSocket, sending text and JSON, and reading typed messages until the server closes.
///
/// Runs offline: a `StubWebSocketTransport` is the server side of the connection.
func webSocketExample() async throws {
    struct ChatMessage: Codable, Sendable, Equatable {
        let text: String
    }

    let socket = StubWebSocketTransport(echoes: false)
    let netti = Netti(service: StubNetworkService(webSocket: { _ in socket }))
    netti.isLoggingEnabled = false

    let connection = try await netti.webSocket(ChatAPI.room(7), pingInterval: .seconds(30))

    // MARK: - Send

    try await connection.send("hello") // a text frame
    try await connection.send(ChatMessage(text: "Hi")) // JSON in a text frame
    report("sent     -> \(socket.sent.map(describe))")
    try expect(socket.sent.count == 2, "expected 2 sent frames")

    // MARK: - Receive

    // The server side: push two messages, then close normally.
    socket.receive(.text(#"{"text": "welcome"}"#))
    socket.receive(.data(Data(#"{"text": "binary frames decode too"}"#.utf8)))
    socket.serverClose()

    var received: [ChatMessage] = []
    for try await message in connection.messages(as: ChatMessage.self) {
        received.append(message)
    }
    report("received -> \(received.map(\.text))")
    try expect(received.count == 2, "expected 2 messages")

    // MARK: - Close

    // Netti does not reconnect a dropped socket: catch the error from the loop and reopen.
    await connection.close(.normalClosure, reason: "done")
    report("closed   -> close codes sent: \(socket.closeCodes.count)")
}

// MARK: - Helpers

private func describe(_ message: WebSocketMessage) -> String {
    switch message {
        case .text(let text): "text \(text)"
        case .data(let data): "binary \(data.count) bytes"
    }
}

private enum ChatAPI: HTTPRequest {
    case room(Int)

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String {
        switch self {
            case .room(let id): "rooms/\(id)"
        }
    }
    var headers: HTTPHeaders { [] }
}
