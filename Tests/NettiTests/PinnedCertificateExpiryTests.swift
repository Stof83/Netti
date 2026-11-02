import Foundation
import Testing

@testable import Netti

@Suite("Pinned certificate expiry")
struct PinnedCertificateExpiryTests {

    // MARK: - Constants

    private static let day: TimeInterval = 24 * 60 * 60
    private static let thirtyDays = Duration.seconds(30 * 24 * 60 * 60)

    private static func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    private func policy(_ entries: [String: ServerTrustEvaluator]) -> ServerTrustPolicy {
        ServerTrustPolicy(entries, allHostsMustBeEvaluated: false)
    }

    // MARK: - Tests

    @Test("given a certificate that expires inside the interval, when listed, then it is reported with its host, subject and date")
    func expiring_insideInterval_isReported() throws {
        let policy = policy(["api.example.com": .pinnedCertificates([try TrustFixtures.Certificate.rsa2048.der])])
        let now = try Self.date("2028-02-15T00:00:00Z")

        let expiries = policy.pinnedCertificatesExpiring(within: Self.thirtyDays, asOf: now)

        #expect(expiries.map(\.host) == ["api.example.com"])
        #expect(expiries.first?.notAfter == (try Self.date("2028-03-01T00:00:00Z")))
        #expect(expiries.first?.subject != nil)
        #expect(expiries.first?.isExpired(at: now) == false)
    }

    @Test("given a certificate that expires after the interval, when listed, then nothing is reported")
    func expiring_outsideInterval_isNotReported() throws {
        let policy = policy(["api.example.com": .pinnedCertificates([try TrustFixtures.Certificate.rsa2048.der])])

        #expect(policy.pinnedCertificatesExpiring(within: Self.thirtyDays, asOf: TrustFixtures.verifyDate).isEmpty)
        #expect(policy.pinnedCertificatesExpiring(within: .seconds(0), asOf: try Self.date("2028-03-01T00:00:00Z")).count == 1)
    }

    @Test("given an expired certificate, when listed, then it is reported even with a zero interval")
    func expiring_expired_isAlwaysReported() throws {
        let policy = policy(["api.example.com": .pinnedCertificates([try TrustFixtures.Certificate.expired.der])])

        let expiries = policy.pinnedCertificatesExpiring(within: .zero, asOf: TrustFixtures.verifyDate)

        #expect(expiries.count == 1)
        #expect(expiries.first?.isExpired(at: TrustFixtures.verifyDate) == true)
    }

    @Test("given several hosts, wildcards and a composite, when listed, then every certificate pin is reported soonest first")
    func expiring_manyHosts_sortedBySoonest() throws {
        let policy = policy([
            "api.example.com": .pinnedCertificates([try TrustFixtures.Certificate.rsa2048.der]),
            "*.cdn.example.com": .pinnedCertificates([try TrustFixtures.Certificate.expired.der]),
            "legacy.example.com": .composite([.revocation, .pinnedCertificates([try TrustFixtures.Certificate.authority.der])]),
        ])

        let expiries = policy.pinnedCertificatesExpiring(within: .seconds(20 * 365 * 24 * 60 * 60), asOf: TrustFixtures.verifyDate)

        #expect(expiries.map(\.host) == ["*.cdn.example.com", "api.example.com", "legacy.example.com"])
    }

    @Test("given public-key pins and no pins, when listed, then nothing is reported")
    func expiring_publicKeyPins_areIgnored() throws {
        let policy = policy([
            "api.example.com": .publicKeys(["pinA=", "pinB="]),
            "cdn.example.com": .default,
        ])

        #expect(policy.pinnedCertificatesExpiring(within: .seconds(100 * 365 * 24 * 60 * 60), asOf: TrustFixtures.verifyDate).isEmpty)
    }

    @Test("given pinned data that is not a certificate, when listed, then it is skipped")
    func expiring_garbage_isSkipped() throws {
        let policy = policy(["api.example.com": .pinnedCertificates([Data("not a certificate".utf8), try TrustFixtures.Certificate.expired.der])])

        #expect(policy.pinnedCertificatesExpiring(within: .zero, asOf: TrustFixtures.verifyDate).count == 1)
    }
}
