import Foundation
import Security
import Testing

@testable import Netti

@Suite("Server trust evaluators")
struct TrustEvaluatorTests {
    private typealias Fixture = TrustFixtures.Certificate

    private let host = TrustFixtures.host
    private let afterLeafExpiry = ISO8601DateFormatter().date(from: "2029-01-01T00:00:00Z") ?? .distantFuture

    // MARK: - Default

    @Test("given a valid chain for the host, when evaluated by default, then it passes", arguments: Fixture.validLeaves)
    func default_validChain_passes(leaf: TrustFixtures.Certificate) throws {
        try ServerTrustEvaluator.default.evaluate(try TrustFixtures.trust([leaf]), forHost: host)
    }

    @Test("given an expired leaf, when evaluated by default, then it fails")
    func default_expiredChain_fails() throws {
        let trust = try TrustFixtures.trust([.expired])

        expectTrustFailure { () throws(HTTPRequestError) in try ServerTrustEvaluator.default.evaluate(trust, forHost: host) }
    }

    @Test("given a leaf for another host, when evaluated by default, then it fails")
    func default_wrongHost_fails() throws {
        let otherHostTrust = try TrustFixtures.trust([.otherHost])
        let apiTrust = try TrustFixtures.trust([.p256])

        expectTrustFailure { () throws(HTTPRequestError) in try ServerTrustEvaluator.default.evaluate(otherHostTrust, forHost: host) }
        expectTrustFailure(host: "evil.example.org") { () throws(HTTPRequestError) in
            try ServerTrustEvaluator.default.evaluate(apiTrust, forHost: "evil.example.org")
        }
    }

    @Test("given a certificate not issued by a trusted anchor, when evaluated by default, then it fails")
    func default_untrustedAnchor_fails() throws {
        let trust = try TrustFixtures.trust([.unrelated])

        expectTrustFailure { () throws(HTTPRequestError) in try ServerTrustEvaluator.default.evaluate(trust, forHost: host) }
    }

    @Test("given a verify date set on the trust, when evaluated, then the evaluator keeps it")
    func default_keepsVerifyDate() throws {
        let trust = try TrustFixtures.trust([.p256], at: afterLeafExpiry)

        expectTrustFailure { () throws(HTTPRequestError) in try ServerTrustEvaluator.default.evaluate(trust, forHost: host) }
    }

    // MARK: - Revocation

    @Test("given a valid chain without revocation info, when evaluated with soft-fail revocation, then it passes")
    func revocation_validChain_passes() throws {
        try ServerTrustEvaluator.revocation.evaluate(try TrustFixtures.trust([.p256]), forHost: host)
    }

    @Test("given a chain without revocation info, when a positive response is required, then it fails")
    func revocation_requirePositiveResponse_fails() throws {
        let trust = try TrustFixtures.trust([.p256])
        let evaluator = ServerTrustEvaluator.revocation(requirePositiveResponse: true)

        expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
    }

    @Test("given an expired leaf, when evaluated with revocation, then default validation still fails it")
    func revocation_expiredChain_fails() throws {
        let trust = try TrustFixtures.trust([.expired])

        expectTrustFailure { () throws(HTTPRequestError) in try ServerTrustEvaluator.revocation.evaluate(trust, forHost: host) }
    }

    // MARK: - Public Keys

    @Test("given the leaf's SPKI pin, when evaluated, then it passes", arguments: Fixture.validLeaves)
    func publicKeys_match_passes(leaf: TrustFixtures.Certificate) throws {
        let evaluator = ServerTrustEvaluator.publicKeys([leaf.expectedPin, Fixture.unrelated.expectedPin])

        try evaluator.evaluate(try TrustFixtures.trust([leaf]), forHost: host)
    }

    @Test("given only the CA's SPKI pin, when evaluated, then any certificate in the chain matches")
    func publicKeys_caPin_passes() throws {
        let evaluator = ServerTrustEvaluator.publicKeys([Fixture.authority.expectedPin])

        try evaluator.evaluate(try TrustFixtures.trust([.rsa2048]), forHost: host)
    }

    @Test("given no matching pin, when evaluated, then it fails")
    func publicKeys_mismatch_fails() throws {
        let trust = try TrustFixtures.trust([.p256])
        let evaluator = ServerTrustEvaluator.publicKeys([Fixture.unrelated.expectedPin, Fixture.p384.expectedPin])

        let reason = expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
        #expect(reason?.contains("pinned") == true)
    }

    @Test("given an expired chain with the correct pin, when evaluated, then it fails")
    func publicKeys_expiredWithCorrectPin_fails() throws {
        let trust = try TrustFixtures.trust([.expired])
        let evaluator = ServerTrustEvaluator.publicKeys([Fixture.expired.expectedPin, Fixture.authority.expectedPin])

        expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
    }

    @Test("given a wrong host with the correct pin, when evaluated, then it fails")
    func publicKeys_wrongHostWithCorrectPin_fails() throws {
        let trust = try TrustFixtures.trust([.otherHost])
        let evaluator = ServerTrustEvaluator.publicKeys([Fixture.otherHost.expectedPin, Fixture.authority.expectedPin])

        expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
    }

    @Test("given default validation turned off, when evaluated, then the pin anchors the chain and the host is checked")
    func publicKeys_withoutDefaultValidation_anchorsOnPin() throws {
        let matching = ServerTrustEvaluator.publicKeys([Fixture.authority.expectedPin], performDefaultValidation: false)
        let mismatching = ServerTrustEvaluator.publicKeys([Fixture.unrelated.expectedPin], performDefaultValidation: false)

        let otherHostTrust = try TrustFixtures.trust([.otherHost, .authority], anchoredOnTestCA: false)
        let mismatchTrust = try TrustFixtures.trust([.p256, .authority], anchoredOnTestCA: false)

        try matching.evaluate(try TrustFixtures.trust([.p256, .authority], anchoredOnTestCA: false), forHost: host)
        expectTrustFailure { () throws(HTTPRequestError) in try matching.evaluate(otherHostTrust, forHost: host) }
        expectTrustFailure { () throws(HTTPRequestError) in try mismatching.evaluate(mismatchTrust, forHost: host) }
    }

    @Test("given default validation turned off and an expired chain with the correct pin, when evaluated, then it fails")
    func publicKeys_withoutDefaultValidation_expiredFails() throws {
        let trust = try TrustFixtures.trust([.expired, .authority], anchoredOnTestCA: false)
        let evaluator = ServerTrustEvaluator.publicKeys([Fixture.authority.expectedPin], performDefaultValidation: false)

        expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
    }

    @Test("given only malformed pins, when evaluated, then it fails closed")
    func publicKeys_malformedPins_fail() throws {
        let trust = try TrustFixtures.trust([.p256])
        let evaluator = ServerTrustEvaluator.publicKeys(["not base64", "c2hvcnQ="])

        expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
        #expect(evaluator.pinCounts == [0])
    }

    // MARK: - Pinned Certificates

    @Test("given the leaf or CA certificate pinned, when evaluated, then it passes", arguments: [Fixture.p384, .authority])
    func pinnedCertificates_match_passes(pinned: TrustFixtures.Certificate) throws {
        let evaluator = ServerTrustEvaluator.pinnedCertificates([try pinned.der])

        try evaluator.evaluate(try TrustFixtures.trust([.p384]), forHost: host)
    }

    @Test("given no pinned certificate in the chain, when evaluated, then it fails")
    func pinnedCertificates_mismatch_fails() throws {
        let trust = try TrustFixtures.trust([.p384])
        let evaluator = ServerTrustEvaluator.pinnedCertificates([try Fixture.unrelated.der, try Fixture.p256.der])

        let reason = expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
        #expect(reason?.contains("pinned") == true)
    }

    @Test("given an expired chain with its certificate pinned, when evaluated, then it fails")
    func pinnedCertificates_expiredWithPin_fails() throws {
        let trust = try TrustFixtures.trust([.expired])
        let evaluator = ServerTrustEvaluator.pinnedCertificates([try Fixture.expired.der])

        expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
    }

    @Test("given certificates in a bundle, when pinned from it, then every .cer and .der is a pin")
    func pinnedCertificates_bundle_loadsEveryCertificate() throws {
        let evaluator = ServerTrustEvaluator.pinnedCertificates(in: .module, subdirectory: TrustFixtures.subdirectory)

        try evaluator.evaluate(try TrustFixtures.trust([.rsa4096]), forHost: host)
        #expect(evaluator.pinCounts == [Fixture.allCases.count])
    }

    @Test("given a bundle without certificates, when pinned from it, then evaluation fails closed")
    func pinnedCertificates_emptyBundle_fails() throws {
        let trust = try TrustFixtures.trust([.rsa4096])
        let evaluator = ServerTrustEvaluator.pinnedCertificates(in: .module, subdirectory: "Missing")

        expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
        #expect(evaluator.pinCounts == [0])
    }

    // MARK: - Pins Anchor An Unvalidated Chain (TM-02)

    @Test(
        "given default validation off and a forged leaf followed by the genuine pinned CA, when evaluated, then it fails",
        arguments: [Fixture.unrelated, .forgedIssuer]
    )
    func pinsWithoutDefaultValidation_forgedLeaf_fails(forged: TrustFixtures.Certificate) throws {
        let evaluators = [
            ServerTrustEvaluator.pinnedCertificates([try Fixture.authority.der], performDefaultValidation: false),
            ServerTrustEvaluator.publicKeys([Fixture.authority.expectedPin], performDefaultValidation: false),
        ]
        for evaluator in evaluators {
            let trust = try TrustFixtures.trust([forged, .authority], anchoredOnTestCA: false)

            expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
        }
    }

    @Test("given default validation off and a chain issued by the pinned private CA, when evaluated, then it passes")
    func pinsWithoutDefaultValidation_privateCA_passes() throws {
        let evaluators = [
            ServerTrustEvaluator.pinnedCertificates([try Fixture.authority.der], performDefaultValidation: false),
            ServerTrustEvaluator.publicKeys([Fixture.authority.expectedPin], performDefaultValidation: false),
        ]
        for evaluator in evaluators {
            try evaluator.evaluate(try TrustFixtures.trust([.rsa2048, .authority], anchoredOnTestCA: false), forHost: host)
        }
    }

    @Test("given default validation off and the pinned CA not sent by the server, when evaluated with a certificate pin, then it passes")
    func pinnedCertificatesWithoutDefaultValidation_rootNotSent_passes() throws {
        let evaluator = ServerTrustEvaluator.pinnedCertificates([try Fixture.authority.der], performDefaultValidation: false)

        try evaluator.evaluate(try TrustFixtures.trust([.p256], anchoredOnTestCA: false), forHost: host)
    }

    @Test("given default validation off and the leaf itself pinned, when evaluated, then it passes", arguments: [true, false])
    func pinsWithoutDefaultValidation_pinnedLeaf_passes(byCertificate: Bool) throws {
        let evaluator = byCertificate
            ? ServerTrustEvaluator.pinnedCertificates([try Fixture.p384.der], performDefaultValidation: false)
            : ServerTrustEvaluator.publicKeys([Fixture.p384.expectedPin], performDefaultValidation: false)

        try evaluator.evaluate(try TrustFixtures.trust([.p384, .authority], anchoredOnTestCA: false), forHost: host)
    }

    @Test("given default validation off and an expired chain with its certificate pinned, when evaluated, then it fails")
    func pinnedCertificatesWithoutDefaultValidation_expired_fails() throws {
        let trust = try TrustFixtures.trust([.expired, .authority], anchoredOnTestCA: false)
        let evaluator = ServerTrustEvaluator.pinnedCertificates([try Fixture.authority.der], performDefaultValidation: false)

        expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
    }

    // MARK: - Composite

    @Test("given evaluators that all pass, when composed, then the composite passes")
    func composite_allPass_passes() throws {
        let evaluator = ServerTrustEvaluator.composite([.revocation, .publicKeys([Fixture.p256.expectedPin])])

        try evaluator.evaluate(try TrustFixtures.trust([.p256]), forHost: host)
    }

    @Test("given one failing evaluator, when composed, then the composite fails")
    func composite_oneFails_fails() throws {
        let trust = try TrustFixtures.trust([.p256])
        let evaluator = ServerTrustEvaluator.composite([.default, .publicKeys([Fixture.unrelated.expectedPin])])

        expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
        #expect(evaluator.pinCounts == [1])
    }

    /// TM-47: an anchored pin evaluates a copy of the trust, so it never lends its anchors to a
    /// later step.
    @Test(
        "given an anchored pin then default validation, when composed, then each step checks the chain independently",
        arguments: [true, false]
    )
    func composite_anchoredPinThenDefault_independent(systemTrustsCA: Bool) throws {
        let pin = ServerTrustEvaluator.publicKeys([Fixture.authority.expectedPin], performDefaultValidation: false)
        let evaluator = ServerTrustEvaluator.composite([pin, .default])
        let trust = try TrustFixtures.trust([.p256, .authority], anchoredOnTestCA: systemTrustsCA)

        if systemTrustsCA {
            try evaluator.evaluate(trust, forHost: host)
        } else {
            expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
            expectTrustFailure { () throws(HTTPRequestError) in try ServerTrustEvaluator.default.evaluate(trust, forHost: host) }
        }
        try pin.evaluate(trust, forHost: host)
    }

    @Test("given no evaluators, when composed, then the composite fails closed")
    func composite_empty_fails() throws {
        let trust = try TrustFixtures.trust([.p256])

        expectTrustFailure { () throws(HTTPRequestError) in try ServerTrustEvaluator.composite([]).evaluate(trust, forHost: host) }
    }

    // MARK: - Custom

    @Test("given a custom evaluator, when wrapped, then its decision is used")
    func custom_isInvoked() throws {
        let trust = try TrustFixtures.trust([.p256])
        let evaluator = ServerTrustEvaluator.custom(RejectingEvaluator())

        let reason = expectTrustFailure { () throws(HTTPRequestError) in try evaluator.evaluate(trust, forHost: host) }
        #expect(reason == "custom")
    }

    // MARK: - Disabled

    #if DEBUG
    @Test("given an expired chain for another host, when evaluation is disabled, then it passes")
    func disabled_alwaysPasses() throws {
        try ServerTrustEvaluator.disabled.evaluate(try TrustFixtures.trust([.expired]), forHost: "evil.example.org")
        try ServerTrustEvaluator.disabled.evaluate(try TrustFixtures.trust([.unrelated]), forHost: host)
    }
    #endif
}

private struct RejectingEvaluator: ServerTrustEvaluating {
    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        throw .serverTrustEvaluationFailed(host: host, reason: "custom")
    }
}
