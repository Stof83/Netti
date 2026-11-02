//
//  FuzzCertificateTests.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/10/26.
//

import CryptoKit
import Foundation
import Testing

@testable import Netti

/// Seeded fuzzing of DER and SPKI loading (TM-31): mutated fixture certificates and random TLV
/// trees never trap; loading returns `nil` or the same bytes, and SPKI extraction returns `nil` or
/// a well-formed `SEQUENCE` that lies inside the input and hashes to the reported pin.
@Suite("Fuzz: DER certificates", .timeLimit(.minutes(30)))
struct FuzzCertificateTests {

    // MARK: - Mutated Fixtures

    @Test("given fixture certificates with bit flips, truncation and corrupted lengths, when loaded, then nothing traps and results stay well-formed")
    func mutatedFixtures_loadSafely() async throws {
        let fixtures = try TrustFixtures.Certificate.allCases.map { try $0.der }

        await Fuzz.run("der.mutated") { fuzz in
            let original = fuzz.random.pick(fixtures)
            let (mutated, isTruncation) = mutate(original, using: &fuzz.random)
            fuzz.input = "\(mutated.count) B, truncation=\(isTruncation) prefix=\(mutated.prefix(16).map { String(format: "%02X", $0) }.joined())"

            check(mutated, in: &fuzz)
            if isTruncation {
                fuzz.check(Certificates.subjectPublicKeyInfo(ofCertificate: mutated) == nil, "a truncated certificate yielded an SPKI")
                fuzz.check(Certificates.notAfter(ofCertificate: mutated) == nil, "a truncated certificate yielded a notAfter")
            }
        }
    }

    @Test("given random TLV trees with lying and oversized lengths, when the SPKI is extracted, then nothing traps and results stay well-formed")
    func randomTLV_extractSafely() async {
        await Fuzz.run("der.tlv") { fuzz in
            let bytes = Data(TLVGenerator.element(using: &fuzz.random, depth: 0, preferCertificateShape: fuzz.random.chance(0.7)))
            fuzz.input = bytes.prefix(48).map { String(format: "%02X", $0) }.joined()

            check(bytes, in: &fuzz)
        }
    }

    // MARK: - Private Helpers

    private func check(_ bytes: Data, in fuzz: inout FuzzCase) {
        if let certificate = Certificates.certificate(from: bytes) {
            fuzz.check(certificate == bytes, "certificate(from:) returned other bytes")
        }

        if let notAfter = Certificates.notAfter(ofCertificate: bytes) {
            fuzz.check(Certificates.subjectPublicKeyInfo(ofCertificate: bytes) != nil, "a notAfter was read from a certificate with no SPKI")
            fuzz.check((-62_135_596_800...253_402_300_799).contains(notAfter.timeIntervalSince1970), "notAfter is outside years 1 to 9999")
        }

        let spki = Certificates.subjectPublicKeyInfo(ofCertificate: bytes)
        let pin = Certificates.publicKeyPin(ofCertificate: bytes)
        fuzz.check((spki == nil) == (pin == nil), "SPKI and pin disagree on nil")
        guard let spki else {
            return
        }
        fuzz.check(bytes.range(of: spki) != nil, "SPKI is not a slice of the input")
        fuzz.check(TLVGenerator.isWellFormedSequence(spki), "SPKI is not one well-formed SEQUENCE")
        fuzz.check(pin == Data(SHA256.hash(data: spki)).base64EncodedString(), "pin is not the SPKI hash")
    }

    /// One structural or byte-level mutation; reports whether it was a strict truncation.
    private func mutate(_ der: Data, using random: inout SeededRandom) -> (Data, Bool) {
        switch random.int(0...5) {
            case 0:
                return (der.prefix(random.int(0...(der.count - 1))), true)
            case 1...2:
                return (corruptLength(der, using: &random), false)
            default:
                return (random.mutate(der, times: random.int(1...4), fragments: [Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF]), Data([0x80]), Data([0x00])]), false)
        }
    }

    /// Rewrites the length of a random element of the certificate's TLV structure.
    private func corruptLength(_ der: Data, using random: inout SeededRandom) -> Data {
        let offsets = TLVGenerator.elementOffsets(in: [UInt8](der))
        guard let tagOffset = offsets.isEmpty ? nil : random.pick(offsets) else {
            return random.mutate(der)
        }
        var bytes = [UInt8](der)
        let lengthOffset = tagOffset + 1
        let lengthByteCount = bytes[lengthOffset] >= 0x80 ? Int(bytes[lengthOffset] & 0x7F) : 0
        let replacement: [UInt8] = random.pick([
            [0x00], [0x7F], [0x80], [0x81, 0xFF], [0x82, 0xFF, 0xFF], [0x84, 0xFF, 0xFF, 0xFF, 0xFF], [0x84, 0x7F, 0xFF, 0xFF, 0xFF],
            [0x85, 0x01, 0x00, 0x00, 0x00, 0x00], [0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], [0xFF],
            [UInt8(truncatingIfNeeded: Int(bytes[lengthOffset]) + random.pick([-1, 1]))],
        ])
        let end = min(bytes.count, lengthOffset + 1 + lengthByteCount)
        bytes.replaceSubrange(lengthOffset..<end, with: replacement)
        return Data(bytes)
    }
}

// MARK: - TLVGenerator

private enum TLVGenerator {
    private static let tags: [UInt8] = [0x30, 0x30, 0x30, 0x02, 0xA0, 0x31, 0x04, 0x03, 0x05, 0x06, 0x1F, 0x3F, 0xFF, 0x00]

    /// A random TLV element; certificate-shaped trees put `[0] version, INTEGER, SEQUENCE × 5`
    /// inside two `SEQUENCE`s, so the walker gets past its first checks.
    static func element(using random: inout SeededRandom, depth: Int, preferCertificateShape: Bool) -> [UInt8] {
        if preferCertificateShape, depth == 0 {
            var tbs: [UInt8] = []
            if random.chance(0.7) {
                tbs += encode(tag: 0xA0, content: element(using: &random, depth: 2, preferCertificateShape: false), using: &random)
            }
            tbs += encode(tag: 0x02, content: random.bytes(count: random.int(0...8)).map { $0 }, using: &random)
            for _ in 0..<random.int(3...6) {
                tbs += encode(tag: 0x30, content: element(using: &random, depth: 3, preferCertificateShape: false), using: &random)
            }
            let certificate = encode(tag: 0x30, content: tbs, using: &random) + element(using: &random, depth: 3, preferCertificateShape: false)
            return encode(tag: 0x30, content: certificate, using: &random)
        }
        let tag = random.pick(tags)
        let isConstructed = tag & 0x20 != 0 && depth < 6
        let content: [UInt8] = isConstructed
            ? (0..<random.int(0...3)).flatMap { _ in element(using: &random, depth: depth + 1, preferCertificateShape: false) }
            : [UInt8](random.bytes(count: random.length(upTo: 64)))
        return encode(tag: tag, content: content, using: &random)
    }

    /// The offsets of every element header reachable by walking constructed elements.
    static func elementOffsets(in bytes: [UInt8]) -> [Int] {
        var offsets: [Int] = []
        var pending = [(start: 0, end: bytes.count)]
        while let range = pending.popLast(), offsets.count < 512 {
            var offset = range.start
            while let header = header(in: bytes, at: offset, limit: range.end) {
                offsets.append(offset)
                if bytes[offset] & 0x20 != 0 {
                    pending.append((header.contentStart, header.end))
                }
                offset = header.end
            }
        }
        return offsets
    }

    /// Whether `bytes` is exactly one `SEQUENCE` whose length matches its content.
    static func isWellFormedSequence(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.first == 0x30, let header = header(in: bytes, at: 0, limit: bytes.count) else {
            return false
        }
        return header.end == bytes.count
    }

    private static func header(in bytes: [UInt8], at offset: Int, limit: Int) -> (contentStart: Int, end: Int)? {
        guard offset + 1 < limit else {
            return nil
        }
        var contentStart = offset + 2
        var length = Int(bytes[offset + 1])
        if length >= 0x80 {
            let count = length & 0x7F
            guard (1...4).contains(count), contentStart + count <= limit else {
                return nil
            }
            length = bytes[contentStart..<contentStart + count].reduce(0) { $0 << 8 | Int($1) }
            contentStart += count
        }
        guard contentStart + length <= limit else {
            return nil
        }
        return (contentStart, contentStart + length)
    }

    /// Encodes `content` under `tag`, sometimes in long form, sometimes with a lying length.
    private static func encode(tag: UInt8, content: [UInt8], using random: inout SeededRandom) -> [UInt8] {
        var length = content.count
        if random.chance(0.15) {
            length = max(0, length + random.pick([-2, -1, 1, 2, 1_000, Int(UInt32.max)]))
        }
        let lengthBytes: [UInt8]
        if length < 0x80, random.chance(0.8) {
            lengthBytes = [UInt8(length)]
        } else {
            let significant = withUnsafeBytes(of: UInt64(length).bigEndian, Array.init).drop { $0 == 0 }
            let padded = random.chance(0.1) ? [0x00] + significant : Array(significant)
            let body = padded.isEmpty ? [UInt8(0)] : padded
            lengthBytes = [0x80 | UInt8(min(body.count, 0x7F))] + body
        }
        return [tag] + lengthBytes + content
    }
}
