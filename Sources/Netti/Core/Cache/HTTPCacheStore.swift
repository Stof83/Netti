//
//  HTTPCacheStore.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/01/26.
//

import Foundation

/// A thread-safe cache store responsible for persisting HTTP responses for offline usage.
///
/// This cache store is designed as an *offline fallback mechanism*, not a freshness cache.
/// Cached data is **never consulted while the device is online** and is only read when
/// the network layer determines that connectivity is unavailable.
///
/// The cache persists data to disk to ensure availability across app launches and
/// optionally mirrors data in memory as an internal optimization.
actor HTTPCacheStore {

    /// An in-memory cache used as a fast-access mirror for disk-backed entries.
    ///
    /// This cache is opportunistic and may be evicted at any time by the system.
    private let memoryCache = NSCache<NSString, CacheEntry>()

    /// A disk-backed cache used to persist responses across app launches.
    private let diskCache: DiskCache

    /// Creates a new cache store with the provided disk cache.
    ///
    /// - Parameter diskCache: The disk-backed cache used to persist responses.
    init(diskCache: DiskCache) {
        self.diskCache = diskCache
    }

    /// Reads cached data for the given key if the request opted into caching.
    ///
    /// This method must only be called when the device is offline.
    /// If the request’s cache policy is `.none`, no cached data is returned.
    ///
    /// - Parameters:
    ///   - key: A deterministic cache key uniquely identifying the request.
    ///
    /// - Returns: Cached response data if available; otherwise `nil`.
    func read(key: String) async throws -> Data? {
        if let data = memoryCache.object(forKey: key as NSString)?.data {
            return data
        } else if let data = try await diskCache.read(Data.self, key: key) {
            return data
        }
        
        return nil
    }

    /// Writes response data to the cache if the request opted into caching.
    ///
    /// This method is typically called after a successful network request
    /// while the device is online.
    ///
    /// - Parameters:
    ///   - data: The raw response data to cache.
    ///   - key: A deterministic cache key uniquely identifying the request.
    func write(_ data: Data, key: String) async throws {
        let entry = CacheEntry(data)
        memoryCache.setObject(entry, forKey: key as NSString)
        try await diskCache.write(data, key: key)
    }
}

