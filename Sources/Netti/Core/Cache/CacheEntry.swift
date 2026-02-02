//
//  CacheEntry.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/01/26.
//

import Foundation

/// A cached value wrapper storing raw HTTP response data.
///
/// `CacheEntry` is a lightweight container used by both memory and disk caches
/// to persist response payloads. It is intentionally simple and does not apply
/// any expiration logic on its own.
///
/// Cache invalidation and offline usage decisions are delegated to higher-level
/// cache policies in the networking layer.
final class CacheEntry: NSObject, NSSecureCoding {

    /// Indicates that the cache entry supports secure coding.
    static var supportsSecureCoding: Bool { true }

    /// The raw cached response data.
    let data: Data

    /// The timestamp representing when the data was cached.
    let timestamp: Date

    /// Initializes a new cache entry.
    ///
    /// - Parameters:
    ///   - data: The raw response data to cache.
    ///   - timestamp: The creation date of the cache entry.
    ///                Defaults to the current date.
    init(_ data: Data, timestamp: Date = .init()) {
        self.data = data
        self.timestamp = timestamp
    }

    /// Initializes a cache entry from a decoder.
    ///
    /// - Parameter coder: The decoder to read data from.
    required init?(coder: NSCoder) {
        guard
            let data = coder.decodeObject(of: NSData.self, forKey: "data") as Data?,
            let timestamp = coder.decodeObject(of: NSDate.self, forKey: "timestamp") as Date?
        else {
            return nil
        }

        self.data = data
        self.timestamp = timestamp
    }

    /// Encodes the cache entry into the provided coder.
    ///
    /// - Parameter coder: The coder used to encode the cache entry.
    func encode(with coder: NSCoder) {
        coder.encode(data as NSData, forKey: "data")
        coder.encode(timestamp as NSDate, forKey: "timestamp")
    }

    /// Returns the cached data.
    ///
    /// This method performs no freshness or expiration checks and is intended
    /// to be used only when the application is operating in offline mode.
    ///
    /// - Returns: The cached response data.
    func value() -> Data {
        data
    }
}

