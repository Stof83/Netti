import Foundation
import Security
import Testing

@testable import Netti

/// DER fixtures from `Resources/Certificates` (see `Resources/README.md`) and a builder for
/// offline, deterministic `SecTrust` objects anchored on the test CA.
enum TrustFixtures {

    // MARK: - Types

    enum Certificate: String, CaseIterable, CustomTestStringConvertible {
        case authority = "ca.cer"
        case rsa2048 = "leaf-rsa2048.cer"
        case rsa4096 = "leaf-rsa4096.cer"
        case p256 = "leaf-p256.cer"
        case p384 = "leaf-p384.cer"
        case expired = "leaf-expired.cer"
        case otherHost = "leaf-other-host.cer"
        case unrelated = "unrelated.der"
        /// `api.example.com`, issuer name `Netti Test Root CA`, but signed by another key.
        case forgedIssuer = "leaf-forged-issuer.cer"

        static let validLeaves: [Certificate] = [.rsa2048, .rsa4096, .p256, .p384]

        /// The base64 SPKI SHA-256 computed by `openssl` (see `generate-fixtures.sh`).
        var expectedPin: String {
            switch self {
                case .authority: "eoQZ9PerkFsmQ2Ih3njXWVk4+QYfniABdkOMRCkTrys="
                case .rsa2048: "34ujpoov2icMePbP1Jf8TDHQBT6/XKjsa5YuEFbz1MU="
                case .rsa4096: "lbyITytMlRwjtfK/PiB8Ih1Ev/zX0wvx9zQJ3Q+N3Bo="
                case .p256: "vFzo9rMWlmH3bW6NPQM8oFmsF0J8fXVBGCP5gRmRwdQ="
                case .p384: "9E7LRUikpeqiXteMkSnxksfFDorFulCGpPOq7ZocBbM="
                case .expired: "koV5WFrU9WR4xynKAE4fEqrUbsvaeaOfjrTk1wc7tJU="
                case .otherHost: "L1dAWhPR1IkiQPr/qYDr5JlX/kYjpJEAs/zZa8guTOo="
                case .unrelated: "0ZxBLg7bxXuWmr5z6dkie4jYSFsYWCU6FUXghfipTsw="
                case .forgedIssuer: "Da4qKtuVMopitm62tYIOjqdGHmUleNYjzPv/iE9b6lQ="
            }
        }

        /// The `notAfter` computed by `openssl x509 -enddate` (see `generate-fixtures.sh`), as ISO 8601.
        var expectedNotAfter: String {
            switch self {
                case .authority: "2040-01-01T00:00:00Z"
                case .expired: "2025-01-01T00:00:00Z"
                case .rsa2048, .rsa4096, .p256, .p384, .otherHost, .unrelated, .forgedIssuer: "2028-03-01T00:00:00Z"
            }
        }

        var url: URL {
            get throws {
                try #require(Bundle.module.url(forResource: rawValue, withExtension: nil, subdirectory: TrustFixtures.subdirectory))
            }
        }

        var der: Data {
            get throws {
                try Data(contentsOf: url)
            }
        }

        var testDescription: String {
            rawValue
        }
    }

    // MARK: - Constants

    static let host = "api.example.com"
    static let subdirectory = "Resources/Certificates"

    /// Inside every valid leaf's window (2026-01-01 → 2028-03-01), after the expired leaf's.
    static let verifyDate = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z") ?? .distantPast

    // MARK: - Trust

    /// Builds a `SecTrust` for `chain` anchored only on the test CA, evaluated at `date`, offline.
    ///
    /// With `anchoredOnTestCA` false the trust keeps the system anchors, as a real TLS challenge
    /// does, so the test CA is not trusted unless an evaluator anchors it.
    static func trust(_ chain: [Certificate], at date: Date = verifyDate, anchoredOnTestCA: Bool = true) throws -> SecTrust {
        let certificates = try chain.map(secCertificate)
        var trust: SecTrust?
        try #require(SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let builtTrust = try #require(trust)
        if anchoredOnTestCA {
            let anchor = try secCertificate(.authority)
            try #require(SecTrustSetAnchorCertificates(builtTrust, [anchor] as CFArray) == errSecSuccess)
            try #require(SecTrustSetAnchorCertificatesOnly(builtTrust, true) == errSecSuccess)
        }
        try #require(SecTrustSetVerifyDate(builtTrust, date as CFDate) == errSecSuccess)
        try #require(SecTrustSetNetworkFetchAllowed(builtTrust, false) == errSecSuccess)
        return builtTrust
    }

    private static func secCertificate(_ certificate: Certificate) throws -> SecCertificate {
        try #require(SecCertificateCreateWithData(nil, try certificate.der as CFData))
    }
}

/// Asserts that `body` throws `serverTrustEvaluationFailed` for `host` and returns its reason.
@discardableResult
func expectTrustFailure(
    host: String = TrustFixtures.host,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws(HTTPRequestError) -> Void
) -> String? {
    do {
        try body()
        Issue.record("Expected serverTrustEvaluationFailed, but evaluation passed", sourceLocation: sourceLocation)
    } catch {
        guard case .serverTrustEvaluationFailed(let failedHost, let reason) = error else {
            Issue.record("Expected serverTrustEvaluationFailed, got \(error)", sourceLocation: sourceLocation)
            return nil
        }
        #expect(failedHost == host, sourceLocation: sourceLocation)
        return reason
    }
    return nil
}
