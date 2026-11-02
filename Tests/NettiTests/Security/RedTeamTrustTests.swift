//
//  RedTeamTrustTests.swift
//  Netti
//

import Foundation
import Security
import Testing

@testable import Netti

/// S.12 red team, server trust (TM-02, TM-34): an attacker who controls the network and holds a
/// certificate of their choosing must never get a pinned host accepted.
///
/// With default validation on, trusts are anchored on the test CA, the strongest attacker: the CA
/// is trusted, so only the pin, the date or the host name can stop the attack. With it off, trusts
/// keep the system anchors, as a real TLS challenge does, and the pins are the only anchors.
@Suite("Red team: server trust")
struct RedTeamTrustTests {
    typealias Fixture = TrustFixtures.Certificate

    // MARK: - Types

    struct Attack: CustomTestStringConvertible, Sendable {
        let name: String
        let chain: [Fixture]
        let evaluator: @Sendable (Bool) throws -> ServerTrustEvaluator

        var testDescription: String {
            name
        }
    }

    // MARK: - Constants

    private static let validation = [true, false]

    private static let attacks: [Attack] = [
        Attack(name: "wrong key pin", chain: [.p256, .authority]) {
            .publicKeys([Fixture.unrelated.expectedPin, Fixture.otherHost.expectedPin], performDefaultValidation: $0)
        },
        Attack(name: "wrong certificate pin", chain: [.p256, .authority]) {
            .pinnedCertificates([try Fixture.unrelated.der, try Fixture.otherHost.der], performDefaultValidation: $0)
        },
        Attack(name: "expired leaf, its own key pinned", chain: [.expired, .authority]) {
            .publicKeys([Fixture.expired.expectedPin, Fixture.p384.expectedPin], performDefaultValidation: $0)
        },
        Attack(name: "expired leaf, CA key pinned", chain: [.expired, .authority]) {
            .publicKeys([Fixture.authority.expectedPin, Fixture.p384.expectedPin], performDefaultValidation: $0)
        },
        Attack(name: "expired leaf, its certificate pinned", chain: [.expired, .authority]) {
            .pinnedCertificates([try Fixture.expired.der], performDefaultValidation: $0)
        },
        Attack(name: "other-host leaf from the pinned CA, api leaf key pinned", chain: [.otherHost, .authority]) {
            .publicKeys([Fixture.p256.expectedPin, Fixture.p384.expectedPin], performDefaultValidation: $0)
        },
        Attack(name: "unrelated self-signed, api keys pinned", chain: [.unrelated]) {
            .publicKeys([Fixture.p256.expectedPin, Fixture.authority.expectedPin], performDefaultValidation: $0)
        },
        Attack(name: "unrelated self-signed, CA certificate pinned", chain: [.unrelated]) {
            .pinnedCertificates([try Fixture.authority.der], performDefaultValidation: $0)
        },
        Attack(name: "forged issuer + genuine CA appended, CA key pinned", chain: [.forgedIssuer, .authority]) {
            .publicKeys([Fixture.authority.expectedPin, Fixture.p384.expectedPin], performDefaultValidation: $0)
        },
        Attack(name: "forged issuer + genuine CA appended, CA certificate pinned", chain: [.forgedIssuer, .authority]) {
            .pinnedCertificates([try Fixture.authority.der], performDefaultValidation: $0)
        },
        Attack(name: "self-signed leaf + genuine CA appended, CA key pinned", chain: [.unrelated, .authority]) {
            .publicKeys([Fixture.authority.expectedPin, Fixture.p384.expectedPin], performDefaultValidation: $0)
        },
    ]

    // MARK: - Attacks

    @Test("given an attacker chain, when evaluated with or without default validation, then the host is rejected", arguments: attacks, validation)
    func attack_rejected(attack: Attack, performDefaultValidation: Bool) throws {
        let policy = ServerTrustPolicy([TrustFixtures.host: try attack.evaluator(performDefaultValidation)])
        let trust = try TrustFixtures.trust(attack.chain, anchoredOnTestCA: performDefaultValidation)

        expectTrustFailure { () throws(HTTPRequestError) in
            try policy.evaluate(trust, forHost: TrustFixtures.host)
        }
    }

    @Test("given a chain without the CA and a system that does not trust it, when the CA key is pinned, then the host is rejected", arguments: validation)
    func missingCA_untrustedCA_rejected(performDefaultValidation: Bool) throws {
        let policy = ServerTrustPolicy([TrustFixtures.host: .publicKeys([Fixture.authority.expectedPin, Fixture.p384.expectedPin], performDefaultValidation: performDefaultValidation)])
        let trust = try TrustFixtures.trust([.p256], anchoredOnTestCA: false)

        expectTrustFailure { () throws(HTTPRequestError) in
            try policy.evaluate(trust, forHost: TrustFixtures.host)
        }
    }

    /// TM-35: without default validation the anchored chain is still checked against the host name,
    /// so pinning a CA never accepts a leaf that CA issued for another host.
    @Test(
        "given default validation off and the CA pinned, when a leaf for another host is presented, then it is rejected",
        arguments: [true, false]
    )
    func otherHost_caPinned_validationOff_rejected(byCertificate: Bool) throws {
        let evaluator: ServerTrustEvaluator = byCertificate
            ? .pinnedCertificates([try Fixture.authority.der], performDefaultValidation: false)
            : .publicKeys([Fixture.authority.expectedPin, Fixture.p384.expectedPin], performDefaultValidation: false)
        let policy = ServerTrustPolicy([TrustFixtures.host: evaluator])
        let trust = try TrustFixtures.trust([.otherHost, .authority], anchoredOnTestCA: false)

        expectTrustFailure { () throws(HTTPRequestError) in
            try policy.evaluate(trust, forHost: TrustFixtures.host)
        }
    }

    @Test(
        "given default validation off and the CA pinned, when a leaf for the pinned host is presented, then it is accepted",
        arguments: [true, false]
    )
    func rightHost_caPinned_validationOff_accepted(byCertificate: Bool) throws {
        let evaluator: ServerTrustEvaluator = byCertificate
            ? .pinnedCertificates([try Fixture.authority.der], performDefaultValidation: false)
            : .publicKeys([Fixture.authority.expectedPin, Fixture.p384.expectedPin], performDefaultValidation: false)
        let policy = ServerTrustPolicy([TrustFixtures.host: evaluator])
        let trust = try TrustFixtures.trust([.p256, .authority], anchoredOnTestCA: false)

        try policy.evaluate(trust, forHost: TrustFixtures.host)
    }

    @Test("given default validation on and the CA key pinned, when a leaf for another host is presented, then it is rejected")
    func otherHost_caPinned_validationOn_rejected() throws {
        let policy = ServerTrustPolicy([TrustFixtures.host: .publicKeys([Fixture.authority.expectedPin, Fixture.p384.expectedPin])])
        let trust = try TrustFixtures.trust([.otherHost, .authority])

        expectTrustFailure { () throws(HTTPRequestError) in
            try policy.evaluate(trust, forHost: TrustFixtures.host)
        }
    }

    // MARK: - Pin Brute Force

    @Test("given 10,000 random SPKI SHA-256 pins, when every fixture chain is evaluated, then every one is rejected", arguments: validation)
    func randomPins_rejectEveryFixture(performDefaultValidation: Bool) throws {
        var random = RedTeamRandom(seed: 0x5EC0_12)
        let pins = (0..<10_000).map { _ in random.bytes(32).base64EncodedString() }
        let realPins = Set(Fixture.allCases.map(\.expectedPin))
        #expect(realPins.isDisjoint(with: pins))
        let policy = ServerTrustPolicy([TrustFixtures.host: .publicKeys(pins, performDefaultValidation: performDefaultValidation)])

        for fixture in Fixture.allCases {
            let chain: [Fixture] = fixture == .authority || fixture == .unrelated ? [fixture] : [fixture, .authority]
            let trust = try TrustFixtures.trust(chain, anchoredOnTestCA: performDefaultValidation)
            expectTrustFailure { () throws(HTTPRequestError) in
                try policy.evaluate(trust, forHost: TrustFixtures.host)
            }
        }
    }

    // MARK: - Host Matching

    @Test(
        "given a policy that requires every host, when an unlisted host is evaluated with a valid chain, then it is rejected",
        arguments: ["evil.example.com", "api.example.co", "api-example.com", "example.com", "127.0.0.1", "localhost"]
    )
    func unlistedHost_rejected(host: String) throws {
        let policy = ServerTrustPolicy([TrustFixtures.host: .custom(RedTeamAcceptingEvaluator())])
        let trust = try TrustFixtures.trust([.p256, .authority])

        #expect(policy.allHostsMustBeEvaluated)
        let reason = expectTrustFailure(host: host) { () throws(HTTPRequestError) in
            try policy.evaluate(trust, forHost: host)
        }
        #expect(reason?.contains("no trust evaluator") == true)
    }

    @Test(
        "given a *.example.com entry, when a host outside its single label is evaluated, then it is rejected",
        arguments: [
            "example.com", "evil-example.com", "api.example.com.evil.com", "a.api.example.com", "apiexample.com",
            ".example.com", "example.com.", "*.example.com.evil.com", "api.example.comm", "api.example.co",
        ]
    )
    func wildcard_doesNotOvermatch(host: String) throws {
        let policy = ServerTrustPolicy(["*.example.com": .custom(RedTeamAcceptingEvaluator())])
        let trust = try TrustFixtures.trust([.p256, .authority])

        expectTrustFailure(host: host) { () throws(HTTPRequestError) in
            try policy.evaluate(trust, forHost: host)
        }
    }

    @Test("given a *.example.com entry, when one-label subdomains in any case are evaluated, then they match", arguments: ["api.example.com", "API.Example.COM", "api.example.com."])
    func wildcard_matchesSingleLabel(host: String) throws {
        let policy = ServerTrustPolicy(["*.example.com": .custom(RedTeamAcceptingEvaluator())])
        let trust = try TrustFixtures.trust([.p256, .authority])

        #expect(throws: Never.self) {
            try policy.evaluate(trust, forHost: host)
        }
    }

    @Test("given a wildcard over a numeric parent, when an IP address is evaluated, then the wildcard never matches", arguments: ["10.0.0.1", "1.2.3.4"])
    func wildcard_neverMatchesIPAddress(host: String) throws {
        let parent = host.split(separator: ".").dropFirst().joined(separator: ".")
        let policy = ServerTrustPolicy(["*.\(parent)": .custom(RedTeamAcceptingEvaluator())])
        let trust = try TrustFixtures.trust([.p256, .authority])

        expectTrustFailure(host: host) { () throws(HTTPRequestError) in
            try policy.evaluate(trust, forHost: host)
        }
    }

    @Test("given an exact entry that pins and a wildcard that accepts, when the exact host is evaluated, then the exact pin wins")
    func exactEntry_beatsPermissiveWildcard() throws {
        let policy = ServerTrustPolicy([
            TrustFixtures.host: .publicKeys([Fixture.unrelated.expectedPin, Fixture.otherHost.expectedPin]),
            "*.example.com": .custom(RedTeamAcceptingEvaluator()),
        ])
        let trust = try TrustFixtures.trust([.p256, .authority])

        expectTrustFailure(host: "API.EXAMPLE.COM") { () throws(HTTPRequestError) in
            try policy.evaluate(trust, forHost: "API.EXAMPLE.COM")
        }
    }
}
