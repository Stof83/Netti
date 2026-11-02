//
//  TrustEventTests.swift
//  Netti
//

import Foundation
import Testing

@testable import Netti
import NettiTesting

/// TM-26 / S.8: a pin or trust failure reaches `EventMonitor.requestDidFail` as
/// `serverTrustEvaluationFailed`, for data, transfer, stream and WebSocket requests, on both engines.
///
/// The engines run against ``RedTeamTLSServer``, a real TLS listener on 127.0.0.1 with a
/// self-signed `localhost` certificate, so the failure comes from an actual trust challenge. The
/// Alamofire engine opens WebSockets through its internal `URLSessionNetworkService`.
@Suite("Trust events", .timeLimit(.minutes(1)), .enabled(if: RedTeamTLSServer.isAvailable, "needs a loopback TLS identity"))
struct TrustEventTests {
    typealias Fixture = TrustFixtures.Certificate

    // MARK: - Types

    enum Operation: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case data
        case upload
        case download
        case stream
        case webSocket

        var testDescription: String {
            rawValue
        }

        func run(_ netti: Netti, url: URL) async throws(HTTPRequestError) {
            switch self {
                case .data:
                    try await netti.send(URLRequest(url: url))
                case .upload:
                    try await netti.upload(URLEndpoint(url), data: Data("payload".utf8))
                case .download:
                    _ = try await netti.download(URLEndpoint(url))
                case .stream:
                    _ = try await netti.stream(URLRequest(url: url))
                case .webSocket:
                    _ = try await netti.webSocket(URLEndpoint(url))
            }
        }
    }

    // MARK: - Engines

    @Test(
        "given a pin the server does not match, when a request runs on a real TLS engine, then every monitor receives requestDidFail with serverTrustEvaluationFailed",
        arguments: EngineKind.allCases, Operation.allCases
    )
    func pinMismatch_reachesMonitors(engine: EngineKind, operation: Operation) async throws {
        let server = try await RedTeamTLSServer.start()
        defer { server.stop() }
        let first = RedTeamFailureMonitor()
        let second = RedTeamFailureMonitor()
        let netti = makeNetti(service: Self.service(engine, policy: Self.mismatchedPolicy), monitors: [first, second])

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await operation.run(netti, url: server.url("/\(operation.rawValue)"))
        }

        #expect(error?.trustFailureHost == "localhost", "\(String(describing: error))")
        for monitor in [first, second] {
            #expect(monitor.failures.values.count == 1)
            #expect(monitor.failures.values.first?.trustFailureHost == "localhost", "\(monitor.failures.values)")
        }
        #expect(server.requestCount == 0)
    }

    @Test(
        "given the server's own pin, when a data request runs on a real TLS engine, then it succeeds and no failure is reported",
        arguments: EngineKind.allCases
    )
    func pinMatch_noFailureEvent(engine: EngineKind) async throws {
        let server = try await RedTeamTLSServer.start()
        defer { server.stop() }
        let monitor = RedTeamFailureMonitor()
        let policy = ServerTrustPolicy(["localhost": .publicKeys([try RedTeamTLSServer.pin, Fixture.authority.expectedPin], performDefaultValidation: false)])
        let netti = makeNetti(service: Self.service(engine, policy: policy), monitors: [monitor])

        let response = try await netti.send(URLRequest(url: server.url("/data")))

        #expect(response.statusCode == 200)
        #expect(monitor.failures.values.isEmpty)
        #expect(server.requestCount == 1)
    }

    // MARK: - Pipeline

    @Test("given a WebSocket transport that fails trust, when opened, then every monitor receives the same serverTrustEvaluationFailed")
    func webSocketPipeline_forwardsTrustFailure() async {
        let service = StubNetworkService(webSocket: { request in
            throw HTTPRequestError.serverTrustEvaluationFailed(host: request.url?.host ?? "", reason: "pin mismatch")
        })
        let monitors = [RedTeamFailureMonitor(), RedTeamFailureMonitor()]
        let netti = makeNetti(service: service, monitors: monitors)

        let error = await expectRequestError { () async throws(HTTPRequestError) -> WebSocketConnection in
            try await netti.webSocket(TestEndpoint())
        }

        #expect(error?.trustFailureHost == "api.test")
        for monitor in monitors {
            #expect(monitor.failures.values.map(\.trustFailureHost) == ["api.test"])
        }
    }

    @Test("given a retry policy, when a data request fails trust, then it is not retried and fails once")
    func trustFailure_notRetried() async throws {
        let server = try await RedTeamTLSServer.start()
        defer { server.stop() }
        let monitor = RecordingMonitor()
        let netti = makeNetti(
            service: Self.service(.urlSession, policy: Self.mismatchedPolicy),
            retryPolicy: RetryPolicy(),
            monitors: [monitor]
        )

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await netti.send(URLRequest(url: server.url("/data")))
        }

        #expect(error?.trustFailureHost == "localhost")
        #expect(monitor.events.values.filter { $0 == "retry" }.isEmpty)
        #expect(monitor.events.values.last == "fail")
    }
}

// MARK: - Helpers

private extension TrustEventTests {
    /// Pins that no key of the TLS server matches; no default validation, so only the pin decides.
    static let mismatchedPolicy = ServerTrustPolicy([
        "localhost": .publicKeys([Fixture.unrelated.expectedPin, Fixture.otherHost.expectedPin], performDefaultValidation: false),
    ])

    static func service(_ engine: EngineKind, policy: ServerTrustPolicy) -> any NetworkService {
        switch engine {
            case .urlSession:
                URLSessionNetworkService(configuration: .ephemeral, trustPolicy: policy)
            case .alamofire:
                AFNetworkService(configuration: .ephemeral, trustPolicy: policy)
        }
    }
}
