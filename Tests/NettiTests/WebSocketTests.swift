import Foundation
import Testing

@testable import Netti
import NettiTesting

@Suite("WebSocket connection", .timeLimit(.minutes(1)))
struct WebSocketTests {

    private struct ChatMessage: Codable, Equatable, Sendable {
        let author: String
        let text: String
    }

    @Test("given an echoing connection, when an Encodable is sent, then the echo decodes to an equal value")
    func codableRoundTrip() async throws {
        let transport = StubWebSocketTransport()
        let socket = try await makeNetti(service: StubNetworkService(webSocket: { _ in transport })).webSocket(TestEndpoint())
        let message = ChatMessage(author: "ada", text: "hi")

        try await socket.send(message)
        var messages = socket.messages(as: ChatMessage.self).makeAsyncIterator()

        #expect(try await messages.next() == message)
        guard case .text(let json)? = transport.sent.first else {
            Issue.record("Expected a text frame, got \(transport.sent)")
            return
        }
        #expect(json.contains(#""author":"ada""#))
    }

    @Test("given text and binary frames, when sent, then the transport receives them as such")
    func textAndBinary() async throws {
        let transport = StubWebSocketTransport(echoes: false)
        let socket = try await makeNetti(service: StubNetworkService(webSocket: { _ in transport })).webSocket(TestEndpoint())

        try await socket.send("hello")
        try await socket.send(Data([1, 2]))

        #expect(transport.sent == [.text("hello"), .data(Data([1, 2]))])
    }

    @Test("given a message that does not decode, when read as a type, then decodingFailed is thrown")
    func undecodableMessage() async throws {
        let transport = StubWebSocketTransport(echoes: false)
        let socket = try await makeNetti(service: StubNetworkService(webSocket: { _ in transport })).webSocket(TestEndpoint())
        transport.receive(.text("not json"))

        let error = await #expect(throws: HTTPRequestError.self) {
            for try await _ in socket.messages(as: ChatMessage.self) {}
        }

        guard case .decodingFailed? = error else {
            Issue.record("Expected decodingFailed, got \(String(describing: error))")
            return
        }
    }

    @Test("given the server closes normally, when receiving, then the messages end without an error")
    func serverCloseEnds() async throws {
        let transport = StubWebSocketTransport(echoes: false)
        let socket = try await makeNetti(service: StubNetworkService(webSocket: { _ in transport })).webSocket(TestEndpoint())
        transport.receive(.text("last"))
        transport.serverClose()

        var received: [WebSocketMessage] = []
        for try await message in socket.messages {
            received.append(message)
        }

        #expect(received == [.text("last")])
    }

    @Test("given a close with a code and reason, when closed, then the transport closes and the messages end")
    func clientClose() async throws {
        let transport = StubWebSocketTransport(echoes: false)
        let socket = try await makeNetti(service: StubNetworkService(webSocket: { _ in transport })).webSocket(TestEndpoint())

        await socket.close(.goingAway, reason: "bye")
        for try await _ in socket.messages {}

        #expect(transport.closeCodes == [.goingAway])
    }

    @Test("given a ping interval, when the connection stays open, then pings are sent periodically until closed")
    func keepAlivePings() async throws {
        let transport = StubWebSocketTransport(echoes: false)
        let socket = try await makeNetti(service: StubNetworkService(webSocket: { _ in transport }))
            .webSocket(TestEndpoint(), pingInterval: .milliseconds(10))

        #expect(await eventually { transport.pingCount >= 2 })
        await socket.close()
        let afterClose = transport.pingCount
        try await Task.sleep(for: .milliseconds(50))

        #expect(transport.pingCount <= afterClose + 1)
    }

    @Test("given an https endpoint with headers and an adapter, when opened, then the handshake is wss with both applied")
    func handshakeRequest() async throws {
        let service = StubNetworkService()
        var endpoint = TestEndpoint()
        endpoint.headers = ["X-Room": "42"]
        let adapter = ClosureAdapter { request in
            var request = request
            request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
            return request
        }

        _ = try await makeNetti(service: service, interceptors: [adapter]).webSocket(endpoint)

        let request = try #require(service.webSocketRequests.first)
        #expect(request.url?.absoluteString == "wss://api.test/v1/items")
        #expect(request.value(forHTTPHeaderField: "X-Room") == "42")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test("given a host that fails the pin, when opening, then serverTrustEvaluationFailed is thrown and reported")
    func pinningFailure() async {
        let service = StubNetworkService(webSocket: { request in
            throw HTTPRequestError.serverTrustEvaluationFailed(host: request.url?.host ?? "", reason: "pin mismatch")
        })
        let monitor = RecordingMonitor()

        let error = await expectRequestError { () async throws(HTTPRequestError) -> WebSocketConnection in
            try await makeNetti(service: service, monitors: [monitor]).webSocket(TestEndpoint())
        }

        guard case .serverTrustEvaluationFailed(let host, _)? = error else {
            Issue.record("Expected serverTrustEvaluationFailed, got \(String(describing: error))")
            return
        }
        #expect(host == "api.test")
        #expect(monitor.events.values == ["create", "send", "fail"])
    }

    @Test("given a real WebSocket server, when a Codable message is echoed through Netti, then it decodes to an equal value")
    func loopbackRoundTrip() async throws {
        let server = try await LocalWebSocketServer.start()
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))
        let message = ChatMessage(author: "ada", text: "hello")

        let socket = try await netti.webSocket(URLEndpoint(server.url))
        try await socket.send(message)
        var messages = socket.messages(as: ChatMessage.self).makeAsyncIterator()

        #expect(try await messages.next() == message)
        await socket.close()
    }
}
