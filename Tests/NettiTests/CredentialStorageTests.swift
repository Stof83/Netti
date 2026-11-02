import Foundation
import Testing

@testable import Netti

/// TM-10/17: authenticated responses stay out of `URLCache`, and the Netti disk cache is protected
/// and excluded from backups.
@Suite("Credential-safe storage", .timeLimit(.minutes(1)))
struct CredentialStorageTests {

    // MARK: - URLCache

    @Test("given a cacheable response, when the GET carries Authorization, then URLCache holds no entry; without it, the entry is stored")
    func urlCache_skipsAuthenticatedResponses() async throws {
        let server = try await LocalHTTPServer.start { request in
            .text("body of \(request.path)", headers: ["Cache-Control": "max-age=600"])
        }
        defer { server.stop() }
        let cache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = cache
        let service = URLSessionNetworkService(configuration: configuration)
        var authenticated = URLRequest(url: server.url("/me"))
        authenticated.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let anonymous = URLRequest(url: server.url("/public"))

        _ = try await service.data(for: authenticated)
        _ = try await service.data(for: anonymous)

        #expect(await eventually { cache.cachedResponse(for: anonymous) != nil }, "the control response was never cached")
        #expect(cache.cachedResponse(for: authenticated) == nil)
        #expect(cache.cachedResponse(for: URLRequest(url: server.url("/me"))) == nil)
    }

    @Test(
        "given a cacheable response, when the GET carries another credential header, then URLCache holds no entry (TM-38)",
        arguments: ["Cookie", "Proxy-Authorization", "X-Api-Key", "X-Session-Token"]
    )
    func urlCache_skipsCredentialHeaders(name: String) async throws {
        let server = try await LocalHTTPServer.start { request in
            .text("body of \(request.path)", headers: ["Cache-Control": "max-age=600"])
        }
        defer { server.stop() }
        let cache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = cache
        let service = URLSessionNetworkService(configuration: configuration)
        var authenticated = URLRequest(url: server.url("/me"))
        authenticated.setValue("secret", forHTTPHeaderField: name)
        let anonymous = URLRequest(url: server.url("/public"))

        _ = try await service.data(for: authenticated)
        _ = try await service.data(for: anonymous)

        #expect(await eventually { cache.cachedResponse(for: anonymous) != nil }, "the control response was never cached")
        #expect(cache.cachedResponse(for: authenticated) == nil)
        #expect(cache.cachedResponse(for: URLRequest(url: server.url("/me"))) == nil)
    }

    @Test("given Authorization in the session's additional headers, when a cacheable GET is sent, then URLCache holds no entry (TM-38)")
    func urlCache_skipsSessionCredentialHeaders() async throws {
        let server = try await LocalHTTPServer.start { request in
            .text("body of \(request.path)", headers: ["Cache-Control": "max-age=600"])
        }
        defer { server.stop() }
        let cache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0)
        let authenticatedConfiguration = URLSessionConfiguration.ephemeral
        authenticatedConfiguration.urlCache = cache
        authenticatedConfiguration.httpAdditionalHeaders = ["Authorization": "Bearer secret"]
        let anonymousConfiguration = URLSessionConfiguration.ephemeral
        anonymousConfiguration.urlCache = cache
        let authenticated = URLRequest(url: server.url("/me"))
        let anonymous = URLRequest(url: server.url("/public"))

        _ = try await URLSessionNetworkService(configuration: authenticatedConfiguration).data(for: authenticated)
        _ = try await URLSessionNetworkService(configuration: anonymousConfiguration).data(for: anonymous)

        #expect(await eventually { cache.cachedResponse(for: anonymous) != nil }, "the control response was never cached")
        #expect(cache.cachedResponse(for: authenticated) == nil)
    }

    // MARK: - Disk Cache

    @Test("given a disk cache, when created, then its directory is excluded from backups")
    func diskCache_excludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let diskCache = DiskCache(directoryURL: directory, sizeLimit: .max, now: { Date() })
        try diskCache.write(CacheEntry(Data("secret".utf8), timestamp: Date()), key: "entry")

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("given a disk cache entry, when written, then it is protected until first user authentication where data protection exists")
    func diskCache_fileProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-protection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diskCache = DiskCache(directoryURL: directory, sizeLimit: .max, now: { Date() })

        try diskCache.write(CacheEntry(Data("secret".utf8), timestamp: Date()), key: "entry")

        #expect(diskCache.read(key: "entry")?.data == Data("secret".utf8))
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let values = try directory.appendingPathComponent("entry").resourceValues(forKeys: [.fileProtectionKey])
        #expect(values.fileProtection == .completeUntilFirstUserAuthentication)
        #endif
    }
}
