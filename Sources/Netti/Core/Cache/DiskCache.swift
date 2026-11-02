//
//  DiskCache.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/01/26.
//

import Foundation

/// A disk-backed cache of raw HTTP response data, kept under a size limit.
///
/// Each entry is one file in the app's Caches directory, named by its key. A file's modification
/// date records when the entry was last used, so the least recently used entries are evicted
/// first once the directory grows past ``sizeLimit``. The system may also purge the directory
/// under storage pressure.
///
/// The directory is excluded from backups, and on iOS, tvOS, watchOS and visionOS each entry is
/// written with `completeUntilFirstUserAuthentication` file protection.
///
/// Not thread-safe: ``HTTPCacheStore`` is its only user and serializes every call.
final class DiskCache: @unchecked Sendable {

    // MARK: - Constants

    /// The default size limit: 50 MB.
    static let defaultSizeLimit = 50 * 1024 * 1024

    /// How entries are written: atomically, and protected where the platform has data protection.
    private static let writingOptions: Data.WritingOptions = {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        .atomic
        #endif
    }()

    // MARK: - Properties

    /// The most bytes the cache files may take together.
    let sizeLimit: Int

    private let directoryURL: URL
    private let fileManager: FileManager = .default
    private let now: @Sendable () -> Date

    // MARK: - Initialization

    /// Creates a disk cache in a directory of the Caches directory.
    ///
    /// - Parameters:
    ///   - directoryName: The directory name.
    ///   - sizeLimit: The most bytes the cache may take. Defaults to ``defaultSizeLimit``.
    ///   - now: The clock that dates entry use; injected by tests.
    convenience init(
        directoryName: String = "http_cache",
        sizeLimit: Int = DiskCache.defaultSizeLimit,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.init(directoryURL: baseURL.appendingPathComponent(directoryName, isDirectory: true), sizeLimit: sizeLimit, now: now)
    }

    /// Creates a disk cache in `directoryURL`.
    init(directoryURL: URL, sizeLimit: Int, now: @escaping @Sendable () -> Date) {
        self.directoryURL = directoryURL
        self.sizeLimit = max(0, sizeLimit)
        self.now = now

        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        excludeFromBackup()
    }

    // MARK: - Entries

    /// Reads the entry for `key` and marks it as recently used.
    ///
    /// - Parameter key: The cache key.
    /// - Returns: The entry, or `nil` when there is none or it cannot be read.
    func read(key: String) -> CacheEntry? {
        let url = fileURL(for: key)
        guard
            let data = try? Data(contentsOf: url),
            let entry = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CacheEntry.self, from: data)
        else {
            return nil
        }
        touch(url)
        return entry
    }

    /// Marks the entry for `key` as recently used, when it exists.
    func touch(key: String) {
        touch(fileURL(for: key))
    }

    /// Writes `entry` for `key`, then evicts least recently used entries until the cache fits its limit.
    ///
    /// - Parameters:
    ///   - entry: The entry to persist.
    ///   - key: The cache key.
    /// - Returns: The keys of the evicted entries; `key` itself when the entry alone exceeds the limit.
    /// - Throws: The file system error when the entry cannot be written.
    @discardableResult
    func write(_ entry: CacheEntry, key: String) throws -> [String] {
        let url = fileURL(for: key)
        let archived = try NSKeyedArchiver.archivedData(withRootObject: entry, requiringSecureCoding: true)
        try archived.write(to: url, options: Self.writingOptions)
        touch(url)
        return trim()
    }

    /// Removes the entry for `key`; does nothing when there is none.
    ///
    /// - Throws: The file system error when the file exists but cannot be removed.
    func remove(key: String) throws {
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Removes every entry.
    ///
    /// - Throws: The file system error when an entry cannot be removed.
    func removeAll() throws {
        let contents = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }

    /// The bytes the cache files take together.
    var totalSize: Int {
        files().reduce(0) { $0 + $1.size }
    }
}

// MARK: - Private Helpers

private extension DiskCache {
    struct CachedFile {
        let url: URL
        let size: Int
        let lastUsed: Date
    }

    /// Keeps the directory, and so every entry in it, out of iCloud, device and Time Machine backups.
    func excludeFromBackup() {
        var directoryURL = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(values)
    }

    func fileURL(for key: String) -> URL {
        directoryURL.appendingPathComponent(key)
    }

    func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
    }

    func files() -> [CachedFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                return nil
            }
            return CachedFile(url: url, size: values.fileSize ?? 0, lastUsed: values.contentModificationDate ?? .distantPast)
        }
    }

    /// Evicts least recently used files until the total fits ``sizeLimit``.
    func trim() -> [String] {
        let files = files()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > sizeLimit else {
            return []
        }
        var evicted: [String] = []
        for file in files.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > sizeLimit {
            guard (try? fileManager.removeItem(at: file.url)) != nil else {
                continue
            }
            total -= file.size
            evicted.append(file.url.lastPathComponent)
        }
        return evicted
    }
}
