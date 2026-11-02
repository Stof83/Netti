//
//  RedTeamCacheTests.swift
//  Netti
//

import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

/// S.12 red team, response cache (TM-11, TM-27, TM-31): crafted requests must not read another
/// request's entry, a tampered entry on disk must be a miss rather than a crash, and the documented
/// account-switch behaviour must still hold.
@Suite("Red team: cache", .timeLimit(.minutes(1)))
struct RedTeamCacheTests {

    // MARK: - Types

    struct Pair: CustomTestStringConvertible, Sendable {
        let name: String
        let first: URLRequest
        let second: URLRequest

        var testDescription: String {
            name
        }

        init(_ name: String, _ first: String, _ second: String, firstMethod: String = "GET", secondMethod: String = "GET", firstBody: String? = nil, secondBody: String? = nil) {
            self.name = name
            self.first = Self.request(first, method: firstMethod, body: firstBody)
            self.second = Self.request(second, method: secondMethod, body: secondBody)
        }

        private static func request(_ url: String, method: String, body: String?) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = method
            request.httpBody = body.map { Data($0.utf8) }
            return request
        }
    }

    // MARK: - Constants

    private static let distinct: [Pair] = [
        Pair("method GET vs HEAD", "https://api.test/items", "https://api.test/items", secondMethod: "HEAD"),
        Pair("method GET vs POST", "https://api.test/items", "https://api.test/items", secondMethod: "POST"),
        Pair("body differs", "https://api.test/items", "https://api.test/items", firstMethod: "POST", secondMethod: "POST", firstBody: #"{"id":1}"#, secondBody: #"{"id":2}"#),
        Pair("body vs no body", "https://api.test/items", "https://api.test/items", firstMethod: "POST", secondMethod: "POST", firstBody: "x"),
        Pair("path case", "https://api.test/Items", "https://api.test/items"),
        Pair("query value case", "https://api.test/items?q=A", "https://api.test/items?q=a"),
        Pair("encoded & in a value", "https://api.test/items?q=a%26b=c", "https://api.test/items?q=a&b=c"),
        Pair("encoded = in a value", "https://api.test/items?q=a%3Db", "https://api.test/items?q=a&b"),
        Pair("literal + vs encoded +", "https://api.test/items?q=a+b", "https://api.test/items?q=a%2Bb"),
        Pair("encoded slash in path", "https://api.test/a%2Fb", "https://api.test/a/b"),
        Pair("duplicate key", "https://api.test/items?a=1", "https://api.test/items?a=1&a=1"),
        Pair("key without value vs empty value", "https://api.test/items?a", "https://api.test/items?a="),
        Pair("scheme", "http://api.test/items", "https://api.test/items"),
        Pair("host", "https://api.test/items", "https://api.test.evil/items"),
        Pair("port", "https://api.test/items", "https://api.test:8443/items"),
        Pair("separator in the path", "https://api.test/items%7CGET", "https://api.test/items"),
        Pair("value moved between keys", "https://api.test/items?a=1&b=2", "https://api.test/items?a=2&b=1"),
    ]

    private static let equivalent: [Pair] = [
        Pair("query order", "https://api.test/items?a=1&b=2&c=3", "https://api.test/items?c=3&a=1&b=2"),
        Pair("fragment", "https://api.test/items?a=1#top", "https://api.test/items?a=1"),
        Pair("nil vs empty body", "https://api.test/items", "https://api.test/items", firstMethod: "POST", secondMethod: "POST", firstBody: ""),
    ]

    // MARK: - Key Collisions

    @Test("given requests that differ semantically, when their cache keys are computed, then they never collide", arguments: distinct)
    func distinctRequests_distinctKeys(pair: Pair) {
        #expect(pair.first.cacheKey != pair.second.cacheKey)
    }

    @Test("given equivalent requests, when their cache keys are computed, then they share one", arguments: equivalent)
    func equivalentRequests_sameKey(pair: Pair) {
        #expect(pair.first.cacheKey == pair.second.cacheKey)
    }

    @Test("given a repeated query key, when its values are reordered, then the requests do not share an entry")
    func repeatedKeyOrder_distinctKeys() {
        let pair = Pair("repeated key order", "https://api.test/items?id=1&id=2", "https://api.test/items?id=2&id=1")

        withKnownIssue("TM-red-2: sorting query items by name and value makes ?id=1&id=2 and ?id=2&id=1 share a cache entry") {
            #expect(pair.first.cacheKey != pair.second.cacheKey)
        }
    }

    @Test("given requests that differ only in Accept-Language, when their cache keys are computed, then they do not share an entry")
    func headerOnlyDifference_distinctKeys() {
        var english = URLRequest(url: URL(string: "https://api.test/items")!)
        english.setValue("en", forHTTPHeaderField: "Accept-Language")
        var italian = english
        italian.setValue("it", forHTTPHeaderField: "Accept-Language")

        withKnownIssue("TM-red-3: the cache key ignores every header, so content-negotiated variants share one offline entry") {
            #expect(english.cacheKey != italian.cacheKey)
        }
    }

    @Test("given two endpoints that differ only in their query order, when one is cached and the other read offline, then the entry is shared")
    func equivalentEndpoint_servedOffline() async throws {
        let connectivity = StubConnectivity(.connected)
        let service = StubNetworkService { request in
            if connectivity.currentStatus == .disconnected {
                throw URLError(.notConnectedToInternet)
            }
            return try .json(for: request, Widget(id: 1, name: request.url?.query ?? ""))
        }
        let netti = makeNetti(service: service, connectivity: connectivity)
        let cached = Self.cachedEndpoint("https://api.test/items?a=1&b=2")
        let reordered = Self.cachedEndpoint("https://api.test/items?b=2&a=1")
        let other = Self.cachedEndpoint("https://api.test/items?a=2&b=1")

        let original: HTTPResponse<Widget> = try await netti.get(cached)
        connectivity.set(.disconnected)
        let shared: HTTPResponse<Widget> = try await netti.get(reordered)
        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Widget> in
            try await netti.get(other)
        }

        #expect(shared.data == original.data)
        #expect(error != nil, "a semantically different query was served the cached entry")
        #expect(service.requests.count == 2)
    }

    // MARK: - TM-27 Deduplication

    @Test("given concurrent identical GETs for two users, when sent, then each user gets a transfer of their own")
    func deduplication_neverCoalescesAcrossUsers() async throws {
        let service = StubNetworkService { request in
            try await Task.sleep(for: .milliseconds(100))
            return try .json(for: request, Widget(id: 1, name: request.value(forHTTPHeaderField: "Authorization") ?? "anonymous"))
        }
        let authenticate = ClosureAdapter { request in
            var request = request
            request.setValue(request.value(forHTTPHeaderField: "X-User"), forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "X-User")
            return request
        }
        let netti = makeNetti(service: service, interceptors: [authenticate])
        let url = URL(string: "https://api.test/me")!

        async let alice: HTTPResponse<Widget> = netti.send(Self.request(url, user: "alice"))
        async let bob: HTTPResponse<Widget> = netti.send(Self.request(url, user: "bob"))
        async let aliceAgain: HTTPResponse<Widget> = netti.send(Self.request(url, user: "alice"))
        let names = try await [alice.data?.name, bob.data?.name, aliceAgain.data?.name]

        #expect(names == ["alice", "bob", "alice"])
        #expect(service.requests.count == 2, "alice's two requests share one transfer, bob gets his own")
    }

    // MARK: - TM-11 Account Switch

    @Test("given user A's response cached, when user B reads it offline, then A's entry is served until clearCache, as documented")
    func accountSwitch_documentedBehaviourHolds() async throws {
        let connectivity = StubConnectivity(.connected)
        let service = StubNetworkService { request in
            if connectivity.currentStatus == .disconnected {
                throw URLError(.notConnectedToInternet)
            }
            return try .json(for: request, Widget(id: 1, name: request.value(forHTTPHeaderField: "Authorization") ?? "anonymous"))
        }
        let interceptor = AuthenticationInterceptor(bearerToken: "user-a") { $0 }
        let netti = makeNetti(service: service, interceptors: [interceptor], connectivity: connectivity)
        let endpoint = Self.cachedEndpoint("https://api.test/me")

        _ = try await netti.get(endpoint) as HTTPResponse<Widget>
        await interceptor.setCredential("user-b")
        connectivity.set(.disconnected)
        let servedToB: HTTPResponse<Widget> = try await netti.get(endpoint)
        try await netti.clearCache()
        let afterClear = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Widget> in
            try await netti.get(endpoint)
        }

        #expect(servedToB.data?.name == "Bearer user-a", "TM-11: the key is computed before the token is added")
        #expect(afterClear != nil)
    }

    // MARK: - Tampered Entries

    @Test(
        "given a cache file that was truncated or replaced, when read after a relaunch, then it is a miss",
        arguments: ["empty", "half", "one byte short", "random bytes", "plain JSON", "other archive class"]
    )
    func tamperedFile_miss(tampering: String) async throws {
        let (directory, key) = try await Self.cachedEntry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(key)
        let original = try Data(contentsOf: file)
        var random = RedTeamRandom(seed: 0xCAC4E)
        let tampered: Data = switch tampering {
            case "empty": Data()
            case "half": original.prefix(original.count / 2)
            case "one byte short": original.dropLast()
            case "random bytes": random.bytes(original.count)
            case "plain JSON": Data(#"{"data":"evil","timestamp":0}"#.utf8)
            default: try NSKeyedArchiver.archivedData(withRootObject: ["data": Data("evil".utf8)] as NSDictionary, requiringSecureCoding: true)
        }
        try tampered.write(to: file)

        let read = await Self.relaunchedStore(directory).read(key: key)

        #expect(read == nil)
    }

    @Test("given 2,000 random bit flips in a cache file, when each is read after a relaunch, then reading never crashes and corrupted archives are misses")
    func bitFlips_neverCrash() async throws {
        let (directory, key) = try await Self.cachedEntry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(key)
        let original = try Data(contentsOf: file)
        var random = RedTeamRandom(seed: 0xB17F_11B5)
        var misses = 0

        for _ in 0..<2_000 {
            var tampered = original
            for _ in 0..<Int.random(in: 1...8, using: &random) {
                let index = Int.random(in: 0..<tampered.count, using: &random)
                tampered[index] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &random)
            }
            try tampered.write(to: file)
            let read = await Self.relaunchedStore(directory).read(key: key)
            if read == nil {
                misses += 1
            }
        }

        #expect(misses > 0)
    }

    @Test("given a bit flipped inside the stored payload, when read after a relaunch, then the tampered body is not served")
    func payloadBitFlip_notServed() async throws {
        let (directory, key) = try await Self.cachedEntry()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(key)
        var tampered = try Data(contentsOf: file)
        let payloadRange = try #require(tampered.range(of: Self.payload))
        tampered[payloadRange.lowerBound + 7] ^= 0x01
        try tampered.write(to: file)

        let read = await Self.relaunchedStore(directory).read(key: key)

        withKnownIssue("TM-red-4: cache entries carry no integrity check; a flipped payload byte is served instead of being a miss (TM-31 assumes a miss)") {
            #expect(read == nil)
        }
        #expect(read == nil || read?.count == Self.payload.count)
    }
}

// MARK: - Helpers

private extension RedTeamCacheTests {
    static let payload = Data(#"{"id":1,"name":"payload-marker-0123456789"}"#.utf8)

    static func cachedEndpoint(_ url: String) -> CachedURLEndpoint {
        CachedURLEndpoint(url: URL(string: url)!)
    }

    static func request(_ url: URL, user: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(user, forHTTPHeaderField: "X-User")
        return request
    }

    /// Writes ``payload`` under a fresh key in a new directory; returns both.
    static func cachedEntry() async throws -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-redteam-cache-\(UUID().uuidString)", isDirectory: true)
        let store = relaunchedStore(directory)
        let key = URLRequest(url: URL(string: "https://api.test/me")!).cacheKey
        try await store.write(payload, key: key)
        return (directory, key)
    }

    /// A store with an empty memory cache, as after a relaunch.
    static func relaunchedStore(_ directory: URL) -> HTTPCacheStore {
        HTTPCacheStore(diskCache: DiskCache(directoryURL: directory, sizeLimit: DiskCache.defaultSizeLimit, now: { Date() }))
    }
}

/// An endpoint for a full URL with a ten-minute offline cache.
struct CachedURLEndpoint: HTTPRequest {
    let url: URL

    var baseURL: URL? { url }
    var basePath: String { "" }
    var path: String { "" }
    var requestURL: URL { url }
    var headers: HTTPHeaders { [:] }
    var cachePolicy: HTTPCachePolicy { .cache(maxAge: .seconds(600)) }
}
