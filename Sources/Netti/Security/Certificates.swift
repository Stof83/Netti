//
//  Certificates.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import CryptoKit
import Foundation
import os
import Security

/// DER certificate loading and SubjectPublicKeyInfo (SPKI) pin computation.
///
/// Pins are the base64 SHA-256 of the certificate's DER-encoded SPKI, the value produced by
/// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`.
/// The SPKI is read straight from the certificate DER rather than rebuilt from a `SecKey`, so
/// every key type (RSA, P-256, P-384, and any future algorithm) hashes exactly as encoded.
enum Certificates {

    // MARK: - Types

    /// The bounds of one DER element: where it starts, where its contents start and where it ends.
    fileprivate struct Element {
        let start: Int
        let contentStart: Int
        let end: Int
    }

    // MARK: - Constants

    /// File extensions searched in a bundle; each file must hold a single DER certificate.
    static let fileExtensions = ["cer", "der", "crt"]

    private static let integerTag: UInt8 = 0x02
    private static let sequenceTag: UInt8 = 0x30
    private static let utcTimeTag: UInt8 = 0x17
    private static let generalizedTimeTag: UInt8 = 0x18
    private static let versionTag: UInt8 = 0xA0
    private static let shortLengthLimit: UInt8 = 0x80
    private static let maximumLengthBytes = 4
    private static let highTagNumberMask: UInt8 = 0x1F

    // MARK: - Loading

    /// Returns `der` when it is a well-formed DER certificate, otherwise `nil`.
    static func certificate(from der: Data) -> Data? {
        SecCertificateCreateWithData(nil, der as CFData) == nil ? nil : der
    }

    /// Reads a DER certificate from a file, returning `nil` when the file is unreadable or not a certificate.
    static func load(contentsOf url: URL) -> Data? {
        guard let contents = try? Data(contentsOf: url) else {
            return nil
        }
        return certificate(from: contents)
    }

    /// Loads every `.cer`, `.der` and `.crt` certificate in a bundle directory.
    ///
    /// Files that are not DER certificates (for example PEM) are skipped with a logged warning.
    static func load(in bundle: Bundle, subdirectory: String? = nil) -> [Data] {
        let urls = fileExtensions.flatMap { fileExtension in
            bundle.urls(forResourcesWithExtension: fileExtension, subdirectory: subdirectory) ?? []
        }
        return urls.compactMap { url in
            guard let der = load(contentsOf: url) else {
                Logger.security.warning("Skipping \(url.lastPathComponent, privacy: .public): not a DER certificate")
                return nil
            }
            return der
        }
    }

    // MARK: - Public Key Pins

    /// The base64 SHA-256 of the certificate's SPKI, or `nil` when the DER cannot be parsed.
    static func publicKeyPin(ofCertificate der: Data) -> String? {
        publicKeyHash(ofCertificate: der)?.base64EncodedString()
    }

    /// The raw SHA-256 of the certificate's SPKI, or `nil` when the DER cannot be parsed.
    static func publicKeyHash(ofCertificate der: Data) -> Data? {
        subjectPublicKeyInfo(ofCertificate: der).map { Data(SHA256.hash(data: $0)) }
    }

    /// Extracts the DER-encoded `SubjectPublicKeyInfo` from an X.509 certificate.
    ///
    /// Walks `Certificate → TBSCertificate → [version] serialNumber signature issuer validity subject
    /// subjectPublicKeyInfo` (RFC 5280 §4.1), checking every tag and bound.
    static func subjectPublicKeyInfo(ofCertificate der: Data) -> Data? {
        let bytes = [UInt8](der)
        guard let fields = tbsFields(in: bytes) else {
            return nil
        }
        return Data(bytes[fields.publicKeyInfo.start..<fields.publicKeyInfo.end])
    }

    /// The end of the certificate's validity period (`notAfter`), or `nil` when the DER cannot be
    /// parsed or the time is malformed.
    ///
    /// Read from the DER, because `SecCertificateCopyNotValidAfterDate` needs iOS 18 and macOS 15.
    /// Accepts the two forms RFC 5280 §4.1.2.5 allows: `UTCTime` (`YYMMDDHHMMSSZ`, years 1950 to
    /// 2049) and `GeneralizedTime` (`YYYYMMDDHHMMSSZ`).
    static func notAfter(ofCertificate der: Data) -> Date? {
        let bytes = [UInt8](der)
        guard let fields = tbsFields(in: bytes),
              let notBefore = timeElement(in: bytes, at: fields.validity.contentStart, limit: fields.validity.end),
              let notAfter = timeElement(in: bytes, at: notBefore.end, limit: fields.validity.end),
              notAfter.end == fields.validity.end
        else {
            return nil
        }
        return date(fromTime: bytes[notAfter.contentStart..<notAfter.end], isGeneralized: bytes[notAfter.start] == generalizedTimeTag)
    }
}

// MARK: - Private Methods

private extension Certificates {
    /// The `validity` and `subjectPublicKeyInfo` fields of a certificate's `TBSCertificate`.
    struct TBSFields {
        let validity: Element
        let publicKeyInfo: Element
    }

    /// Walks `Certificate → TBSCertificate → [version] serialNumber signature issuer validity subject
    /// subjectPublicKeyInfo`, checking every tag and bound.
    static func tbsFields(in bytes: [UInt8]) -> TBSFields? {
        guard let certificate = element(in: bytes, at: 0, limit: bytes.count, tag: sequenceTag),
              let tbsCertificate = element(in: bytes, at: certificate.contentStart, limit: certificate.end, tag: sequenceTag)
        else {
            return nil
        }
        var offset = tbsCertificate.contentStart
        if let version = element(in: bytes, at: offset, limit: tbsCertificate.end, tag: versionTag) {
            offset = version.end
        }
        let precedingFieldTags = [integerTag, sequenceTag, sequenceTag, sequenceTag, sequenceTag]
        var fields: [Element] = []
        for tag in precedingFieldTags {
            guard let field = element(in: bytes, at: offset, limit: tbsCertificate.end, tag: tag) else {
                return nil
            }
            fields.append(field)
            offset = field.end
        }
        guard let publicKeyInfo = element(in: bytes, at: offset, limit: tbsCertificate.end, tag: sequenceTag) else {
            return nil
        }
        // serialNumber, signature, issuer, validity, subject: validity is the fourth.
        return TBSFields(validity: fields[3], publicKeyInfo: publicKeyInfo)
    }

    /// Parses a `UTCTime` or `GeneralizedTime` element at `offset`.
    static func timeElement(in bytes: [UInt8], at offset: Int, limit: Int) -> Element? {
        element(in: bytes, at: offset, limit: limit, tag: utcTimeTag) ?? element(in: bytes, at: offset, limit: limit, tag: generalizedTimeTag)
    }

    /// Converts the digits and trailing `Z` of a DER time, rejecting any other shape.
    static func date(fromTime content: ArraySlice<UInt8>, isGeneralized: Bool) -> Date? {
        let digitCount = isGeneralized ? 14 : 12
        guard content.count == digitCount + 1, content.last == UInt8(ascii: "Z") else {
            return nil
        }
        let digits = content.dropLast().map { Int($0) - Int(UInt8(ascii: "0")) }
        guard digits.allSatisfy({ (0...9).contains($0) }) else {
            return nil
        }
        func number(_ range: Range<Int>) -> Int {
            digits[range].reduce(0) { $0 * 10 + $1 }
        }
        let yearDigits = isGeneralized ? 4 : 2
        var year = number(0..<yearDigits)
        if isGeneralized == false {
            year += year >= 50 ? 1900 : 2000
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: number(yearDigits..<yearDigits + 2),
            day: number(yearDigits + 2..<yearDigits + 4),
            hour: number(yearDigits + 4..<yearDigits + 6),
            minute: number(yearDigits + 6..<yearDigits + 8),
            // A leap second (60) is a valid certificate time; count it as the last second of the minute.
            second: min(number(yearDigits + 8..<yearDigits + 10), 59)
        )
        guard components.isValidDate(in: calendar) else {
            return nil
        }
        return calendar.date(from: components)
    }

    /// Parses the DER element at `offset` with the expected `tag`, entirely inside `limit`.
    ///
    /// Only definite lengths of up to four bytes and single-byte tags are accepted.
    static func element(in bytes: [UInt8], at offset: Int, limit: Int, tag: UInt8) -> Element? {
        guard offset >= 0, offset + 1 < limit, limit <= bytes.count, bytes[offset] == tag,
              tag & highTagNumberMask != highTagNumberMask
        else {
            return nil
        }
        let lengthByte = bytes[offset + 1]
        var contentStart = offset + 2
        var length = Int(lengthByte)
        if lengthByte >= shortLengthLimit {
            let lengthByteCount = Int(lengthByte & ~shortLengthLimit)
            guard (1...maximumLengthBytes).contains(lengthByteCount), contentStart + lengthByteCount <= limit else {
                return nil
            }
            // Accumulated unsigned, so a length with the high bit set cannot wrap negative where
            // `Int` is 32 bits (watchOS on arm64_32).
            let unsigned = bytes[contentStart..<contentStart + lengthByteCount].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard let converted = Int(exactly: unsigned) else {
                return nil
            }
            length = converted
            contentStart += lengthByteCount
        }
        let (end, overflow) = contentStart.addingReportingOverflow(length)
        guard overflow == false, length >= 0, end <= limit else {
            return nil
        }
        return Element(start: offset, contentStart: contentStart, end: end)
    }
}

// MARK: - Logger

extension Logger {
    /// Server trust and pinning diagnostics.
    static let security = Logger(subsystem: "Netti", category: "security")
}
