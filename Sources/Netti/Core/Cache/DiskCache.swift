//
//  DiskCache.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/01/26.
//

import CryptoKit
import Foundation

/// A disk-backed cache responsible for persisting raw HTTP response data.
///
/// This cache is designed to support **offline fallback** behavior.
/// Cached entries do not expire automatically and are returned only when
/// the network layer determines that the device is offline.
///
/// Data is stored inside the app’s Caches directory and may be evicted
/// by the system under storage pressure.
final class DiskCache: @unchecked Sendable {

    /// The directory where cached files are stored.
    private let directoryURL: URL

    /// The file manager used to read and write cached files.
    private let fileManager: FileManager = .default

    /// Initializes a new disk cache at the specified directory.
    ///
    /// - Parameter directoryName: The directory name used to store cached files.
    init(directoryName: String = "http_cache") {
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directoryURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)

        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    /// Reads cached data from disk if it exists.
    ///
    /// This method performs no expiration or freshness validation and should
    /// only be used when the device is offline.
    ///
    /// - Parameters:
    ///   - type: The expected type of the cached payload.
    ///   - key: The cache key uniquely identifying the request.
    ///
    /// - Returns: Cached data if it exists; otherwise `nil`.
    func read<T>(_ type: T.Type, key: String) async throws -> Data? {
        let url = fileURL(for: key)

        guard
            let data = try? Data(contentsOf: url),
            let entry = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: CacheEntry.self,
                from: data
            )
        else {
            return nil
        }

        return entry.data
    }

    /// Writes cached data to disk.
    ///
    /// - Parameters:
    ///   - data: The raw response data to persist.
    ///   - key: The cache key uniquely identifying the request.
    func write(_ data: Data, key: String) async throws {
        let entry = CacheEntry(data)
        let url = fileURL(for: key)

        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: entry,
            requiringSecureCoding: true
        )

        try archived.write(to: url, options: .atomic)
    }

    /// Generates a deterministic file URL for a given cache key.
    ///
    /// - Parameter key: The cache key.
    /// - Returns: A file URL suitable for disk storage.
    private func fileURL(for key: String) -> URL {
        directoryURL.appendingPathComponent(key.sha256)
    }
}
