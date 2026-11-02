//
//  PinnedCertificateExpiry.swift
//  Netti
//

import Foundation

/// A pinned certificate that is expired or about to expire, as reported by
/// ``ServerTrustPolicy/pinnedCertificatesExpiring(within:asOf:)``.
public struct PinnedCertificateExpiry: Sendable, Hashable {
    /// The host or wildcard the certificate is pinned for, lowercased, as configured in the policy.
    public let host: String

    /// The certificate's subject summary, usually its common name; `nil` when it has none.
    public let subject: String?

    /// When the certificate stops being valid.
    public let notAfter: Date

    /// Whether the certificate has expired at `date`. Defaults to now.
    ///
    /// - Parameter date: The moment to check.
    public func isExpired(at date: Date = Date()) -> Bool {
        notAfter <= date
    }
}
