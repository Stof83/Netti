//
//  HTTPCacheStore.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/01/26.
//

import Foundation

/// A thread-safe cache of HTTP response data for offline use.
///
/// Entries persist on disk across launches and are mirrored in memory. Every call is serialized by
/// the actor, so a write is visible to the next read as soon as `write` returns.
actor HTTPCacheStore {

    // MARK: - Properties

    /// An opportunistic in-memory mirror of disk entries; the system may evict it at any time.
    private let memoryCache = NSCache<NSString, CacheEntry>()

    /// The disk-backed cache that persists entries across launches.
    private let diskCache: DiskCache

    private let now: @Sendable () -> Date

    // MARK: - Initialization

    /// Creates a cache store.
    ///
    /// - Parameters:
    ///   - diskCache: The disk-backed cache.
    ///   - now: The clock used to date entries and check their age; injected by tests.
    init(diskCache: DiskCache, now: @escaping @Sendable () -> Date = { Date() }) {
        self.diskCache = diskCache
        self.now = now
    }

    // MARK: - Entries

    /// Reads the data cached for `key`.
    ///
    /// - Parameters:
    ///   - key: The cache key.
    ///   - maxAge: How old the entry may be; `nil` accepts any age.
    /// - Returns: The cached data, or `nil` when there is no entry or it is older than `maxAge`.
    func read(key: String, maxAge: Duration? = nil) -> Data? {
        let entry: CacheEntry
        if let memoryEntry = memoryCache.object(forKey: key as NSString) {
            diskCache.touch(key: key)
            entry = memoryEntry
        } else if let diskEntry = diskCache.read(key: key) {
            memoryCache.setObject(diskEntry, forKey: key as NSString)
            entry = diskEntry
        } else {
            return nil
        }

        if let maxAge, now().timeIntervalSince(entry.timestamp) > maxAge.timeInterval {
            return nil
        }
        return entry.data
    }

    /// Caches `data` for `key`, evicting least recently used entries past the size limit.
    ///
    /// - Parameters:
    ///   - data: The raw response data.
    ///   - key: The cache key.
    /// - Throws: The file system error when the entry cannot be written.
    func write(_ data: Data, key: String) throws {
        let entry = CacheEntry(data, timestamp: now())
        let evicted = try diskCache.write(entry, key: key)
        memoryCache.setObject(entry, forKey: key as NSString)
        for evictedKey in evicted {
            memoryCache.removeObject(forKey: evictedKey as NSString)
        }
    }

    /// Removes the entry for `key`; does nothing when there is none.
    ///
    /// - Throws: The file system error when the entry cannot be removed.
    func remove(key: String) throws {
        memoryCache.removeObject(forKey: key as NSString)
        try diskCache.remove(key: key)
    }

    /// Removes every entry.
    ///
    /// - Throws: The file system error when an entry cannot be removed.
    func clearAll() throws {
        memoryCache.removeAllObjects()
        try diskCache.removeAll()
    }
}

extension Duration {
    /// The duration in seconds.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
