//
//  RedTeamDowngradeTests.swift
//  Netti
//

import Foundation
import Network
import Testing

@testable import Netti

/// S.12 red team, downgrades (TM-03, TM-06): no redirect takes an `https` request to `http`, and
/// neither engine negotiates below TLS 1.2, whatever configuration the caller passes.
///
/// The end-to-end cases use ``RedTeamTLSServer`` for the `https` origin and ``LocalHTTPServer`` as
/// the plain-`http` target.
@Suite("Red team: downgrade", .timeLimit(.minutes(1)), .enabled(if: RedTeamTLSServer.isAvailable, "needs a loopback TLS identity"))
struct RedTeamDowngradeTests {
    typealias Fixture = TrustFixtures.Certificate

    // MARK: - Redirects

    @Test(
        "given an https origin that redirects to http, when the URLSession engine follows its default, then the call fails and the http target is never contacted",
        arguments: [301, 302, 303, 307, 308]
    )
    func httpsToHttp_urlSession_refused(status: Int) async throws {
        let (origin, target) = try await Self.downgradingServers(status: status)
        defer { origin.stop(); target.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, trustPolicy: try Self.serverPolicy())

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await service.data(for: Self.authenticated(origin.url("/start")))
        }

        #expect(error?.urlErrorCode == .appTransportSecurityRequiresSecureConnection)
        #expect(target.requests.isEmpty)
    }

    @Test("given an https origin that redirects to http, when sent through Netti, then the failure is reported to monitors")
    func httpsToHttp_netti_reported() async throws {
        let (origin, target) = try await Self.downgradingServers(status: 302)
        defer { origin.stop(); target.stop() }
        let monitor = RedTeamFailureMonitor()
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral, trustPolicy: try Self.serverPolicy()), monitors: [monitor])

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await netti.send(Self.authenticated(origin.url("/start")))
        }

        #expect(error?.urlErrorCode == .appTransportSecurityRequiresSecureConnection)
        #expect(monitor.failures.values.map(\.urlErrorCode) == [.appTransportSecurityRequiresSecureConnection])
        #expect(target.requests.isEmpty)
    }

    /// The deprecated Alamofire engine has no redirect handler: the transport-security spec scopes
    /// the downgrade refusal to the URLSession engine. This records what it does.
    @Test("given an https origin that redirects to http, when the Alamofire engine sends it, then the http target is never contacted")
    func httpsToHttp_alamofire_probe() async throws {
        let (origin, target) = try await Self.downgradingServers(status: 302)
        defer { origin.stop(); target.stop() }
        let service = AFNetworkService(configuration: .ephemeral, trustPolicy: try Self.serverPolicy())

        _ = try? await service.data(for: Self.authenticated(origin.url("/start")))

        withKnownIssue("TM-red-1: the deprecated AF engine follows an https→http redirect (spec scopes the refusal to the URLSession engine)") {
            #expect(target.requests.isEmpty)
        }
        #expect(target.requests.first?.header("Authorization") == nil, "the bearer token crossed to the http origin")
    }

    @Test(
        "given .secure, when the https source is spelled in any case and the target is plain http, then the redirect fails",
        arguments: [
            ("HTTPS://api.test/start", "http://api.test/final"),
            ("https://api.test/start", "HTTP://api.test/final"),
            ("https://api.test/start", "http://api.test:443/final"),
            ("https://api.test/start", "http://127.0.0.1/final"),
        ]
    )
    func secure_downgradeVariants_fail(from: String, to: String) throws {
        let source = try #require(URL(string: from))
        let destination = try #require(URL(string: to))
        let response = try #require(HTTPURLResponse(url: source, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to]))

        let outcome = RedirectHandler.secure.outcome(for: Self.authenticated(destination), response: response, current: Self.authenticated(source), hasBody: false)

        #expect(outcome == .fail(URLError(.appTransportSecurityRequiresSecureConnection)))
    }

    // MARK: - TLS Floor

    @Test(
        "given a configuration allowing TLS 1.0, when either engine is created, then its session still requires TLS 1.2",
        arguments: EngineKind.allCases, [tls_protocol_version_t.TLSv10, .TLSv11]
    )
    func tlsFloor_raised(engine: EngineKind, requested: tls_protocol_version_t) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = requested

        let negotiated = switch engine {
            case .urlSession: URLSessionNetworkService(configuration: configuration, trustPolicy: ServerTrustPolicy([:])).sessionConfiguration
            case .alamofire: AFNetworkService(configuration: configuration, trustPolicy: ServerTrustPolicy([:])).sessionConfiguration
        }

        #expect(negotiated.tlsMinimumSupportedProtocolVersion.rawValue >= tls_protocol_version_t.TLSv12.rawValue)
    }

    @Test("given the deprecated 1.x Alamofire configuration, when the engine is created, then it requires TLS 1.2")
    @available(*, deprecated)
    func tlsFloor_legacyAlamofire() {
        let service = AFNetworkService(configuration: AFConfiguration())

        #expect(service.sessionConfiguration.tlsMinimumSupportedProtocolVersion.rawValue >= tls_protocol_version_t.TLSv12.rawValue)
    }

    @Test(
        "given a server capped at TLS 1.1 and a caller that allows TLS 1.0, when either engine connects, then the handshake fails and nothing is sent",
        arguments: EngineKind.allCases
    )
    func tlsFloor_endToEnd(engine: EngineKind) async throws {
        let server = try await RedTeamTLSServer.start(maximumTLSVersion: .TLSv11)
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv10
        let policy = try Self.serverPolicy()
        let service: any NetworkService = switch engine {
            case .urlSession: URLSessionNetworkService(configuration: configuration, trustPolicy: policy)
            case .alamofire: AFNetworkService(configuration: configuration, trustPolicy: policy)
        }

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await service.data(for: URLRequest(url: server.url("/legacy")))
        }

        #expect(error != nil)
        #expect(server.requestCount == 0)
    }

    /// Without this control the floor test would also pass if the system could not speak TLS 1.1 at all.
    @Test("given a server capped at TLS 1.1, when a bare URLSession that allows TLS 1.0 connects, then it succeeds (control for the floor test)")
    func tlsFloor_bareSessionControl() async throws {
        let server = try await RedTeamTLSServer.start(maximumTLSVersion: .TLSv11)
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv10
        let session = URLSession(configuration: configuration, delegate: TrustingSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (_, response) = try await session.data(from: server.url("/legacy"))

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(server.requestCount == 1)
    }

    @Test("given a server allowing TLS 1.2, when the engine connects, then the request succeeds (control for the floor test)")
    func tlsFloor_control() async throws {
        let server = try await RedTeamTLSServer.start(maximumTLSVersion: .TLSv12)
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, trustPolicy: try Self.serverPolicy())

        let response = try await service.data(for: URLRequest(url: server.url("/modern")))

        #expect(response.statusCode == 200)
    }
}

// MARK: - Helpers

private extension RedTeamDowngradeTests {
    /// Accepts the TLS server by its own key only.
    static func serverPolicy() throws -> ServerTrustPolicy {
        ServerTrustPolicy(["localhost": .publicKeys([try RedTeamTLSServer.pin, Fixture.authority.expectedPin], performDefaultValidation: false)])
    }

    /// An https origin whose `/start` answers `status` with a `Location` on a plain-http target.
    static func downgradingServers(status: Int) async throws -> (origin: RedTeamTLSServer, target: LocalHTTPServer) {
        let target = try await LocalHTTPServer.start { _ in .text("downgraded") }
        let location = target.url("/final").absoluteString
        let origin = try await RedTeamTLSServer.start { _ in
            RedTeamTLSServer.Response(status: status, headers: ["Location": location], body: Data())
        }
        return (origin, target)
    }

    static func authenticated(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// Accepts every server trust: the bare-session control for the TLS floor.
private final class TrustingSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
