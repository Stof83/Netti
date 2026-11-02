import Foundation
import Network
import os

/// A minimal HTTP/1.1 server bound to 127.0.0.1, for engine tests: real sockets, no external network.
///
/// Every connection serves one request and is closed (`Connection: close`). Requests are recorded,
/// and so are clients that disconnect while a streamed or stalled body is still being sent.
final class LocalHTTPServer: @unchecked Sendable {

    // MARK: - Types

    struct Request: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data

        var path: String {
            String(target.prefix { $0 != "?" })
        }

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
    }

    struct Response: Sendable {
        enum Body: Sendable {
            /// A body with `Content-Length`.
            case data(Data)
            /// A chunked body; each chunk is sent once its `before` closure returns.
            case chunks([Chunk])
            /// Declares `contentLength`, sends `prefix`, then waits until the client disconnects.
            case stall(prefix: Data, contentLength: Int)
            /// Chaos: runs `steps` on the raw socket, then closes it. `status` and `headers` are
            /// ignored; the steps write every byte, head included.
            case script([Step])
        }

        /// One step of a ``Body/script(_:)``; the script stops early once the client disconnects.
        enum Step: Sendable {
            /// Sends the bytes as they are.
            case send(Data)
            /// Sends the bytes `count` at a time, pausing `interval` after each slice.
            case drip(Data, count: Int, interval: Duration)
            /// Waits, or stops waiting once the client disconnects.
            case pause(Duration)
            /// Waits until the client disconnects, for at most 30 seconds.
            case waitForDisconnect
            /// Waits until `condition` holds or the client disconnects, for at most 30 seconds. Use it
            /// to hold a close until the client has observed what was sent, instead of a fixed delay.
            case waitUntil(@Sendable () -> Bool)
            /// Tears the connection down at once, without a graceful close, and ends the script.
            case reset
        }

        struct Chunk: Sendable {
            let data: Data
            let before: @Sendable () async -> Void

            init(_ text: String, before: @escaping @Sendable () async -> Void = {}) {
                self.data = Data(text.utf8)
                self.before = before
            }
        }

        var status = 200
        var headers: [String: String] = [:]
        var body = Body.data(Data())

        static func text(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers, body: .data(Data(text.utf8)))
        }

        /// A chunked body with no last chunk: sends `chunks` at once, then holds the connection until
        /// the client goes away, which is recorded as a disconnect. The server never finishes the body,
        /// so only the client can end the transfer, however late it reads.
        static func unterminatedChunks(_ chunks: [String]) -> Response {
            let head = LocalHTTPServer.head(200, ["Transfer-Encoding": "chunked", "Connection": "close"])
            let framing = chunks.map { "\(String($0.utf8.count, radix: 16))\r\n\($0)\r\n" }.joined()
            return Response(body: .script([.send(head + Data(framing.utf8)), .waitForDisconnect]))
        }
    }

    typealias Handler = @Sendable (Request) async -> Response

    private struct Log {
        var requests: [Request] = []
        var disconnects = 0
    }

    private enum ServerError: Error {
        case malformedRequest
        case closedEarly
    }

    // MARK: - Properties

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "netti.tests.http-server")
    private let port = OSAllocatedUnfairLock<UInt16>(initialState: 0)
    private let log = OSAllocatedUnfairLock(initialState: Log())

    var baseURL: URL {
        url("")
    }

    var requests: [Request] {
        log.withLock { $0.requests }
    }

    /// Clients that went away before a streamed or stalled body finished.
    var disconnects: Int {
        log.withLock { $0.disconnects }
    }

    // MARK: - Lifecycle

    private init(handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
        self.handler = handler
    }

    static func start(handler: @escaping Handler) async throws -> LocalHTTPServer {
        let server = try LocalHTTPServer(handler: handler)
        try await server.listen()
        return server
    }

    func stop() {
        listener.cancel()
    }

    func url(_ pathAndQuery: String) -> URL {
        URL(string: "http://127.0.0.1:\(port.withLock { $0 })\(pathAndQuery)") ?? URL(filePath: "/")
    }

    /// Polls until `condition` holds or `timeout` elapses.
    ///
    /// The bound is generous because it only matters on failure: under a loaded parallel run the
    /// client can take seconds to act on what the server already sent.
    func wait(timeout: Duration = .seconds(30), until condition: (LocalHTTPServer) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(self) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(self)
    }
}

// MARK: - Private Methods

private extension LocalHTTPServer {
    func listen() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
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

    func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task {
            defer { connection.cancel() }
            guard let request = try? await Self.readRequest(from: connection) else {
                return
            }
            log.withLock { $0.requests.append(request) }
            let response = await handler(request)
            try? await write(response, to: connection)
        }
    }

    func write(_ response: Response, to connection: NWConnection) async throws {
        var headers = response.headers
        headers["Connection"] = "close"

        switch response.body {
            case .data(let body):
                headers["Content-Length"] = "\(body.count)"
                try await Self.send(Self.head(response.status, headers) + body, on: connection)

            case .chunks(let chunks):
                headers["Transfer-Encoding"] = "chunked"
                try await Self.send(Self.head(response.status, headers), on: connection)
                let disconnected = watchDisconnect(of: connection)
                for chunk in chunks {
                    await chunk.before()
                    if disconnected.withLock({ $0.disconnected }) {
                        return
                    }
                    try await Self.send(Data(String(chunk.data.count, radix: 16).utf8) + Self.crlf + chunk.data + Self.crlf, on: connection)
                }
                disconnected.withLock { $0.finished = true }
                try await Self.send(Data("0\r\n\r\n".utf8), on: connection)

            case .stall(let prefix, let contentLength):
                headers["Content-Length"] = "\(contentLength)"
                try await Self.send(Self.head(response.status, headers) + prefix, on: connection)
                while (try? await Self.receive(from: connection)) != nil {}
                log.withLock { $0.disconnects += 1 }

            case .script(let steps):
                try await run(steps, on: connection)
        }
    }

    /// Runs chaos `steps`; a disconnect before the last step is recorded like any other.
    func run(_ steps: [Response.Step], on connection: NWConnection) async throws {
        let state = watchDisconnect(of: connection)
        let isDisconnected = { state.withLock { $0.disconnected } }
        defer { state.withLock { $0.finished = true } }
        for step in steps {
            guard isDisconnected() == false else {
                return
            }
            switch step {
                case .send(let data):
                    try await Self.send(data, on: connection)

                case .drip(let data, let count, let interval):
                    var offset = data.startIndex
                    while offset < data.endIndex, isDisconnected() == false {
                        let end = min(offset + max(1, count), data.endIndex)
                        try await Self.send(data[offset..<end], on: connection)
                        offset = end
                        await Self.pause(interval, until: isDisconnected)
                    }

                case .pause(let duration):
                    await Self.pause(duration, until: isDisconnected)

                case .waitForDisconnect:
                    await Self.pause(.seconds(30), until: isDisconnected)

                case .waitUntil(let condition):
                    await Self.pause(.seconds(30)) { isDisconnected() || condition() }

                case .reset:
                    state.withLock { $0.finished = true }
                    connection.forceCancel()
                    return
            }
        }
    }

    /// Sleeps for `duration` in short slices, returning early once `condition` holds.
    static func pause(_ duration: Duration, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline, condition() == false {
            try? await Task.sleep(for: min(.milliseconds(5), deadline - ContinuousClock.now))
        }
    }

    /// Records a disconnect if the client goes away before the body is `finished`.
    func watchDisconnect(of connection: NWConnection) -> OSAllocatedUnfairLock<(disconnected: Bool, finished: Bool)> {
        let state = OSAllocatedUnfairLock(initialState: (disconnected: false, finished: false))
        Task {
            while (try? await Self.receive(from: connection)) != nil {}
            let isEarly = state.withLock { state in
                state.disconnected = true
                return state.finished == false
            }
            if isEarly {
                log.withLock { $0.disconnects += 1 }
            }
        }
        return state
    }

    static let crlf = Data("\r\n".utf8)

    static func head(_ status: Int, _ headers: [String: String]) -> Data {
        let lines = ["HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))"]
            + headers.map { "\($0.key): \($0.value)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func readRequest(from connection: NWConnection) async throws -> Request {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let headerEnd = buffer.range(of: separator) {
                var lines = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let requestLine = lines.removeFirst().split(separator: " ")
                guard requestLine.count >= 2 else {
                    throw ServerError.malformedRequest
                }
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else {
                        continue
                    }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                if let body = decodeBody(Data(buffer[headerEnd.upperBound...]), headers: headers) {
                    return Request(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body)
                }
            }
            guard let received = try await receive(from: connection) else {
                throw ServerError.closedEarly
            }
            buffer.append(received)
        }
    }

    /// The complete body, or `nil` while more bytes are needed.
    static func decodeBody(_ data: Data, headers: [String: String]) -> Data? {
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            return decodeChunked(data)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        return data.count >= length ? data.prefix(length) : nil
    }

    static func decodeChunked(_ data: Data) -> Data? {
        var body = Data()
        var index = data.startIndex
        while let lineEnd = data.range(of: crlf, in: index..<data.endIndex) {
            let sizeField = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeField, radix: 16) else {
                return nil
            }
            if size == 0 {
                return body
            }
            let chunkEnd = lineEnd.upperBound + size
            guard data.endIndex >= chunkEnd + crlf.count else {
                return nil
            }
            body.append(data[lineEnd.upperBound..<chunkEnd])
            index = chunkEnd + crlf.count
        }
        return nil
    }

    /// The next bytes, or `nil` once the client has closed its side.
    static func receive(from connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, content.isEmpty == false {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
