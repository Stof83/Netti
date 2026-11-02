//
//  RedTeamSessionIsolationTests.swift
//  Netti
//

import Foundation
import Testing

@testable import Netti

/// S.12 red team, TM-15: two engines in one process hit the same host. The unpinned one connects
/// first and accepts the server (standing in for a mis-issued certificate the system trusts); the
/// pinned one must still get a trust challenge and reject the server, whatever TLS session state,
/// connection pool or cache the process kept from the first connection.
///
/// Runs against ``RedTeamTLSServer``, a real TLS 1.2/1.3 listener on 127.0.0.1, with `.default`
/// configurations so the engines share every process-wide store `URLSession` offers.
@Suite("Red team: session isolation (TM-15)", .timeLimit(.minutes(1)), .enabled(if: RedTeamTLSServer.isAvailable, "needs a loopback TLS identity"))
struct RedTeamSessionIsolationTests {
    typealias Fixture = TrustFixtures.Certificate

    @Test(
        "given an unpinned engine that already connected, when a pinned engine requests the same host, then its evaluator runs and the server is rejected",
        arguments: EngineKind.allCases
    )
    func pinnedEngine_afterUnpinned_stillEvaluates(pinnedEngine: EngineKind) async throws {
        let server = try await RedTeamTLSServer.start()
        defer { server.stop() }
        let unpinned = URLSessionNetworkService(configuration: .default, trustPolicy: ServerTrustPolicy(["localhost": .custom(RedTeamAcceptingEvaluator())]))
        let evaluations = Counter()
        let pinnedPolicy = ServerTrustPolicy(["localhost": .composite([
            .custom(RedTeamCountingEvaluator(counter: evaluations)),
            .publicKeys([Fixture.unrelated.expectedPin, Fixture.otherHost.expectedPin], performDefaultValidation: false),
        ])])
        let pinned: any NetworkService = switch pinnedEngine {
            case .urlSession: URLSessionNetworkService(configuration: .default, trustPolicy: pinnedPolicy)
        }

        for round in 1...3 {
            let accepted = try await unpinned.data(for: URLRequest(url: server.url("/unpinned/\(round)")))
            #expect(accepted.statusCode == 200)

            let error = await expectRequestError { () async throws(HTTPRequestError) in
                try await pinned.data(for: URLRequest(url: server.url("/pinned/\(round)")))
            }

            #expect(error?.trustFailureHost == "localhost", "round \(round): \(String(describing: error))")
            #expect(evaluations.value == round, "round \(round): the pinned engine was not challenged")
        }
        #expect(server.requestCount == 3, "only the unpinned engine's requests may reach the server")
    }

    @Test("given a pinned engine that connected with the right pin, when a second engine pinned to another key requests the same host, then it is still rejected")
    func secondPinnedEngine_afterTrustedOne_stillEvaluates() async throws {
        let server = try await RedTeamTLSServer.start()
        defer { server.stop() }
        let trusted = URLSessionNetworkService(configuration: .default, trustPolicy: ServerTrustPolicy([
            "localhost": .publicKeys([try RedTeamTLSServer.pin, Fixture.authority.expectedPin], performDefaultValidation: false),
        ]))
        let evaluations = Counter()
        let mismatched = URLSessionNetworkService(configuration: .default, trustPolicy: ServerTrustPolicy(["localhost": .composite([
            .custom(RedTeamCountingEvaluator(counter: evaluations)),
            .publicKeys([Fixture.unrelated.expectedPin, Fixture.otherHost.expectedPin], performDefaultValidation: false),
        ])]))

        let accepted = try await trusted.data(for: URLRequest(url: server.url("/trusted")))
        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await mismatched.data(for: URLRequest(url: server.url("/mismatched")))
        }

        #expect(accepted.statusCode == 200)
        #expect(error?.trustFailureHost == "localhost")
        #expect(evaluations.value == 1)
        #expect(server.requestCount == 1)
    }

    @Test("given one pinned engine, when it sends several requests to the same host, then every new connection is challenged")
    func pinnedEngine_everyConnectionChallenged() async throws {
        let server = try await RedTeamTLSServer.start()
        defer { server.stop() }
        let evaluations = Counter()
        let engine = URLSessionNetworkService(configuration: .default, trustPolicy: ServerTrustPolicy(["localhost": .composite([
            .custom(RedTeamCountingEvaluator(counter: evaluations)),
            .publicKeys([try RedTeamTLSServer.pin, Fixture.authority.expectedPin], performDefaultValidation: false),
        ])]))

        for index in 1...3 {
            _ = try await engine.data(for: URLRequest(url: server.url("/\(index)")))
        }

        // The server closes every connection, so each request opens, and must evaluate, a new one.
        #expect(evaluations.value == server.connectionCount)
        #expect(server.requestCount == 3)
    }
}
