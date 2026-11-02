//
//  Configuration.swift
//  Netti
//

import Foundation
import Netti
import NettiTesting

/// Every client setting: the JSON coder, interceptors, retry, validation, monitors, logging,
/// connectivity, deduplication, cache size and the engine's own options.
///
/// Runs offline. Settings are plain properties; a change applies to the next request, never to
/// one in flight.
func configurationExample() async throws {
    // MARK: - Constructor options

    // `Netti()` is a working client. This one is only built, never used to send.
    let production = Netti(deduplicatesRequests: false, cacheSizeLimit: 10 * 1024 * 1024)
    production.isLoggingEnabled = false
    report("client -> built with deduplication off and a 10 MB cache cap")

    // The engine takes the session, trust, redirect and size options.
    _ = URLSessionNetworkService(
        configuration: .ephemeral,
        redirectHandler: .secure,
        maxConnectionsPerHost: 4,
        maximumResponseSize: 8 * 1024 * 1024,
        maximumRequestDuration: .seconds(60)
    )
    report("engine -> ephemeral session, secure redirects, 4 connections per host, 8 MB response cap")

    // MARK: - Properties

    let server = StubServer(jsonManager: JSONManager(keyStrategy: .useDefaultKeys))
    server.stub(.get, "https://api.example.com/v1/users/1", json: User(id: 1, name: "Ada"))
    let netti = server.netti()

    // Keys are snake_case unless you say otherwise; here the wire uses the Swift names as is.
    netti.jsonManager = JSONManager(keyStrategy: .useDefaultKeys)
    netti.validation = ResponseValidation()
    netti.retryPolicy = RetryPolicy(maxRetries: 3, baseDelay: .seconds(1))
    netti.interceptors = [.idempotencyKey]
    netti.monitors = [SendMonitor()]
    netti.isLoggingEnabled = false
    netti.connectivity = StubConnectivity(.connected)

    let user: User? = try await netti.get(UserAPI.user(1)).data
    report("config -> \(user?.name ?? "nil") decoded with useDefaultKeys")
}

// MARK: - Helpers

private struct SendMonitor: EventMonitor {
    func requestDidSend(_ request: URLRequest) {
        report("monitor -> sending \(request.httpMethod ?? "") \(request.url?.path ?? "")")
    }
}
