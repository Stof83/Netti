import Foundation
import Security
import Testing

@testable import Netti

@Suite("ServerTrustPolicy")
struct ServerTrustPolicyTests {
    private typealias Fixture = TrustFixtures.Certificate

    private let host = TrustFixtures.host
    private let mismatchingPins = [Fixture.unrelated.expectedPin, Fixture.p384.expectedPin]

    // MARK: - Configuration

    @Test("given the common case, when configured in one line, then it compiles with dot syntax")
    func init_oneLiner_compiles() {
        let policy = ServerTrustPolicy(["api.example.com": .publicKeys(["hashA=", "hashB="]), "*.cdn.example.com": .pinnedCertificates()])

        #expect(policy.allHostsMustBeEvaluated)
        #expect(policy.evaluator(forHost: "img.cdn.example.com") != nil)
    }

    @Test("given hosts with fewer than two pins, when configured, then they are reported as missing a backup pin")
    func init_reportsHostsMissingBackupPin() {
        let policy = ServerTrustPolicy([
            "single.example.com": .publicKeys([Fixture.p256.expectedPin]),
            "backed-up.example.com": .publicKeys([Fixture.p256.expectedPin, Fixture.unrelated.expectedPin]),
            "composite.example.com": .composite([.revocation, .publicKeys([Fixture.p256.expectedPin])]),
            "*.empty.example.com": .pinnedCertificates([]),
            "unpinned.example.com": .default,
        ])

        #expect(policy.hostsMissingBackupPin == ["*.empty.example.com", "composite.example.com", "single.example.com"])
    }

    // MARK: - Host Matching

    @Test("given a wildcard pin, when a subdomain is evaluated, then the wildcard evaluator is applied")
    func evaluate_wildcardHost_appliesWildcardEvaluator() throws {
        let rejecting = ServerTrustPolicy(["*.example.com": .publicKeys(mismatchingPins)])
        let accepting = ServerTrustPolicy(["*.example.com": .publicKeys([Fixture.p256.expectedPin, Fixture.unrelated.expectedPin])])

        let trust = try TrustFixtures.trust([.p256])

        let reason = expectTrustFailure { () throws(HTTPRequestError) in try rejecting.evaluate(trust, forHost: host) }
        #expect(reason?.contains("pinned") == true)
        try accepting.evaluate(trust, forHost: host)
    }

    @Test("given exact and wildcard entries, when the exact host is evaluated, then the exact evaluator wins")
    func evaluate_exactHostWinsOverWildcard() throws {
        let policy = ServerTrustPolicy([
            "api.example.com": .publicKeys([Fixture.p256.expectedPin, Fixture.unrelated.expectedPin]),
            "*.example.com": .publicKeys(mismatchingPins),
        ])

        try policy.evaluate(try TrustFixtures.trust([.p256]), forHost: host)
    }

    @Test(
        "given a wildcard entry, when the host is the apex or a deeper subdomain, then it does not match",
        arguments: ["example.com", "a.api.example.com", "apiexample.com", "api.example.com.evil.net"]
    )
    func evaluator_wildcardMatchesSingleLabelOnly(candidate: String) {
        let policy = ServerTrustPolicy(["*.example.com": .default])

        #expect(policy.evaluator(forHost: candidate) == nil)
    }

    @Test("given mixed case and a trailing dot, when looked up, then hosts match case-insensitively")
    func evaluator_normalizesHosts() {
        let policy = ServerTrustPolicy(["API.Example.com": .default, "*.CDN.example.com": .default])

        #expect(policy.evaluator(forHost: "api.example.COM.") != nil)
        #expect(policy.evaluator(forHost: "Img.cdn.example.com") != nil)
    }

    @Test("given an IP address host, when looked up, then wildcard entries never match it")
    func evaluator_ipAddress_skipsWildcard() {
        let policy = ServerTrustPolicy(["*.0.0.1": .default, "*.db8::1": .default])

        #expect(policy.evaluator(forHost: "127.0.0.1") == nil)
        #expect(policy.evaluator(forHost: "2001:db8::1") == nil)
    }

    @Test("given two keys for the same host differing only in case, when evaluated, then both must pass")
    func init_duplicateHosts_requireBoth() throws {
        let policy = ServerTrustPolicy([
            "api.example.com": .publicKeys([Fixture.p256.expectedPin, Fixture.unrelated.expectedPin]),
            "API.EXAMPLE.COM": .publicKeys(mismatchingPins),
        ])
        let trust = try TrustFixtures.trust([.p256])

        expectTrustFailure { () throws(HTTPRequestError) in try policy.evaluate(trust, forHost: host) }
    }

    // MARK: - Unlisted Hosts

    @Test("given strict mode, when an unlisted host is evaluated, then it throws naming that host")
    func evaluate_strictUnlistedHost_throws() throws {
        let policy = ServerTrustPolicy(["other.example.net": .default])
        let trust = try TrustFixtures.trust([.p256])

        #expect(policy.allHostsMustBeEvaluated)
        let reason = expectTrustFailure { () throws(HTTPRequestError) in try policy.evaluate(trust, forHost: host) }
        #expect(reason?.contains("no trust evaluator") == true)
    }

    @Test("given non-strict mode, when an unlisted host is evaluated, then default validation applies")
    func evaluate_lenientUnlistedHost_usesDefault() throws {
        let policy = ServerTrustPolicy(["other.example.net": .publicKeys(mismatchingPins)], allHostsMustBeEvaluated: false)

        let expiredTrust = try TrustFixtures.trust([.expired])

        try policy.evaluate(try TrustFixtures.trust([.p256]), forHost: host)
        expectTrustFailure { () throws(HTTPRequestError) in try policy.evaluate(expiredTrust, forHost: host) }
    }
}
