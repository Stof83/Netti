//
//  ServerTrustPolicy.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation
import os
import Security

/// Maps hosts to the evaluator that decides whether their TLS server trust is accepted.
///
/// ```swift
/// let policy = ServerTrustPolicy([
///     "api.example.com": .publicKeys(["hashA=", "hashB="]),
///     "*.cdn.example.com": .pinnedCertificates()
/// ])
/// let netti = Netti(service: URLSessionNetworkService(trustPolicy: policy))
/// ```
///
/// The policy applies to every request and WebSocket the engine opens. A rejected host fails with
/// ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)``.
///
/// Hosts are matched case-insensitively, ignoring a trailing dot. An exact host beats a wildcard.
/// A wildcard `*.example.com` follows RFC 6125: it matches exactly one leftmost label, so it
/// matches `api.example.com` but neither `example.com` nor `a.api.example.com`, and never an IP
/// address. Keys that collide after normalization (`"API.example.com"` and `"api.example.com"`)
/// are combined with ``ServerTrustEvaluator/composite(_:)``, so both must pass.
///
/// Each host whose pinning evaluator has fewer than two pins logs one warning when the policy
/// is created: without a backup pin, rotating the key locks users out. A pinned certificate that
/// is expired or expires within 30 days logs one too; ``pinnedCertificatesExpiring(within:asOf:)``
/// lists them so the app can report them its own way.
///
/// ## Excluding a host
///
/// To keep a host out of pinning, map it to ``ServerTrustEvaluator/default``. It gets the standard
/// system chain and host-name validation, and no pin.
///
/// ```swift
/// let policy = ServerTrustPolicy([
///     "*.example.com": .publicKeys(["hashA=", "hashB="]),
///     "status.example.com": .default,      // vendor-hosted: an exact entry beats the wildcard
///     "maps.googleapis.com": .default      // third-party API: not ours to pin
/// ])
/// ```
///
/// Exclude a host when:
/// - It is a third-party API called through Netti whose certificates you do not control. Pinning it
///   breaks the day the vendor rotates.
/// - It serves presigned storage or CDN URLs, including redirect targets of your own API.
/// - It is a subdomain you want to carve out of a wildcard pin. An exact entry beats the wildcard.
///
/// SDKs that use their own `URLSession` are not affected by this policy.
///
/// An excluded host still fails on an invalid or untrusted certificate: `.default` is not
/// `.disabled`, which exists only in `DEBUG` builds, for example to inspect traffic through a
/// debugging proxy.
///
/// An exclusion is per host, never per path. Trust is evaluated once per TLS connection, and
/// `URLSession` reuses that connection for every path on the host. A per-path exception would
/// either be ignored or leave the whole host unpinned.
///
/// Alternatively, pass `allHostsMustBeEvaluated: false` to give every unlisted host default
/// validation. Listing the excluded hosts explicitly keeps the fail-closed default.
public struct ServerTrustPolicy: ServerTrustEvaluating {

    // MARK: - Constants

    private static let minimumPinCount = 2
    private static let certificateExpiryWarning = Duration.seconds(30 * 24 * 60 * 60)
    private static let wildcardPrefix = "*."
    private static let labelSeparator: Character = "."
    private static let ipv6Separator: Character = ":"

    // MARK: - Properties

    /// When `true`, a host without an entry is rejected; when `false`, it gets ``ServerTrustEvaluator/default`` validation.
    public let allHostsMustBeEvaluated: Bool

    /// The configured hosts (normalized) whose pinning evaluators have fewer than two pins, sorted.
    let hostsMissingBackupPin: [String]

    private let evaluators: [String: ServerTrustEvaluator]

    // MARK: - Initialization

    /// Creates a policy from a host → evaluator map.
    ///
    /// - Parameters:
    ///   - evaluators: Exact hosts (`api.example.com`) or single-label wildcards (`*.example.com`).
    ///   - allHostsMustBeEvaluated: Reject hosts without an entry. Defaults to `true`, so a
    ///     misspelled or forgotten host fails closed instead of silently skipping pinning.
    public init(_ evaluators: [String: ServerTrustEvaluator], allHostsMustBeEvaluated: Bool = true) {
        let normalizedEvaluators = Dictionary(
            evaluators.map { (Self.normalized($0.key), $0.value) },
            uniquingKeysWith: { first, second in .composite([first, second]) }
        )
        self.evaluators = normalizedEvaluators
        self.allHostsMustBeEvaluated = allHostsMustBeEvaluated
        self.hostsMissingBackupPin = normalizedEvaluators
            .filter { $0.value.pinCounts.contains { $0 < Self.minimumPinCount } }
            .keys
            .sorted()
        for host in hostsMissingBackupPin {
            Logger.security.warning("\(host, privacy: .public) has fewer than \(Self.minimumPinCount) pins; add a backup pin so a key rotation does not lock users out")
        }
        for expiry in pinnedCertificatesExpiring(within: Self.certificateExpiryWarning) {
            Logger.security.warning("\(expiry.host, privacy: .public) pins a certificate that \(expiry.isExpired() ? "expired" : "expires", privacy: .public) on \(expiry.notAfter, privacy: .public); ship the renewed certificate in the app before then")
        }
    }

    // MARK: - Expiry

    /// The pinned certificates that are expired or expire within `interval`, soonest first.
    ///
    /// Only certificate pins are checked, such as ``ServerTrustEvaluator/pinnedCertificates(in:subdirectory:performDefaultValidation:)``,
    /// including those inside ``ServerTrustEvaluator/composite(_:)``. A public-key pin has no expiry
    /// of its own, and survives the renewal of its certificate. Pinned data that is not a readable
    /// certificate is skipped.
    ///
    /// Call it once at launch and report what it returns, so a certificate is replaced in the app
    /// before it locks users out:
    ///
    /// ```swift
    /// for expiry in policy.pinnedCertificatesExpiring(within: .seconds(60 * 24 * 60 * 60)) {
    ///     analytics.log("pin expires", host: expiry.host, date: expiry.notAfter)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - interval: How far ahead to look. A certificate that has already expired is always listed.
    ///   - now: The moment to measure from. Defaults to now.
    /// - Returns: One entry per certificate and host, ordered by ``PinnedCertificateExpiry/notAfter``.
    public func pinnedCertificatesExpiring(within interval: Duration, asOf now: Date = Date()) -> [PinnedCertificateExpiry] {
        let horizon = now.addingTimeInterval(interval.timeInterval)
        return evaluators
            .flatMap { host, evaluator in
                evaluator.pinnedCertificates.compactMap { der -> PinnedCertificateExpiry? in
                    guard let notAfter = Certificates.notAfter(ofCertificate: der), notAfter <= horizon else {
                        return nil
                    }
                    let subject = SecCertificateCreateWithData(nil, der as CFData).flatMap { SecCertificateCopySubjectSummary($0) as String? }
                    return PinnedCertificateExpiry(host: host, subject: subject, notAfter: notAfter)
                }
            }
            .sorted { ($0.notAfter, $0.host) < ($1.notAfter, $1.host) }
    }

    // MARK: - Pins

    /// Computes the public-key pin of a certificate: the base64 SHA-256 of its
    /// `SubjectPublicKeyInfo`, the form ``ServerTrustEvaluator/publicKeys(_:performDefaultValidation:)``
    /// expects.
    ///
    /// Use it in a tool or test that reads a certificate and prints its pin, or to check at
    /// launch that a bundled certificate still carries the key you pinned. It matches
    /// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`.
    ///
    /// ```swift
    /// let der = try Data(contentsOf: Bundle.main.url(forResource: "api", withExtension: "cer")!)
    /// let pin = ServerTrustPolicy.publicKeyPin(ofCertificate: der)
    /// ```
    ///
    /// - Parameter der: The certificate in DER form. PEM is not accepted.
    /// - Returns: The pin, or `nil` when `der` is not a well-formed X.509 certificate.
    public static func publicKeyPin(ofCertificate der: Data) -> String? {
        Certificates.certificate(from: der).flatMap { Certificates.publicKeyPin(ofCertificate: $0) }
    }

    /// Computes the public-key pin of a certificate.
    ///
    /// - Parameter certificate: The certificate, for example from a `SecTrust` chain.
    /// - Returns: The pin, or `nil` when the certificate is not a well-formed X.509 certificate.
    public static func publicKeyPin(of certificate: SecCertificate) -> String? {
        Certificates.publicKeyPin(ofCertificate: SecCertificateCopyData(certificate) as Data)
    }

    // MARK: - Evaluation

    /// Evaluates `trust` with the evaluator configured for `host`.
    ///
    /// - Parameters:
    ///   - trust: The server trust from the TLS challenge.
    ///   - host: The host being connected to.
    /// - Throws: ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)`` when the evaluator
    ///   rejects the host, or when the host has no entry and ``allHostsMustBeEvaluated`` is `true`.
    public func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        if let evaluator = evaluator(forHost: host) {
            try evaluator.evaluate(trust, forHost: host)
            return
        }
        if allHostsMustBeEvaluated {
            throw .serverTrustEvaluationFailed(host: host, reason: "no trust evaluator is configured for this host")
        }
        try ServerTrustEvaluator.default.evaluate(trust, forHost: host)
    }

    /// The evaluator for `host`: the exact entry, else the single-label wildcard entry, else `nil`.
    func evaluator(forHost host: String) -> ServerTrustEvaluator? {
        let normalizedHost = Self.normalized(host)
        if let exact = evaluators[normalizedHost] {
            return exact
        }
        return Self.wildcardKey(for: normalizedHost).flatMap { evaluators[$0] }
    }
}

// MARK: - Private Methods

private extension ServerTrustPolicy {
    static func normalized(_ host: String) -> String {
        let lowercased = host.lowercased()
        return lowercased.hasSuffix(String(labelSeparator)) ? String(lowercased.dropLast()) : lowercased
    }

    /// `*.example.com` for `api.example.com`; `nil` for single-label hosts and IP addresses.
    static func wildcardKey(for host: String) -> String? {
        guard isIPAddress(host) == false,
              let separator = host.firstIndex(of: labelSeparator),
              separator != host.startIndex
        else {
            return nil
        }
        let parent = host[host.index(after: separator)...]
        return parent.isEmpty ? nil : wildcardPrefix + parent
    }

    /// IPv6 literals contain `:`; IPv4 literals end in a numeric label, which no DNS TLD does.
    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(ipv6Separator) {
            return true
        }
        let lastLabel = host.split(separator: labelSeparator).last ?? ""
        return lastLabel.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
