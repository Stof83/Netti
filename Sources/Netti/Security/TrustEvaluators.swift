//
//  TrustEvaluators.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import CryptoKit
import Foundation
import os
import Security

// Concrete evaluators behind the `ServerTrustEvaluator` factories. They store only `Data` and
// value types, never `SecCertificate`/`SecTrust`, so they are `Sendable` without `@unchecked`.

/// An evaluator that checks a host against pins, so the policy can warn about missing backup pins.
protocol PinningTrustEvaluator: ServerTrustEvaluating {
    /// The number of valid, distinct pins configured.
    var pinCount: Int { get }
}

// MARK: - Default

/// Standard chain and host-name validation with the system SSL policy.
struct DefaultTrustEvaluator: ServerTrustEvaluating {
    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        try trust.validate(forHost: host)
    }
}

// MARK: - Revocation

/// Default validation plus a revocation check (OCSP or CRL, whichever is available).
struct RevocationTrustEvaluator: ServerTrustEvaluating {
    /// When `true`, a certificate without a positive revocation response is rejected (hard fail).
    let requirePositiveResponse: Bool

    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        var flags = CFOptionFlags(kSecRevocationUseAnyAvailableMethod)
        if requirePositiveResponse {
            flags |= CFOptionFlags(kSecRevocationRequirePositiveResponse)
        }
        guard let revocationPolicy = SecPolicyCreateRevocation(flags) else {
            throw .serverTrustEvaluationFailed(host: host, reason: "the revocation policy could not be created")
        }
        try trust.validate(forHost: host, additionalPolicies: [revocationPolicy])
    }
}

// MARK: - Public Keys

/// Accepts the host only if a certificate in the chain has a pinned SPKI SHA-256.
///
/// Without default validation, the chain certificates carrying a pinned key become the only
/// anchors and the chain is still evaluated, so a forged leaf next to a genuine pinned certificate
/// fails: chain membership alone proves nothing.
struct PublicKeysTrustEvaluator: PinningTrustEvaluator {
    let pinnedHashes: Set<Data>
    let performDefaultValidation: Bool

    var pinCount: Int {
        pinnedHashes.count
    }

    /// Decodes base64 pins, ignoring (and logging) any that are not a SHA-256 digest.
    init(pins: [String], performDefaultValidation: Bool) {
        let hashes = pins.compactMap { Data(base64Encoded: $0) }.filter { $0.count == SHA256.byteCount }
        if hashes.count < pins.count {
            Logger.security.error("Ignoring \(pins.count - hashes.count) public key pin(s) that are not base64 SHA-256 digests")
        }
        self.pinnedHashes = Set(hashes)
        self.performDefaultValidation = performDefaultValidation
    }

    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        guard performDefaultValidation else {
            let pinned = trust.certificateChain.filter { certificate in
                Certificates.publicKeyHash(ofCertificate: SecCertificateCopyData(certificate) as Data).map(pinnedHashes.contains) == true
            }
            guard pinned.isNotEmpty else {
                throw Self.mismatch(host)
            }
            try trust.validate(anchoredOn: pinned, forHost: host)
            return
        }
        try trust.validate(forHost: host)
        let chainHashes = trust.certificateChainDER.compactMap(Certificates.publicKeyHash(ofCertificate:))
        guard chainHashes.contains(where: pinnedHashes.contains) else {
            throw Self.mismatch(host)
        }
    }

    private static func mismatch(_ host: String) -> HTTPRequestError {
        .serverTrustEvaluationFailed(host: host, reason: "no public key in the certificate chain matches a pinned key")
    }
}

// MARK: - Pinned Certificates

/// Accepts the host only if the chain contains a pinned DER certificate.
///
/// Without default validation, the pinned certificates become the only anchors and the chain is
/// still evaluated, so the server may omit a pinned root but cannot forge a leaf next to it.
struct PinnedCertificatesTrustEvaluator: PinningTrustEvaluator {
    let certificates: Set<Data>
    let performDefaultValidation: Bool

    var pinCount: Int {
        certificates.count
    }

    /// Keeps only well-formed DER certificates, logging any that are not.
    init(certificates: [Data], performDefaultValidation: Bool) {
        let valid = certificates.compactMap(Certificates.certificate(from:))
        if valid.count < certificates.count {
            Logger.security.error("Ignoring \(certificates.count - valid.count) pinned certificate(s) that are not DER certificates")
        }
        self.certificates = Set(valid)
        self.performDefaultValidation = performDefaultValidation
    }

    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        guard performDefaultValidation else {
            let anchors = certificates.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard anchors.isNotEmpty else {
                throw .serverTrustEvaluationFailed(host: host, reason: "no certificate in the chain matches a pinned certificate")
            }
            try trust.validate(anchoredOn: anchors, forHost: host)
            return
        }
        try trust.validate(forHost: host)
        guard trust.certificateChainDER.contains(where: certificates.contains) else {
            throw .serverTrustEvaluationFailed(host: host, reason: "no certificate in the chain matches a pinned certificate")
        }
    }
}

// MARK: - Composite

/// Accepts the host only if every evaluator accepts it; an empty list rejects every host.
struct CompositeTrustEvaluator: ServerTrustEvaluating {
    let evaluators: [ServerTrustEvaluator]

    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        guard evaluators.isNotEmpty else {
            throw .serverTrustEvaluationFailed(host: host, reason: "the composite evaluator has no evaluators")
        }
        for evaluator in evaluators {
            try evaluator.evaluate(trust, forHost: host)
        }
    }
}

// MARK: - Disabled

#if DEBUG
/// Accepts every host without evaluation. Compiled only in DEBUG builds.
struct DisabledTrustEvaluator: ServerTrustEvaluating {
    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {}
}
#endif

// MARK: - SecTrust

extension SecTrust {
    /// Every certificate in the chain, leaf first.
    var certificateChain: [SecCertificate] {
        SecTrustCopyCertificateChain(self) as? [SecCertificate] ?? []
    }

    /// The DER of every certificate in the chain, leaf first.
    var certificateChainDER: [Data] {
        certificateChain.map { SecCertificateCopyData($0) as Data }
    }

    /// Evaluates the chain with the SSL policy for `host`, trusting only `anchors`.
    ///
    /// Signatures, validity dates, CA constraints, the host name and the server-auth key usage are
    /// checked; the system roots are not. A chain that does not lead to one of `anchors` fails.
    ///
    /// The evaluation runs on a new trust built from this trust's chain, verify date and
    /// network-fetch setting, so this trust keeps its own anchors and policies for any later
    /// evaluator (TM-47).
    func validate(anchoredOn anchors: [SecCertificate], forHost host: String) throws(HTTPRequestError) {
        var created: SecTrust?
        let createStatus = SecTrustCreateWithCertificates(certificateChain as CFArray, SecPolicyCreateSSL(true, host as CFString), &created)
        guard createStatus == errSecSuccess, let anchored = created else {
            throw .serverTrustEvaluationFailed(host: host, reason: "the pinned trust could not be created (OSStatus \(createStatus))")
        }
        var statuses = [
            SecTrustSetAnchorCertificates(anchored, anchors as CFArray),
            SecTrustSetAnchorCertificatesOnly(anchored, true),
        ]
        var networkFetchAllowed = DarwinBoolean(true)
        if SecTrustGetNetworkFetchAllowed(self, &networkFetchAllowed) == errSecSuccess {
            statuses.append(SecTrustSetNetworkFetchAllowed(anchored, networkFetchAllowed.boolValue))
        }
        let verifyTime = SecTrustGetVerifyTime(self)
        if verifyTime != 0 {
            statuses.append(SecTrustSetVerifyDate(anchored, Date(timeIntervalSinceReferenceDate: verifyTime) as CFDate))
        }
        if let status = statuses.first(where: { $0 != errSecSuccess }) {
            throw .serverTrustEvaluationFailed(host: host, reason: "the pinned anchors could not be set (OSStatus \(status))")
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(anchored, &error) else {
            let description = error.map { CFErrorCopyDescription($0) as String } ?? "unknown error"
            throw .serverTrustEvaluationFailed(host: host, reason: "the certificate chain does not lead to a pinned certificate for this host: \(description)")
        }
    }

    /// Replaces the policies with the SSL policy for `host` (plus `additionalPolicies`) and evaluates.
    ///
    /// Anchors, verify date and network-fetch settings already on the trust are kept.
    func validate(forHost host: String, additionalPolicies: [SecPolicy] = []) throws(HTTPRequestError) {
        let policies = [SecPolicyCreateSSL(true, host as CFString)] + additionalPolicies
        let status = SecTrustSetPolicies(self, policies as CFArray)
        guard status == errSecSuccess else {
            throw .serverTrustEvaluationFailed(host: host, reason: "the trust policies could not be set (OSStatus \(status))")
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(self, &error) else {
            let description = error.map { CFErrorCopyDescription($0) as String } ?? "unknown error"
            throw .serverTrustEvaluationFailed(host: host, reason: "certificate chain validation failed: \(description)")
        }
    }
}
