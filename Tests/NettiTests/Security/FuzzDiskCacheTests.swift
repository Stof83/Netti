//
//  FuzzDiskCacheTests.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/10/26.
//

import Foundation
import NettiTesting
import Testing

@testable import Netti

/// Seeded fuzzing of tampered cache entries (TM-31): random bytes, mutated archives, truncated,
/// empty and oversized files in a client's cache directory never trap; random bytes, truncation
/// and empty files read as a miss, and a client reading them serves the network or a typed error.
@Suite("Fuzz: disk cache entries", .timeLimit(.minutes(30)))
struct FuzzDiskCacheTests {

    // MARK: - Disk Cache

    /// Multiplier 0.5 (minimum 50): every case writes and corrupts a file.
    @Test("given a cache file replaced by random, mutated, truncated or empty bytes, when read, then it never traps and garbage is a miss")
    func corruptedFile_readsAsMissOrEntry() async {
        let iterations = Fuzz.iterations(multiplier: 0.5, minimum: 50)

        await Fuzz.run("cache.file", iterations: iterations) { fuzz in
            let directory = makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = String(format: "%016llx", fuzz.random.next())
            let disk = DiskCache(directoryURL: directory, sizeLimit: DiskCache.defaultSizeLimit, now: { Date() })
            let payload = fuzz.random.bytes(count: fuzz.random.length(upTo: 2_048))
            do {
                try disk.write(CacheEntry(payload), key: key)
            } catch {
                fuzz.fail("could not seed the entry: \(error)")
                return
            }

            let corruption = Corruption.random(using: &fuzz.random, allowsHuge: false)
            corruption.apply(to: directory.appendingPathComponent(key), using: &fuzz.random)
            fuzz.input = "corruption=\(corruption) payload=\(payload.count) B"

            let fromDisk = DiskCache(directoryURL: directory, sizeLimit: DiskCache.defaultSizeLimit, now: { Date() }).read(key: key)
            let fromStore = await HTTPCacheStore(diskCache: disk).read(key: key)
            if corruption.mustMiss {
                fuzz.check(fromDisk == nil, "DiskCache served a \(corruption) entry")
                fuzz.check(fromStore == nil, "HTTPCacheStore served a \(corruption) entry")
            }
        }
    }

    /// Multiplier 0.002 (minimum 3): every case writes a file of several megabytes.
    @Test("given a cache file replaced by megabytes of random bytes, when read, then it is a miss")
    func hugeGarbageFile_isMiss() async {
        let iterations = Fuzz.iterations(multiplier: 0.002, minimum: 3)

        await Fuzz.run("cache.huge", iterations: iterations, timeLimitPerCase: .seconds(20)) { fuzz in
            let directory = makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let disk = DiskCache(directoryURL: directory, sizeLimit: DiskCache.defaultSizeLimit, now: { Date() })
            let key = "entry"
            _ = try? disk.write(CacheEntry(Data("seed".utf8)), key: key)

            let corruption = Corruption.huge(fuzz.random.int(2_000_000...8_000_000))
            corruption.apply(to: directory.appendingPathComponent(key), using: &fuzz.random)
            fuzz.input = "corruption=\(corruption)"

            fuzz.check(disk.read(key: key) == nil, "served megabytes of random bytes as an entry")
        }
    }

    // MARK: - Client

    /// Multiplier 0.1 (minimum 30): every case runs two clients against one cache directory.
    /// The per-case bound is wide for the same reason as the header send suite: at 100k iterations the
    /// CPU-bound suites beside it can delay its actor hops by a minute.
    @Test("given a client whose cache files were corrupted, when it reads the cache or goes offline, then it misses or fails typed, never traps")
    func corruptedClientCache_missesOrFailsTyped() async {
        let iterations = Fuzz.iterations(multiplier: 0.1, minimum: 30)

        await Fuzz.run("cache.client", iterations: iterations, timeLimitPerCase: .seconds(180)) { fuzz in
            let directory = makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = StubNetworkService { try .json(for: $0, Widget(id: 7, name: "fresh")) }
            var endpoint = TestEndpoint()
            endpoint.cachePolicy = .cache

            let writer = makeNetti(service: service, cacheStore: makeStore(directory))
            do throws(HTTPRequestError) {
                let _: HTTPResponse<Widget> = try await writer.get(endpoint)
            } catch {
                fuzz.fail("could not seed the cache: \(error)")
                return
            }

            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            fuzz.check(files.isEmpty == false, "no cache file was written")
            let corruption = Corruption.random(using: &fuzz.random, allowsHuge: false)
            for file in files {
                corruption.apply(to: file, using: &fuzz.random)
            }
            fuzz.input = "corruption=\(corruption) files=\(files.count)"

            let connectivity = StubConnectivity(.disconnected)
            let reader = makeNetti(service: service, connectivity: connectivity, cacheStore: makeStore(directory))
            let cached: HTTPResponse<Widget>? = await reader.cachedResponse(for: endpoint)
            if corruption.mustMiss {
                fuzz.check(cached == nil, "served a \(corruption) entry from the cache")
            }

            // Offline, a cached entry is served without the network; garbage must fall through to it.
            do throws(HTTPRequestError) {
                let response: HTTPResponse<Widget> = try await reader.get(endpoint)
                if corruption.mustMiss {
                    fuzz.check(response.data == Widget(id: 7, name: "fresh"), "offline read served \(String(describing: response.data))")
                }
            } catch {
                fuzz.check(corruption.mustMiss == false, "a \(corruption) entry failed the offline read: \(error)")
                guard case .decodingFailed = error else {
                    fuzz.fail("offline read of a tampered entry threw \(error), not decodingFailed")
                    return
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-fuzz-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStore(_ directory: URL) -> HTTPCacheStore {
        HTTPCacheStore(diskCache: DiskCache(directoryURL: directory, sizeLimit: DiskCache.defaultSizeLimit, now: { Date() }))
    }
}

// MARK: - Corruption

private enum Corruption: CustomStringConvertible {
    /// Random bytes that do not start with a property-list header.
    case randomBytes(Int)
    /// The archive with one to four mutations; it may still decode to some entry.
    case mutatedArchive(Int)
    case truncated
    case empty
    /// The file replaced by a directory.
    case directory
    case huge(Int)

    static func random(using random: inout SeededRandom, allowsHuge: Bool) -> Corruption {
        switch random.int(0...9) {
            case 0...2:
                .randomBytes(random.length(upTo: 4_096))
            case 3...6:
                .mutatedArchive(random.int(1...4))
            case 7:
                .truncated
            case 8:
                .empty
            default:
                allowsHuge ? .huge(random.int(2_000_000...8_000_000)) : .directory
        }
    }

    /// Whether the spec makes the corrupted entry a miss; a mutated archive may legitimately decode.
    var mustMiss: Bool {
        if case .mutatedArchive = self {
            return false
        }
        return true
    }

    func apply(to file: URL, using random: inout SeededRandom) {
        let fileManager = FileManager.default
        let original = (try? Data(contentsOf: file)) ?? Data()
        let replacement: Data
        switch self {
            case .randomBytes(let count):
                var bytes = random.bytes(count: count)
                if bytes.starts(with: Data("bplist".utf8)) {
                    bytes[bytes.startIndex] = 0
                }
                replacement = bytes
            case .mutatedArchive(let count):
                replacement = random.mutate(original, times: count)
            case .truncated:
                replacement = original.prefix(random.int(0...max(0, original.count - 1)))
            case .empty:
                replacement = Data()
            case .directory:
                try? fileManager.removeItem(at: file)
                try? fileManager.createDirectory(at: file, withIntermediateDirectories: false)
                return
            case .huge(let count):
                replacement = random.bytes(count: count)
        }
        try? replacement.write(to: file)
    }

    var description: String {
        switch self {
            case .randomBytes(let count):
                "randomBytes(\(count))"
            case .mutatedArchive(let count):
                "mutatedArchive(\(count))"
            case .truncated:
                "truncated"
            case .empty:
                "empty"
            case .directory:
                "directory"
            case .huge(let count):
                "huge(\(count))"
        }
    }
}
