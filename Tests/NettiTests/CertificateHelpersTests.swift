import Foundation
import Security
import Testing

@testable import Netti

@Suite("Certificate helpers")
struct CertificateHelpersTests {
    @Test(
        "given a fixture certificate, when its SPKI is hashed, then it matches the openssl pin",
        arguments: TrustFixtures.Certificate.allCases
    )
    func publicKeyPin_matchesOpenSSL(certificate: TrustFixtures.Certificate) throws {
        #expect(Certificates.publicKeyPin(ofCertificate: try certificate.der) == certificate.expectedPin)
    }

    @Test("given a DER certificate, when validated, then the same bytes are returned")
    func certificate_validDER_returnsData() throws {
        let der = try TrustFixtures.Certificate.p256.der

        #expect(Certificates.certificate(from: der) == der)
    }

    @Test("given bytes that are not a DER certificate, when validated or hashed, then nil is returned")
    func certificate_invalidBytes_returnsNil() throws {
        let pem = Data("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n".utf8)

        #expect(Certificates.certificate(from: pem) == nil)
        #expect(Certificates.certificate(from: Data()) == nil)
        #expect(Certificates.publicKeyPin(ofCertificate: pem) == nil)
    }

    @Test("given a truncated certificate, when its SPKI is extracted, then nil is returned without crashing")
    func subjectPublicKeyInfo_truncated_returnsNil() throws {
        let der = try TrustFixtures.Certificate.rsa2048.der

        for length in [0, 1, 2, 4, 16, 64, 200, der.count - 1] {
            #expect(Certificates.subjectPublicKeyInfo(ofCertificate: der.prefix(length)) == nil)
        }
    }

    @Test("given a length field larger than the input, when parsed, then nil is returned")
    func subjectPublicKeyInfo_oversizedLength_returnsNil() {
        let bytes = Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF, 0x30, 0x00])

        #expect(Certificates.subjectPublicKeyInfo(ofCertificate: bytes) == nil)
    }

    @Test("given a certificate file URL, when loaded, then its DER is returned")
    func load_fileURL_returnsDER() throws {
        let certificate = TrustFixtures.Certificate.unrelated

        #expect(Certificates.load(contentsOf: try certificate.url) == (try certificate.der))
        #expect(Certificates.load(contentsOf: URL(filePath: "/nonexistent/missing.cer")) == nil)
    }

    @Test("given a bundle directory with .cer and .der files, when loaded, then every certificate is returned")
    func load_bundle_returnsEveryCertificate() throws {
        let loaded = Certificates.load(in: .module, subdirectory: TrustFixtures.subdirectory)
        let expected = try TrustFixtures.Certificate.allCases.map { try $0.der }

        #expect(Set(loaded) == Set(expected))
        #expect(loaded.count == expected.count)
    }

    @Test("given a bundle without certificates, when loaded, then the result is empty")
    func load_bundleWithoutCertificates_isEmpty() {
        #expect(Certificates.load(in: .module, subdirectory: "Missing").isEmpty)
    }

    // MARK: - notAfter

    @Test(
        "given a fixture certificate, when its notAfter is read, then it matches the openssl end date",
        arguments: TrustFixtures.Certificate.allCases
    )
    func notAfter_matchesOpenSSL(certificate: TrustFixtures.Certificate) throws {
        let expected = try #require(Self.utc(certificate.expectedNotAfter))

        #expect(Certificates.notAfter(ofCertificate: try certificate.der) == expected)
    }

    @Test("given a truncated certificate, when its notAfter is read, then nil is returned without crashing")
    func notAfter_truncated_returnsNil() throws {
        let der = try TrustFixtures.Certificate.p256.der

        for length in [0, 1, 2, 4, 16, 64, 120, der.count - 1] {
            #expect(Certificates.notAfter(ofCertificate: der.prefix(length)) == nil)
        }
    }

    @Test("given a UTCTime, when read, then years 50 to 99 are 19xx and 00 to 49 are 20xx")
    func notAfter_utcTimeCentury() throws {
        #expect(Certificates.notAfter(ofCertificate: Self.certificate(notAfterTag: 0x17, notAfter: "491231235959Z")) == Self.utc("2049-12-31T23:59:59Z"))
        #expect(Certificates.notAfter(ofCertificate: Self.certificate(notAfterTag: 0x17, notAfter: "500101000000Z")) == Self.utc("1950-01-01T00:00:00Z"))
    }

    @Test("given a leap second, when read, then it counts as the last second of the minute")
    func notAfter_leapSecond_isClamped() throws {
        #expect(Certificates.notAfter(ofCertificate: Self.certificate(notAfterTag: 0x17, notAfter: "261231235960Z")) == Self.utc("2026-12-31T23:59:59Z"))
    }

    @Test("given a GeneralizedTime, when read, then years from 2050 on are supported")
    func notAfter_generalizedTime() throws {
        #expect(Certificates.notAfter(ofCertificate: Self.certificate(notAfterTag: 0x18, notAfter: "20551231235959Z")) == Self.utc("2055-12-31T23:59:59Z"))
    }

    @Test(
        "given a malformed time, when read, then nil is returned",
        arguments: [
            (UInt8(0x17), "2606010000Z"),
            (UInt8(0x17), "260601000000"),
            (UInt8(0x17), "260601000000+0100"),
            (UInt8(0x17), "26AB01000000Z"),
            (UInt8(0x17), "261301000000Z"),
            (UInt8(0x17), "260230000000Z"),
            (UInt8(0x17), "260601240000Z"),
            (UInt8(0x18), "260601000000Z"),
            (UInt8(0x18), "2026060100000000Z"),
            (UInt8(0x18), ""),
        ]
    )
    func notAfter_malformedTime_returnsNil(tag: UInt8, time: String) {
        #expect(Certificates.notAfter(ofCertificate: Self.certificate(notAfterTag: tag, notAfter: time)) == nil)
    }

    @Test("given a validity with a third element or a wrong tag, when read, then nil is returned")
    func notAfter_malformedValidity_returnsNil() {
        let valid = Self.der(0x17, Array("260101000000Z".utf8)) + Self.der(0x17, Array("270101000000Z".utf8))

        #expect(Certificates.notAfter(ofCertificate: Self.certificate(validity: valid + Self.der(0x17, Array("280101000000Z".utf8)))) == nil)
        #expect(Certificates.notAfter(ofCertificate: Self.certificate(validity: Self.der(0x17, Array("260101000000Z".utf8)))) == nil)
        #expect(Certificates.notAfter(ofCertificate: Self.certificate(validity: Self.der(0x04, Array("260101000000Z".utf8)) + Self.der(0x04, Array("270101000000Z".utf8)))) == nil)
    }

    // MARK: - Builders

    private static func utc(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }

    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        precondition(content.count < 0x80)
        return [tag, UInt8(content.count)] + content
    }

    /// A certificate skeleton whose `notBefore` is fixed and whose `notAfter` is `time` under `tag`.
    private static func certificate(notAfterTag tag: UInt8, notAfter time: String) -> Data {
        certificate(validity: der(0x17, Array("260101000000Z".utf8)) + der(tag, Array(time.utf8)))
    }

    /// `Certificate { TBSCertificate { [0] version, serial, signature, issuer, validity, subject, SPKI } }`
    /// with the given `validity` contents; only the structure a parser walks, not a usable certificate.
    private static func certificate(validity contents: [UInt8]) -> Data {
        let tbs = der(0xA0, der(0x02, [2]))
            + der(0x02, [1])
            + der(0x30, [])
            + der(0x30, [])
            + der(0x30, contents)
            + der(0x30, [])
            + der(0x30, [])
        return Data(der(0x30, der(0x30, tbs)))
    }
}

@Suite("Public key pin")
struct PublicKeyPinTests {
    @Test(
        "given a fixture certificate, when the public pin helper hashes it, then it matches the openssl pin",
        arguments: TrustFixtures.Certificate.allCases
    )
    func publicKeyPin_data_matchesOpenSSL(certificate: TrustFixtures.Certificate) throws {
        #expect(ServerTrustPolicy.publicKeyPin(ofCertificate: try certificate.der) == certificate.expectedPin)
    }

    @Test(
        "given a SecCertificate, when the public pin helper hashes it, then it matches the openssl pin",
        arguments: TrustFixtures.Certificate.allCases
    )
    func publicKeyPin_secCertificate_matchesOpenSSL(certificate: TrustFixtures.Certificate) throws {
        let secCertificate = try #require(SecCertificateCreateWithData(nil, try certificate.der as CFData))

        #expect(ServerTrustPolicy.publicKeyPin(of: secCertificate) == certificate.expectedPin)
    }

    @Test("given bytes that are not a certificate, when hashed, then nil is returned")
    func publicKeyPin_invalid_returnsNil() {
        #expect(ServerTrustPolicy.publicKeyPin(ofCertificate: Data("nope".utf8)) == nil)
        #expect(ServerTrustPolicy.publicKeyPin(ofCertificate: Data()) == nil)
    }

    @Test("given a pin from the helper, when used in a policy, then the pinned certificate is accepted")
    func publicKeyPin_roundTripsThroughAPolicy() throws {
        let leaf = TrustFixtures.Certificate.p256
        let pin = try #require(ServerTrustPolicy.publicKeyPin(ofCertificate: try leaf.der))
        let policy = ServerTrustPolicy([TrustFixtures.host: .publicKeys([pin, "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI="])])

        let trust = try TrustFixtures.trust([leaf])

        #expect(throws: Never.self) { try policy.evaluate(trust, forHost: TrustFixtures.host) }
    }
}

@Suite("DER length parsing")
struct DERLengthTests {
    @Test(
        "given a four-byte length with the high bit set, when parsed, then nil is returned on every platform",
        arguments: [
            [0x30, 0x84, 0x80, 0x00, 0x00, 0x00],
            [0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF],
            [0x30, 0x84, 0xFF, 0xFF, 0xFF, 0x00],
            [0x30, 0x84, 0x7F, 0xFF, 0xFF, 0xFF],
        ] as [[UInt8]]
    )
    func hugeLength_returnsNil(bytes: [UInt8]) {
        #expect(Certificates.subjectPublicKeyInfo(ofCertificate: Data(bytes)) == nil)
        #expect(Certificates.notAfter(ofCertificate: Data(bytes)) == nil)
        #expect(ServerTrustPolicy.publicKeyPin(ofCertificate: Data(bytes)) == nil)
    }
}
