//
//  RedTeamRefreshStormTests.swift
//  Netti
//

import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

/// S.12 red team, token refresh under load: a burst of 401s triggers exactly one refresh and every
/// request completes with the renewed token; a refresh that keeps failing ends, never loops.
@Suite("Red team: refresh storm", .timeLimit(.minutes(1)))
struct RedTeamRefreshStormTests {

    // MARK: - Constants

    private static let stale = "stale"
    private static let fresh = "fresh"

    // MARK: - Storm

    @Test("given 1,000 concurrent requests that all get 401, when the token is refreshed, then it is refreshed once and every request completes with the new token")
    func storm_singleRefresh() async throws {
        let refreshes = Counter()
        let service = StubNetworkService { request in
            let isFresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fresh)"
            return .stub(for: request, status: isFresh ? 200 : 401)
        }
        let interceptor = AuthenticationInterceptor(bearerToken: Self.stale) { _ in
            refreshes.increment()
            try await Task.sleep(for: .milliseconds(50))
            return Self.fresh
        }
        let netti = makeNetti(service: service, interceptors: [interceptor], deduplicatesRequests: false)

        let statuses = try await Self.burst(1_000, on: netti)

        #expect(refreshes.value == 1)
        #expect(statuses.count == 1_000)
        #expect(statuses.allSatisfy { $0 == 200 })
        let final = Dictionary(grouping: service.requests, by: { $0.url?.path ?? "" }).compactMapValues(\.last)
        #expect(final.count == 1_000)
        #expect(final.values.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fresh)" })
        #expect(service.requests.count <= 2_000, "a request was sent more than twice")
    }

    // MARK: - Failing Refresh

    @Test("given a refresh that always throws, when a request gets 401, then it ends with that 401 after one attempt")
    func failingRefresh_single_ends() async throws {
        let refreshes = Counter()
        let service = StubNetworkService { .stub(for: $0, status: 401) }
        let interceptor = AuthenticationInterceptor(bearerToken: Self.stale) { _ in
            refreshes.increment()
            throw URLError(.userAuthenticationRequired)
        }
        let netti = makeNetti(service: service, interceptors: [interceptor])

        let response = try await netti.send(URLRequest(url: URL(string: "https://api.test/me")!))

        #expect(response.statusCode == 401)
        #expect(refreshes.value == 1)
        #expect(service.requests.count == 1)
    }

    @Test("given a refresh that returns a token the server also rejects, when a request gets 401, then it ends after one refresh and two attempts")
    func rejectedRefresh_single_ends() async throws {
        let refreshes = Counter()
        let service = StubNetworkService { .stub(for: $0, status: 401) }
        let interceptor = AuthenticationInterceptor(bearerToken: Self.stale) { token in
            "\(token)-\(refreshes.increment())"
        }
        let netti = makeNetti(service: service, interceptors: [interceptor], retryPolicy: RetryPolicy())

        let response = try await netti.send(URLRequest(url: URL(string: "https://api.test/me")!))

        #expect(response.statusCode == 401)
        #expect(refreshes.value == 1)
        #expect(service.requests.count == 2)
    }

    @Test("given 1,000 concurrent requests and a refresh that always throws, when they all get 401, then every request ends with 401 and each sends once")
    func failingRefresh_storm_ends() async throws {
        let refreshes = Counter()
        let service = StubNetworkService { .stub(for: $0, status: 401) }
        let interceptor = AuthenticationInterceptor(bearerToken: Self.stale) { _ in
            refreshes.increment()
            try await Task.sleep(for: .milliseconds(20))
            throw URLError(.userAuthenticationRequired)
        }
        let netti = makeNetti(service: service, interceptors: [interceptor], deduplicatesRequests: false)

        let statuses = try await Self.burst(1_000, on: netti)

        #expect(statuses.count == 1_000)
        #expect(statuses.allSatisfy { $0 == 401 })
        #expect(service.requests.count == 1_000)
        #expect(refreshes.value <= 1_000)
    }
}

// MARK: - Helpers

private extension RedTeamRefreshStormTests {
    /// Sends `count` concurrent requests to distinct paths and returns their statuses.
    static func burst(_ count: Int, on netti: Netti) async throws -> [Int] {
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await netti.send(URLRequest(url: URL(string: "https://api.test/items/\(index)")!)).statusCode ?? 0
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
    }
}
