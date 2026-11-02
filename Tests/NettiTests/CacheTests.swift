import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

@Suite("Response cache", .timeLimit(.minutes(1)))
struct CacheTests {

    private struct Page: Encodable, Sendable {
        let page: Int
    }

    // MARK: - Policy

    @Test("given an endpoint with cache policy none, when a 200 is received, then no entry is written")
    func nonCachingEndpoint_writesNothing() async throws {
        let service = StubNetworkService { try .json(for: $0, Widget(id: 1, name: "a")) }
        let netti = makeNetti(service: service)
        var caching = TestEndpoint()
        caching.cachePolicy = .cache

        let _: HTTPResponse<Widget> = try await netti.get(TestEndpoint())

        let cached: HTTPResponse<Widget>? = await netti.cachedResponse(for: caching)
        #expect(cached == nil)
    }

    @Test("given a caching endpoint, when a non-2xx is received, then it is not cached")
    func non2xx_isNotCached() async throws {
        let service = StubNetworkService { try .json(for: $0, status: 500, Widget(id: 1, name: "a")) }
        let netti = makeNetti(service: service)
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache

        let _: HTTPResponse<Widget> = try await netti.get(endpoint)

        let cached: HTTPResponse<Widget>? = await netti.cachedResponse(for: endpoint)
        #expect(cached == nil)
    }

    // MARK: - Read-Your-Write

    @Test("given a caching GET, when it returns, then the cached response is readable at once")
    func readYourWrite() async throws {
        let service = StubNetworkService { try .json(for: $0, Widget(id: 1, name: "fresh")) }
        let netti = makeNetti(service: service)
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache

        let _: HTTPResponse<Widget> = try await netti.get(endpoint)
        let cached: HTTPResponse<Widget>? = await netti.cachedResponse(for: endpoint)

        #expect(cached?.data == Widget(id: 1, name: "fresh"))
        #expect(cached?.statusCode == 200)
    }

    // MARK: - Offline

    @Test("given page 1 cached, when page 2 is requested offline, then page 1 is not returned for it")
    func distinctKeysPerQuery() async throws {
        let connectivity = StubConnectivity(.connected)
        let service = StubNetworkService { request in
            if connectivity.currentStatus == .disconnected {
                throw URLError(.notConnectedToInternet)
            }
            return try .json(for: request, Widget(id: 1, name: "page 1"))
        }
        let netti = makeNetti(service: service, connectivity: connectivity)
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache
        let _: HTTPResponse<Widget> = try await netti.get(endpoint, query: Page(page: 1))
        connectivity.set(.disconnected)

        let pageOne: HTTPResponse<Widget> = try await netti.get(endpoint, query: Page(page: 1))
        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Widget> in
            try await netti.get(endpoint, query: Page(page: 2))
        }

        #expect(pageOne.data?.name == "page 1")
        #expect(error?.urlErrorCode == .notConnectedToInternet)
        #expect(service.requests.count == 2)
    }

    @Test("given unknown connectivity, when a caching endpoint is requested, then the network is used, not the cache")
    func unknownConnectivity_usesNetwork() async throws {
        let responses = Counter()
        let service = StubNetworkService { try .json(for: $0, Widget(id: responses.increment(), name: "network")) }
        let connectivity = StubConnectivity(.connected)
        let netti = makeNetti(service: service, connectivity: connectivity)
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache
        let _: HTTPResponse<Widget> = try await netti.get(endpoint)
        connectivity.set(.unknown)

        let response: HTTPResponse<Widget> = try await netti.get(endpoint)

        #expect(response.data?.id == 2)
        #expect(service.requests.count == 2)
    }

    @Test("given an injected source reporting disconnected, when a caching endpoint is requested, then cached data is served without the network")
    func offline_servesCache() async throws {
        let service = StubNetworkService { try .json(for: $0, Widget(id: 1, name: "cached")) }
        let connectivity = StubConnectivity(.connected)
        let netti = makeNetti(service: service, connectivity: connectivity)
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache
        let _: HTTPResponse<Widget> = try await netti.get(endpoint)
        connectivity.set(.disconnected)

        let response: HTTPResponse<Widget> = try await netti.get(endpoint)

        #expect(response.data?.name == "cached")
        #expect(service.requests.count == 1)
    }

    // MARK: - Expiry

    @Test("given an entry older than its maxAge, when read, then it is a miss")
    func maxAgeExpires() async throws {
        let clock = TestClock()
        let service = StubNetworkService { try .json(for: $0, Widget(id: 1, name: "a")) }
        let netti = makeNetti(service: service, cacheStore: makeCacheStore(now: clock.now))
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache(maxAge: .seconds(60))
        let _: HTTPResponse<Widget> = try await netti.get(endpoint)

        clock.advance(by: 59)
        let fresh: HTTPResponse<Widget>? = await netti.cachedResponse(for: endpoint)
        clock.advance(by: 2)
        let expired: HTTPResponse<Widget>? = await netti.cachedResponse(for: endpoint)

        #expect(fresh?.data?.id == 1)
        #expect(expired == nil)
    }

    // MARK: - Size Limit

    @Test("given a full cache, when a new entry is written, then the least recently used entries are evicted")
    func lruEviction() async throws {
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-lru-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entrySize = 10_000
        let store = HTTPCacheStore(
            diskCache: DiskCache(directoryURL: directory, sizeLimit: 3 * entrySize + 3 * 1_000, now: clock.now),
            now: clock.now
        )

        for key in ["a", "b", "c"] {
            try await store.write(Data(count: entrySize), key: key)
            clock.advance(by: 1)
        }
        _ = await store.read(key: "a")
        clock.advance(by: 1)
        try await store.write(Data(count: entrySize), key: "d")

        let reloaded = HTTPCacheStore(diskCache: DiskCache(directoryURL: directory, sizeLimit: .max, now: clock.now), now: clock.now)
        #expect(await reloaded.read(key: "a") != nil)
        #expect(await reloaded.read(key: "b") == nil)
        #expect(await reloaded.read(key: "c") != nil)
        #expect(await reloaded.read(key: "d") != nil)
        #expect(await store.read(key: "b") == nil)
    }

    @Test("given the default disk cache, when created, then its size limit is 50 MB")
    func defaultSizeLimit() {
        #expect(DiskCache(directoryName: "netti-default-\(UUID().uuidString)").sizeLimit == 50 * 1024 * 1024)
    }

    // MARK: - Invalidation

    @Test("given a cached endpoint, when its cache is cleared, then a cache-first read returns nothing")
    func clearCacheForEndpoint() async throws {
        let service = StubNetworkService { try .json(for: $0, Widget(id: 1, name: "a")) }
        let netti = makeNetti(service: service)
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache
        var other = TestEndpoint()
        other.path = "other"
        other.cachePolicy = .cache
        let _: HTTPResponse<Widget> = try await netti.get(endpoint)
        let _: HTTPResponse<Widget> = try await netti.get(other)

        try await netti.clearCache(for: endpoint)

        let cleared: HTTPResponse<Widget>? = await netti.cachedResponse(for: endpoint)
        let kept: HTTPResponse<Widget>? = await netti.cachedResponse(for: other)
        #expect(cleared == nil)
        #expect(kept != nil)
    }

    @Test("given cached endpoints, when the whole cache is cleared, then every cache-first read returns nothing")
    func clearAll() async throws {
        let service = StubNetworkService { try .json(for: $0, Widget(id: 1, name: "a")) }
        let netti = makeNetti(service: service)
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache
        let _: HTTPResponse<Widget> = try await netti.get(endpoint, query: Page(page: 3))

        let before: HTTPResponse<Widget>? = await netti.cachedResponse(for: endpoint, parameters: Page(page: 3))
        try await netti.clearCache()
        let after: HTTPResponse<Widget>? = await netti.cachedResponse(for: endpoint, parameters: Page(page: 3))

        #expect(before != nil)
        #expect(after == nil)
    }
}

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let date = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    var now: @Sendable () -> Date {
        { [date] in date.withLock { $0 } }
    }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 += seconds }
    }
}
