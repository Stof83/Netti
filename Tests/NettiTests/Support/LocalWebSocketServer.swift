import Foundation
import Network
import os

/// A WebSocket echo server bound to 127.0.0.1, for engine tests.
///
/// It echoes text and binary messages and answers pings. The text message `close:<code>` makes
/// it close the connection with that close code instead of echoing.
final class LocalWebSocketServer: @unchecked Sendable {

    // MARK: - Constants

    static let closeCommandPrefix = "close:"

    // MARK: - Properties

    private let listener: NWListener
    private let queue = DispatchQueue(label: "netti.tests.websocket-server")
    private let port = OSAllocatedUnfairLock<UInt16>(initialState: 0)

    var url: URL {
        URL(string: "ws://127.0.0.1:\(port.withLock { $0 })/socket") ?? URL(filePath: "/")
    }

    // MARK: - Lifecycle

    private init() throws {
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    static func start() async throws -> LocalWebSocketServer {
        let server = try LocalWebSocketServer()
        try await server.listen()
        return server
    }

    func stop() {
        listener.cancel()
    }
}

// MARK: - Private Methods

private extension LocalWebSocketServer {
    func listen() async throws {
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.echo(on: connection)
        }
        let readyPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                let result: Result<UInt16, any Error>? = switch state {
                    case .ready:
                        .success(listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        .failure(error)
                    default:
                        nil
                }
                guard let result, resumed.withLock({ resumed in defer { resumed = true }; return resumed == false }) else {
                    return
                }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
        port.withLock { $0 = readyPort }
    }

    static func echo(on connection: NWConnection) {
        connection.receiveMessage { content, context, _, error in
            guard error == nil,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            else {
                connection.cancel()
                return
            }
            switch metadata.opcode {
                case .text:
                    let text = String(decoding: content ?? Data(), as: UTF8.self)
                    if text.hasPrefix(closeCommandPrefix), let rawCode = UInt16(text.dropFirst(closeCommandPrefix.count)) {
                        close(connection, code: rawCode)
                        return
                    }
                    send(content, opcode: .text, on: connection)
                case .binary:
                    send(content, opcode: .binary, on: connection)
                case .close:
                    connection.cancel()
                    return
                default:
                    break
            }
            echo(on: connection)
        }
    }

    static func send(_ content: Data?, opcode: NWProtocolWebSocket.Opcode, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "echo", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: content, contentContext: context, isComplete: true, completion: .idempotent)
    }

    static func close(_ connection: NWConnection, code rawCode: UInt16) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = NWProtocolWebSocket.CloseCode.Defined(rawValue: rawCode).map { .protocolCode($0) } ?? .applicationCode(rawCode)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
