//
//  Netti+Caching.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation

/// Reads and invalidates the offline response cache.
///
/// Endpoints opt in with ``HTTPRequest/cachePolicy``. A cache entry is keyed by method, URL with
/// sorted query, and body, so pass the same `method` and `parameters` the request was sent with.
///
/// ```swift
/// let cached: HTTPResponse<[Ride]>? = await netti.cachedResponse(for: RideAPI.history)
/// try await netti.clearCache(for: RideAPI.history)
/// ```
extension Netti {

    /// Returns the cached response for an endpoint without any network access.
    ///
    /// Use it to show the last known data at once in a cache-first flow. It reads the cache
    /// whatever the connectivity, and honours the endpoint's `maxAge`.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - method: The method the response was requested with. `GET` by default.
    ///   - parameters: The query or body it was requested with. Optional.
    /// - Returns: The decoded response with a synthesized `200` status; `nil` when the endpoint
    ///   does not cache, when there is no valid entry, or when the entry no longer decodes.
    public func cachedResponse<Response: Decodable & Sendable>(
        for endpoint: some HTTPRequest,
        method: HTTPMethod = .get,
        parameters: (some Encodable & Sendable)? = Empty?.none
    ) async -> HTTPResponse<Response>? {
        let snapshot = self.snapshot
        guard endpoint.cachePolicy.isCaching,
              let urlRequest = try? buildRequest(endpoint, parameters: parameters, method: method, jsonManager: snapshot.jsonManager),
              let cachedData = await cacheStore.read(key: urlRequest.cacheKey, maxAge: endpoint.cachePolicy.maxAge)
        else {
            return nil
        }
        return try? decode(cachedData, request: urlRequest, using: snapshot)
    }

    /// Removes the cached response for an endpoint, for example after a mutation made it stale.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - method: The method the response was requested with. `GET` by default.
    ///   - parameters: The query or body it was requested with. Optional.
    /// - Throws: ``HTTPRequestError/invalidURL``, ``HTTPRequestError/encodingFailed(_:)``, or
    ///   ``HTTPRequestError/fileSystem(_:)`` when the entry cannot be removed.
    public func clearCache(
        for endpoint: some HTTPRequest,
        method: HTTPMethod = .get,
        parameters: (some Encodable & Sendable)? = Empty?.none
    ) async throws(HTTPRequestError) {
        let key = try buildRequest(endpoint, parameters: parameters, method: method).cacheKey
        do {
            try await cacheStore.remove(key: key)
        } catch {
            throw .fileSystem(error)
        }
    }

    /// Removes every cached response, for example on logout.
    ///
    /// - Throws: ``HTTPRequestError/fileSystem(_:)`` when an entry cannot be removed.
    public func clearCache() async throws(HTTPRequestError) {
        do {
            try await cacheStore.clearAll()
        } catch {
            throw .fileSystem(error)
        }
    }
}
