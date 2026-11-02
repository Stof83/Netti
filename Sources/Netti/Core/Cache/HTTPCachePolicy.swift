//
//  HTTPCachePolicy.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/01/26.
//

import Foundation

/// How an endpoint's responses are cached for offline use.
///
/// Successful (2xx) responses of a caching endpoint are written to disk. They are served instead
/// of a network request only while the device is offline, or when read explicitly with
/// ``Netti/cachedResponse(for:method:parameters:)``.
///
/// ```swift
/// var cachePolicy: HTTPCachePolicy { .cache(maxAge: .seconds(3600)) }
/// ```
public struct HTTPCachePolicy: Sendable, Equatable {

    // MARK: - Properties

    /// Whether responses are cached.
    public let isCaching: Bool

    /// How long an entry stays valid; `nil` keeps it until it is evicted or cleared.
    public let maxAge: Duration?

    // MARK: - Policies

    /// The response is never cached and has no offline fallback.
    public static let none = HTTPCachePolicy(isCaching: false, maxAge: nil)

    /// The response is cached with no expiry and served while the device is offline.
    public static let cache = HTTPCachePolicy(isCaching: true, maxAge: nil)

    /// The response is cached and served while the device is offline, for at most `maxAge`.
    ///
    /// - Parameter maxAge: How long an entry stays valid after it is written.
    /// - Returns: The policy.
    public static func cache(maxAge: Duration) -> HTTPCachePolicy {
        HTTPCachePolicy(isCaching: true, maxAge: maxAge)
    }
}
