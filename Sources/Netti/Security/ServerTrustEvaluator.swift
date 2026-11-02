//
//  ServerTrustEvaluator.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation
import Security

/// A server trust evaluator, created with dot syntax inside a ``ServerTrustPolicy``.
///
/// ```swift
/// let policy = ServerTrustPolicy([
///     "api.example.com": .publicKeys(["hashA=", "hashB="]),
///     "*.cdn.example.com": .pinnedCertificates()
/// ])
/// ```
///
/// Pinning evaluators also run ``default`` validation (chain and host name) unless
/// `performDefaultValidation` is `false`. Prefer ``publicKeys(_:performDefaultValidation:)``:
/// a public-key pin survives certificate renewal as long as the key is reused.
public struct ServerTrustEvaluator: ServerTrustEvaluating {

    // MARK: - Properties

    private let base: any ServerTrustEvaluating

    /// The pin count of every pinning evaluator inside this one, used for the backup-pin warning.
    var pinCounts: [Int] {
        switch base {
            case let pinning as any PinningTrustEvaluator:
                [pinning.pinCount]
            case let composite as CompositeTrustEvaluator:
                composite.evaluators.flatMap(\.pinCounts)
            default:
                []
        }
    }

    /// The DER certificates of every certificate-pinning evaluator inside this one.
    ///
    /// Public-key pins are not listed: they carry no certificate, and survive its renewal.
    var pinnedCertificates: [Data] {
        switch base {
            case let pinning as PinnedCertificatesTrustEvaluator:
                Array(pinning.certificates)
            case let composite as CompositeTrustEvaluator:
                composite.evaluators.flatMap(\.pinnedCertificates)
            default:
                []
        }
    }

    // MARK: - Initialization

    private init(_ base: any ServerTrustEvaluating) {
        self.base = base
    }

    // MARK: - Evaluators

    /// Standard chain and host-name validation with the system SSL policy.
    public static let `default` = ServerTrustEvaluator(DefaultTrustEvaluator())

    /// Default validation plus a soft-fail revocation check (OCSP or CRL, whichever is available).
    public static let revocation = revocation(requirePositiveResponse: false)

    /// Default validation plus a revocation check.
    ///
    /// - Parameter requirePositiveResponse: When `true`, a certificate without a positive
    ///   revocation response is rejected, including when the responder is unreachable.
    /// - Returns: The evaluator.
    public static func revocation(requirePositiveResponse: Bool) -> ServerTrustEvaluator {
        ServerTrustEvaluator(RevocationTrustEvaluator(requirePositiveResponse: requirePositiveResponse))
    }

    /// Accepts the host only if a certificate in the chain has one of the pinned public keys.
    ///
    /// Configure at least two pins (the current key and a backup) so a key rotation does not lock
    /// users out; ``ServerTrustPolicy`` logs a warning otherwise.
    ///
    /// - Parameters:
    ///   - pins: Base64 SHA-256 hashes of the SubjectPublicKeyInfo (RSA or EC), as printed by
    ///     `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`.
    ///     Malformed pins are ignored and logged.
    ///   - performDefaultValidation: Also validate the chain against the system roots and the host
    ///     name. Defaults to `true`. When `false`, the chain certificates carrying a pinned key become
    ///     the only trust anchors and the chain is still evaluated (signatures, validity, host name),
    ///     so a forged leaf next to a genuine pinned certificate, or a leaf issued for another host,
    ///     is rejected; the server must send the certificate carrying the pinned key.
    /// - Returns: The evaluator.
    public static func publicKeys(_ pins: [String], performDefaultValidation: Bool = true) -> ServerTrustEvaluator {
        ServerTrustEvaluator(PublicKeysTrustEvaluator(pins: pins, performDefaultValidation: performDefaultValidation))
    }

    /// Accepts the host only if the chain contains one of the pinned DER certificates.
    ///
    /// - Parameters:
    ///   - certificates: DER-encoded certificates. Invalid entries are ignored and logged.
    ///   - performDefaultValidation: Also validate the chain against the system roots and the host
    ///     name. Defaults to `true`. When `false`, the pinned certificates become the only trust
    ///     anchors and the chain is still evaluated (signatures, validity, host name), so a forged leaf
    ///     next to a genuine pinned certificate, or a leaf issued for another host, is rejected.
    /// - Returns: The evaluator.
    public static func pinnedCertificates(_ certificates: [Data], performDefaultValidation: Bool = true) -> ServerTrustEvaluator {
        ServerTrustEvaluator(PinnedCertificatesTrustEvaluator(certificates: certificates, performDefaultValidation: performDefaultValidation))
    }

    /// Accepts the host only if the chain contains a certificate found in a bundle.
    ///
    /// Every `.cer`, `.der` and `.crt` file holding a DER certificate is loaded once, when the
    /// evaluator is created. A bundle without certificates rejects every host.
    ///
    /// - Parameters:
    ///   - bundle: The bundle to search. Defaults to `Bundle.main`.
    ///   - subdirectory: A directory inside the bundle's resources. Defaults to the top level.
    ///   - performDefaultValidation: Also validate the chain against the system roots and the host
    ///     name. Defaults to `true`. When `false`, the pinned certificates become the only trust
    ///     anchors and the chain is still evaluated (signatures, validity, host name), so a forged leaf
    ///     next to a genuine pinned certificate, or a leaf issued for another host, is rejected.
    /// - Returns: The evaluator.
    public static func pinnedCertificates(
        in bundle: Bundle = .main,
        subdirectory: String? = nil,
        performDefaultValidation: Bool = true
    ) -> ServerTrustEvaluator {
        pinnedCertificates(Certificates.load(in: bundle, subdirectory: subdirectory), performDefaultValidation: performDefaultValidation)
    }

    /// Accepts the host only if every evaluator accepts it, in order. An empty list rejects every host.
    ///
    /// ```swift
    /// "api.example.com": .composite([.revocation, .publicKeys(["hashA=", "hashB="])])
    /// ```
    ///
    /// - Parameter evaluators: The evaluators, run in order until one rejects the host.
    /// - Returns: The evaluator.
    public static func composite(_ evaluators: [ServerTrustEvaluator]) -> ServerTrustEvaluator {
        ServerTrustEvaluator(CompositeTrustEvaluator(evaluators: evaluators))
    }

    /// Wraps a custom ``ServerTrustEvaluating`` implementation.
    ///
    /// - Parameter evaluator: The custom evaluator; a ``ServerTrustEvaluator`` is returned as is.
    /// - Returns: The evaluator.
    public static func custom(_ evaluator: some ServerTrustEvaluating) -> ServerTrustEvaluator {
        if let wrapped = evaluator as? ServerTrustEvaluator {
            return wrapped
        }
        return ServerTrustEvaluator(evaluator)
    }

    #if DEBUG
    /// Accepts every host without any evaluation. Available only in DEBUG builds; never ship it.
    public static let disabled = ServerTrustEvaluator(DisabledTrustEvaluator())
    #endif

    // MARK: - Evaluation

    /// Evaluates `trust` for `host` with the wrapped evaluator.
    ///
    /// - Parameters:
    ///   - trust: The server trust from the TLS challenge.
    ///   - host: The host being connected to.
    /// - Throws: ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)`` when the host is rejected.
    public func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        try base.evaluate(trust, forHost: host)
    }
}
