import Foundation
import Testing

@testable import Netti

/// TM-03/04/05: the engine's default redirect behaviour. Two loopback servers on different ports
/// are two origins.
@Suite("Redirect security", .timeLimit(.minutes(1)))
struct RedirectSecurityTests {

    private static let credentialHeaders = ["Authorization", "Proxy-Authorization", "Cookie"]

    // MARK: - Native Behaviour

    /// Observed on macOS 26: URLSession drops `Authorization` and `Proxy-Authorization` from every
    /// proposed redirect, same origin included, but forwards a `Cookie` header set on the request,
    /// and every other header, to any origin.
    @Test("given .follow, when redirected across origins, then URLSession drops Authorization but forwards Cookie")
    func follow_crossOrigin_nativeBehaviour() async throws {
        let (origin, target) = try await Self.servers(status: 302)
        defer { origin.stop(); target.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, redirectHandler: .follow)

        let response = try await service.data(for: Self.authenticated(origin.url("/start")))

        #expect(response.rawData == Data("target".utf8))
        let forwarded = try #require(target.requests.first)
        #expect(forwarded.header("Authorization") == nil)
        #expect(forwarded.header("Proxy-Authorization") == nil)
        #expect(forwarded.header("Cookie") == "session=secret")
        #expect(forwarded.header("X-Trace") == "trace-1")
    }

    // MARK: - Secure Default

    @Test("given no handler, when redirected across origins, then credential headers are stripped and the rest kept")
    func default_crossOrigin_stripsCredentials() async throws {
        let (origin, target) = try await Self.servers(status: 302)
        defer { origin.stop(); target.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral)

        let response = try await service.data(for: Self.authenticated(origin.url("/start")))

        #expect(response.rawData == Data("target".utf8))
        let forwarded = try #require(target.requests.first)
        for name in Self.credentialHeaders {
            #expect(forwarded.header(name) == nil, "\(name) leaked across origins")
        }
        #expect(forwarded.header("X-Trace") == "trace-1")
    }

    @Test("given no handler, when redirected on the same origin, then Authorization is kept")
    func default_sameOrigin_keepsCredentials() async throws {
        let server = try await SessionDelegateTests.redirectingServer()
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral)

        _ = try await service.data(for: Self.authenticated(server.url("/start")))

        #expect(server.requests.map(\.path) == ["/start", "/final"])
        #expect(server.requests.last?.header("Authorization") == "Bearer secret")
    }

    @Test("given no handler, when a POST with a body gets a cross-origin 307, then the redirect is returned and the body never reaches the target", arguments: [307, 308])
    func default_crossOrigin307WithBody_notFollowed(status: Int) async throws {
        let (origin, target) = try await Self.servers(status: status)
        defer { origin.stop(); target.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral)
        var request = URLRequest(url: origin.url("/start"))
        request.httpMethod = "POST"
        request.httpBody = Data("password=secret".utf8)

        let response = try await service.data(for: request)

        #expect(response.statusCode == status)
        #expect(target.requests.isEmpty)
    }

    @Test("given no handler, when an upload gets a cross-origin 307, then the redirect is returned and the body never reaches the target")
    func default_crossOrigin307Upload_notFollowed() async throws {
        let (origin, target) = try await Self.servers(status: 307)
        defer { origin.stop(); target.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral)
        var request = URLRequest(url: origin.url("/start"))
        request.httpMethod = "PUT"

        let response = try await service.upload(for: request, from: .data(Data("secret".utf8)), progress: nil)

        #expect(response.statusCode == 307)
        #expect(target.requests.isEmpty)
    }

    @Test("given no handler, when a POST with a body gets a same-origin 307, then it is followed with its body")
    func default_sameOrigin307WithBody_followed() async throws {
        let server = try await LocalHTTPServer.start { request in
            guard request.path == "/start" else {
                return .text(String(decoding: request.body, as: UTF8.self))
            }
            return LocalHTTPServer.Response(status: 307, headers: ["Location": "/final"])
        }
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral)
        var request = URLRequest(url: server.url("/start"))
        request.httpMethod = "POST"
        request.httpBody = Data("payload".utf8)

        let response = try await service.data(for: request)

        #expect(response.rawData == Data("payload".utf8))
        #expect(server.requests.map(\.method) == ["POST", "POST"])
    }

    @Test("given a handler that fails the redirect, when redirected, then the call throws that error and the target is never contacted")
    func failingRedirect_throws() async throws {
        let (origin, target) = try await Self.servers(status: 302)
        defer { origin.stop(); target.stop() }
        let handler = RedirectHandler { _ in .fail(URLError(.appTransportSecurityRequiresSecureConnection)) }
        let service = URLSessionNetworkService(configuration: .ephemeral, redirectHandler: handler)

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await service.data(for: URLRequest(url: origin.url("/start")))
        }

        #expect(error?.urlErrorCode == .appTransportSecurityRequiresSecureConnection)
        #expect(target.requests.isEmpty)
    }

    @Test("given a handler that fails the redirect, when streaming, then the stream call throws that error")
    func failingRedirect_stream_throws() async throws {
        let (origin, target) = try await Self.servers(status: 302)
        defer { origin.stop(); target.stop() }
        let handler = RedirectHandler { _ in .fail(URLError(.appTransportSecurityRequiresSecureConnection)) }
        let service = URLSessionNetworkService(configuration: .ephemeral, redirectHandler: handler)

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await service.bytes(for: URLRequest(url: origin.url("/start")))
        }

        #expect(error?.urlErrorCode == .appTransportSecurityRequiresSecureConnection)
        #expect(target.requests.isEmpty)
    }

    // MARK: - Decision

    @Test("given .secure, when https redirects to http, then the call fails with appTransportSecurityRequiresSecureConnection")
    func secure_downgrade_fails() {
        let outcome = Self.secureOutcome(from: "https://api.test/start", to: "http://api.test/final")

        #expect(outcome == .fail(URLError(.appTransportSecurityRequiresSecureConnection)))
    }

    @Test(
        "given .secure, when the scheme, host or port changes, then credential headers are stripped",
        arguments: [
            ("https://api.test/start", "https://evil.test/final"),
            ("http://api.test/start", "https://api.test/final"),
            ("https://api.test/start", "https://api.test:8443/final"),
            ("https://api.test/start", "https://sub.api.test/final"),
        ]
    )
    func secure_crossOrigin_strips(from: String, to: String) throws {
        let outcome = Self.secureOutcome(from: from, to: to)

        guard case .send(let request) = outcome else {
            Issue.record("Expected the redirect to be followed, got \(outcome)")
            return
        }
        for name in Self.credentialHeaders {
            #expect(request.value(forHTTPHeaderField: name) == nil)
        }
        #expect(request.value(forHTTPHeaderField: "X-Trace") == "trace-1")
    }

    @Test(
        "given .secure, when the origin is the same, then the proposed request is sent unchanged",
        arguments: [
            ("https://api.test/start", "https://api.test/final"),
            ("https://API.test/start", "https://api.test:443/final"),
            ("http://api.test:80/start", "http://api.test/final"),
        ]
    )
    func secure_sameOrigin_unchanged(from: String, to: String) throws {
        let proposed = Self.authenticated(try #require(URL(string: to)))

        #expect(Self.secureOutcome(from: from, to: to) == .send(proposed))
    }

    @Test("given .secure, when URLSession dropped the credentials of a same-origin redirect, then they are restored from the current request")
    func secure_sameOrigin_restoresCredentials() throws {
        let url = try #require(URL(string: "https://api.test/final"))
        let current = Self.authenticated(try #require(URL(string: "https://api.test/start")))
        var proposed = URLRequest(url: url)
        proposed.setValue("trace-1", forHTTPHeaderField: "X-Trace")

        let outcome = RedirectHandler.secure.outcome(
            for: proposed,
            response: Self.redirect(from: "https://api.test/start", to: "https://api.test/final", status: 302),
            current: current,
            hasBody: false
        )

        guard case .send(let request) = outcome else {
            Issue.record("Expected the redirect to be followed, got \(outcome)")
            return
        }
        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Proxy-Authorization") == "Basic proxy-secret")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session=secret")
    }

    @Test("given .secure, when a cross-origin 307 or 308 carries a body, then it is not followed", arguments: [307, 308])
    func secure_crossOriginBody_stops(status: Int) {
        let outcome = Self.secureOutcome(from: "https://api.test/start", to: "https://evil.test/final", status: status, hasBody: true)

        #expect(outcome == .stop)
    }

    @Test("given .secure, when a cross-origin 302 or 303 follows a POST, then it is followed without credentials", arguments: [302, 303])
    func secure_crossOriginNonPreserving_followed(status: Int) {
        let outcome = Self.secureOutcome(from: "https://api.test/start", to: "https://evil.test/final", status: status, hasBody: true)

        guard case .send(let request) = outcome else {
            Issue.record("Expected the redirect to be followed, got \(outcome)")
            return
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("given .follow, when https redirects to http across origins, then the proposed request is sent unchanged")
    func follow_keepsEverything() throws {
        let proposed = Self.authenticated(try #require(URL(string: "http://evil.test/final")))
        let response = Self.redirect(from: "https://api.test/start", to: "http://evil.test/final", status: 307)

        #expect(RedirectHandler.follow.outcome(for: proposed, response: response, current: nil, hasBody: true) == .send(proposed))
    }
}

// MARK: - Helpers

private extension RedirectSecurityTests {
    /// An origin server whose `/start` answers `status` with a `Location` on a second server, the target.
    static func servers(status: Int) async throws -> (origin: LocalHTTPServer, target: LocalHTTPServer) {
        let target = try await LocalHTTPServer.start { _ in .text("target") }
        let location = target.url("/final").absoluteString
        let origin = try await LocalHTTPServer.start { request in
            guard request.path == "/start" else {
                return .text("origin")
            }
            return LocalHTTPServer.Response(status: status, headers: ["Location": location])
        }
        return (origin, target)
    }

    static func authenticated(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("Basic proxy-secret", forHTTPHeaderField: "Proxy-Authorization")
        request.setValue("session=secret", forHTTPHeaderField: "Cookie")
        request.setValue("trace-1", forHTTPHeaderField: "X-Trace")
        return request
    }

    static func redirect(from: String, to: String, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: from)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": to])!
    }

    static func secureOutcome(from: String, to: String, status: Int = 302, hasBody: Bool = false) -> RedirectHandler.Outcome {
        RedirectHandler.secure.outcome(
            for: authenticated(URL(string: to)!),
            response: redirect(from: from, to: to, status: status),
            current: authenticated(URL(string: from)!),
            hasBody: hasBody
        )
    }
}
