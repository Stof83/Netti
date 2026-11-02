import Foundation
import Testing

@testable import Netti

@Suite("RedirectHandler")
struct RedirectHandlerTests {
    private let proposed: URLRequest = {
        var request = URLRequest(url: URL(string: "https://api.test/final")!)
        request.setValue("Bearer abc", forHTTPHeaderField: "Authorization")
        return request
    }()

    private let redirect = HTTPURLResponse(
        url: URL(string: "https://api.test/start")!,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": "https://api.test/final"]
    )!

    /// The current request the engine passes: the one that was redirected.
    private var current: URLRequest {
        var request = URLRequest(url: URL(string: "https://api.test/start")!)
        request.setValue("Bearer abc", forHTTPHeaderField: "Authorization")
        return request
    }

    private func outcome(_ handler: RedirectHandler) -> RedirectHandler.Outcome {
        handler.outcome(for: proposed, response: redirect, current: current, hasBody: false)
    }

    @Test("given .follow, when redirected, then the proposed request is sent")
    func follow_sendsProposedRequest() {
        #expect(outcome(.follow) == .send(proposed))
    }

    @Test("given .doNotFollow, when redirected, then no request is sent")
    func doNotFollow_stops() {
        #expect(outcome(.doNotFollow) == .stop)
    }

    @Test("given a handler that modifies, when redirected, then the modified request is sent")
    func modify_sendsModifiedRequest() {
        let handler = RedirectHandler { proposed, _ in
            var request = proposed
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            return .modify(request)
        }

        guard case .send(let request) = outcome(handler) else {
            Issue.record("Expected the modified request to be sent")
            return
        }

        #expect(request.url == proposed.url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("given a handler, when redirected, then it sees the redirect response")
    func handler_receivesResponse() {
        let status = Recorder<Int>()
        let handler = RedirectHandler { _, response in
            status.append(response.statusCode)
            return .follow
        }

        _ = outcome(handler)

        #expect(status.values == [302])
    }

    @Test("given the public engine initializer, when no handler is given, then redirects are followed")
    func engine_default_follows() async throws {
        let server = try await SessionDelegateTests.redirectingServer()
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral)

        let response = try await service.data(for: URLRequest(url: server.url("/start")))

        #expect(response.rawData == Data("final".utf8))
    }

    @Test("given .doNotFollow on the engine, when the server redirects, then the redirect response is returned")
    func engine_doNotFollow_returnsRedirect() async throws {
        let server = try await SessionDelegateTests.redirectingServer()
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, redirectHandler: .doNotFollow)

        let response = try await service.data(for: URLRequest(url: server.url("/start")))

        #expect(response.statusCode == 302)
        #expect(server.requests.map(\.path) == ["/start"])
    }

    @Test("given a modifying handler on the engine, when the server redirects, then the modified request is sent")
    func engine_modify_sendsModifiedRequest() async throws {
        let server = try await SessionDelegateTests.redirectingServer()
        defer { server.stop() }
        let elsewhere = server.url("/elsewhere")
        let service = URLSessionNetworkService(configuration: .ephemeral, redirectHandler: RedirectHandler { proposed, _ in
            var request = proposed
            request.url = elsewhere
            return .modify(request)
        })

        let response = try await service.data(for: URLRequest(url: server.url("/start")))

        #expect(response.rawData == Data("elsewhere".utf8))
        #expect(server.requests.map(\.path) == ["/start", "/elsewhere"])
    }
}
