//
//  CachingAndOffline.swift
//  Netti
//

import Foundation
import NettiTesting

/// An endpoint that caches, served from disk while offline, read first for an instant UI, and
/// invalidated.
///
/// Runs offline: `StubConnectivity` plays the network state and `StubServer` the backend. A client
/// from `server.netti()` has its own empty cache, so runs never see each other's entries.
func cachingAndOfflineExample() async throws {
    let server = StubServer()
    server.stub(.get, "https://api.example.com/v1/rides/1", json: [Ride(id: 1), Ride(id: 2)])
    let connectivity = StubConnectivity(.connected)
    let netti = server.netti(connectivity: connectivity)

    // MARK: - Online: network first, and the response is written to disk

    let online: [Ride]? = try await netti.get(RideAPI.page(1)).data
    report("online      -> \(online?.count ?? 0) rides, requests sent: \(server.requests.count)")

    // MARK: - Offline: the cache answers, no request leaves

    connectivity.set(.disconnected)
    let offline: HTTPResponse<[Ride]> = try await netti.get(RideAPI.page(1))
    report("offline     -> \(offline.data?.count ?? 0) rides, status \(offline.statusCode ?? 0), requests sent: \(server.requests.count)")
    try expect(server.requests.count == 1, "the offline read reached the network")
    try expect(offline.data?.count == 2, "the offline read missed the cache")

    // MARK: - Cache first, then refresh

    connectivity.set(.connected)
    let cached: HTTPResponse<[Ride]>? = await netti.cachedResponse(for: RideAPI.page(1))
    report("cache first -> \(cached?.data?.count ?? 0) rides shown at once")
    let fresh: [Ride]? = try await netti.get(RideAPI.page(1)).data
    report("refresh     -> \(fresh?.count ?? 0) rides, requests sent: \(server.requests.count)")

    // MARK: - Invalidate

    try await netti.clearCache(for: RideAPI.page(1))
    let afterClear: HTTPResponse<[Ride]>? = await netti.cachedResponse(for: RideAPI.page(1))
    report("invalidate  -> entry gone: \(afterClear == nil)")
    try expect(afterClear == nil, "the entry survived clearCache")

    // MARK: - Writes made offline go out on reconnect

    let outbox = netti.queue(.serial(waitsForConnectivity: true))
    server.stub(.post, "https://api.example.com/v1/rides/1", status: 201)
    connectivity.set(.disconnected)
    let sending = Task {
        try await outbox.enqueue { try await netti.post(RideAPI.page(1), body: Ride(id: 3)).statusCode }
    }
    while await outbox.pendingCount == 0 {
        await Task.yield()
    }
    report("outbox      -> held while offline, pending: \(await outbox.pendingCount)")
    connectivity.set(.connected)
    let status = try await sending.value
    report("outbox      -> sent on reconnect, status \(status ?? 0)")
    try expect(status == 201, "the queued write did not go out")
}

// MARK: - Helpers

private struct Ride: Codable, Sendable {
    let id: Int
}

private enum RideAPI: HTTPRequest {
    case page(Int)

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String {
        switch self {
            case .page(let number): "rides/\(number)"
        }
    }
    var headers: HTTPHeaders { [.accept("application/json")] }
    var cachePolicy: HTTPCachePolicy { .cache(maxAge: .seconds(24 * 60 * 60)) }
}
