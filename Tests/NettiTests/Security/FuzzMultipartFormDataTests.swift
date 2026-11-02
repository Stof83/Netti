//
//  FuzzMultipartFormDataTests.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/10/26.
//

import Foundation
import Testing

@testable import Netti

/// Seeded fuzzing of `MultipartFormData` (TM-20): with random names, file names, MIME types,
/// boundaries and bodies, the encoded form either throws `encodingFailed` for exactly the inputs the
/// spec rejects, or frames every part with only its own `Content-Disposition` and `Content-Type`
/// lines and the body bytes unchanged.
@Suite("Fuzz: multipart form data", .timeLimit(.minutes(30)))
struct FuzzMultipartFormDataTests {

    // MARK: - Encoding

    @Test("given random parts and boundaries, when encoded, then invalid input throws and valid output has no injected header line")
    func randomParts_encodeSafelyOrThrow() async {
        await Fuzz.run("multipart.encode") { fuzz in
            let boundary = randomBoundary(using: &fuzz.random)
            let parts = (0..<fuzz.random.int(0...5)).map { _ in RandomPart.make(using: &fuzz.random) }
            var form = MultipartFormData(boundary: boundary)
            for part in parts {
                part.append(to: &form)
            }
            fuzz.input = "boundary=\(boundary.debugDescription) parts=\(FuzzCase.describe(parts))"

            let shouldThrow = boundary.map(isValidRFC2046Boundary) == false || parts.contains(where: \.isInvalid)
            let encoded: Data
            do throws(HTTPRequestError) {
                encoded = try form.encode()
            } catch {
                fuzz.check(isInvalidMultipartForm(error), "threw \(error), not encodingFailed(InvalidMultipartFormError)")
                fuzz.check(shouldThrow, "rejected a valid form: \(error)")
                return
            }
            fuzz.check(shouldThrow == false, "encoded a form the spec rejects")
            fuzz.check(
                form.contentType.utf8.contains { $0 == 0x0D || $0 == 0x0A || $0 == 0x00 } == false,
                "Content-Type carries CR, LF or NUL: \(form.contentType.debugDescription)"
            )
            if let length = try? form.contentLength() {
                fuzz.check(length == UInt64(encoded.count), "contentLength \(length) != encoded \(encoded.count)")
            }
            verifyFraming(encoded, boundary: form.boundary, parts: parts, in: &fuzz)
        }
    }

    /// TM-fuzz-2 (fixed): `"`, CR or LF in a part name or file name followed by a combining mark
    /// must still be escaped. Character-level replacement matched whole grapheme clusters and skipped
    /// them, so a name could close its quoted value and add parameters (`a"\u{301}; filename="evil.html`)
    /// or start a new header line (`a\n\u{301}Content-Type: text/html`). Escaping now runs on scalars.
    @Test("given a quote, CR or LF followed by a combining mark in a part name or file name, when encoded, then the header block is not broken")
    func markAfterEscapedCharacter_doesNotBreakHeaders() async {
        await Fuzz.run("multipart.mark") { fuzz in
            let mark = Unicode.Scalar(UInt32(fuzz.random.int(0x0300...0x036F))) ?? "\u{301}"
            let (special, payload) = fuzz.random.pick([
                ("\"", "; filename=\"evil.html"), ("\n", "Content-Type: text/html"), ("\r\n", "X-Injected: 1"), ("\r", "X: 1"),
            ])
            let injected = fuzz.random.string(maximumLength: 8, alphabet: .printableASCII)
                .replacingOccurrences(of: "\"", with: "") + special + String(Character(mark)) + payload
            let usesFileName = fuzz.random.chance(0.5)
            let part = RandomPart(
                kind: .data,
                name: usesFileName ? "file" : injected,
                fileName: usesFileName ? injected : nil,
                mimeType: "text/plain",
                body: Data("body".utf8)
            )
            var form = MultipartFormData()
            part.append(to: &form)
            fuzz.input = FuzzCase.describe(part)

            do throws(HTTPRequestError) {
                verifyFraming(try form.encode(), boundary: form.boundary, parts: [part], in: &fuzz)
            } catch {
                fuzz.fail("threw \(error)")
            }
        }
    }

    // MARK: - Private Helpers

    private func randomBoundary(using random: inout SeededRandom) -> String? {
        switch random.int(0...9) {
            case 0...2:
                return nil
            case 3...6:
                let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'()+_,-./:=? ")
                return String((0..<random.int(1...72)).map { _ in random.pick(alphabet) })
            default:
                return random.string(maximumLength: 80)
        }
    }

    /// RFC 2046 §5.1.1: 1 to 70 of `bcharsnospace` or space, not ending with a space.
    private func isValidRFC2046Boundary(_ boundary: String) -> Bool {
        let allowed = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'()+_,-./:=? ".unicodeScalars)
        return (1...70).contains(boundary.unicodeScalars.count)
            && boundary.unicodeScalars.allSatisfy(allowed.contains)
            && boundary.unicodeScalars.last != " "
    }

    private func isInvalidMultipartForm(_ error: HTTPRequestError) -> Bool {
        guard case .encodingFailed(let underlying) = error else {
            return false
        }
        return underlying is InvalidMultipartFormError
    }

    /// Walks the output by the known part sizes: each part is the opening boundary, a header block
    /// of exactly the expected lines, the unchanged body and CRLF; the form ends with the closing boundary.
    private func verifyFraming(_ encoded: Data, boundary: String, parts: [RandomPart], in fuzz: inout FuzzCase) {
        let bytes = [UInt8](encoded)
        var offset = 0
        let headerEnd: [UInt8] = Array("\r\n\r\n".utf8)

        func consume(_ expected: String) -> Bool {
            let expectedBytes = Array(expected.utf8)
            guard bytes.count - offset >= expectedBytes.count, Array(bytes[offset..<offset + expectedBytes.count]) == expectedBytes else {
                return false
            }
            offset += expectedBytes.count
            return true
        }

        for (index, part) in parts.enumerated() {
            guard consume("--\(boundary)\r\n") else {
                fuzz.fail("part \(index): opening boundary missing at \(offset)")
                return
            }
            guard let end = firstRange(of: headerEnd, in: bytes, from: offset) else {
                fuzz.fail("part \(index): header block not terminated")
                return
            }
            let block = Array(bytes[offset..<end])
            offset = end + headerEnd.count
            let lines = split(block, separator: Array("\r\n".utf8))
            verifyHeaderLines(lines, part: part, index: index, in: &fuzz)

            guard bytes.count - offset >= part.body.count, Data(bytes[offset..<offset + part.body.count]) == part.body else {
                fuzz.fail("part \(index): body changed")
                return
            }
            offset += part.body.count
            guard consume("\r\n") else {
                fuzz.fail("part \(index): body not followed by CRLF")
                return
            }
        }
        fuzz.check(consume("--\(boundary)--\r\n") && offset == bytes.count, "closing boundary missing or trailing bytes")
    }

    private func verifyHeaderLines(_ lines: [[UInt8]], part: RandomPart, index: Int, in fuzz: inout FuzzCase) {
        let expectsContentType = part.resolvedMimeType != nil
        fuzz.check(lines.count == (expectsContentType ? 2 : 1), "part \(index): \(lines.count) header lines")
        for line in lines {
            fuzz.check(line.contains { $0 == 0x0D || $0 == 0x0A || $0 == 0x00 } == false, "part \(index): header line holds CR, LF or NUL")
        }
        guard let first = lines.first else {
            return
        }
        let disposition = String(decoding: first, as: UTF8.self)
        fuzz.check(first.starts(with: Array("Content-Disposition: form-data; name=\"".utf8)), "part \(index): \(disposition.debugDescription)")
        let quotes = disposition.utf8.count(where: { $0 == UInt8(ascii: "\"") })
        fuzz.check(quotes == (part.fileName == nil ? 2 : 4), "part \(index): \(quotes) quotes, a parameter escaped its quotes")
        if let mimeType = part.mimeType, lines.count > 1 {
            fuzz.check(lines[1] == Array("Content-Type: \(mimeType)".utf8), "part \(index): Content-Type line changed")
        } else if lines.count > 1 {
            fuzz.check(lines[1].starts(with: Array("Content-Type: ".utf8)), "part \(index): second header is not Content-Type")
        }
    }

    private func firstRange(of needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= needle.count, start <= bytes.count - needle.count else {
            return nil
        }
        return (start...(bytes.count - needle.count)).first { Array(bytes[$0..<$0 + needle.count]) == needle }
    }

    private func split(_ bytes: [UInt8], separator: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var start = 0
        var index = 0
        while index + separator.count <= bytes.count {
            if Array(bytes[index..<index + separator.count]) == separator {
                lines.append(Array(bytes[start..<index]))
                index += separator.count
                start = index
            } else {
                index += 1
            }
        }
        lines.append(Array(bytes[start...]))
        return lines
    }
}

// MARK: - RandomPart

private struct RandomPart: CustomDebugStringConvertible {
    enum Kind {
        case text(String)
        case data
    }

    let kind: Kind
    let name: String
    let fileName: String?
    let mimeType: String?
    let body: Data

    static func make(using random: inout SeededRandom) -> RandomPart {
        let name = random.chance(0.2) ? random.pick(["a\"; filename=\"x.html", "x\r\nContent-Type: text/html", "n\0", "\"", "\\"]) : random.string(maximumLength: 24)
        if random.chance(0.3) {
            let text = random.string(maximumLength: 64)
            return RandomPart(kind: .text(text), name: name, fileName: nil, mimeType: nil, body: Data(text.utf8))
        }
        let fileName: String? = random.chance(0.6) ? random.string(maximumLength: 24) + random.pick(["", ".png", ".json", ".x\u{0}y", ".\u{1F600}"]) : nil
        let mimeType: String? = switch random.int(0...4) {
            case 0, 1:
                nil
            case 2:
                random.pick(["image/png", "text/plain; charset=utf-8", "text/html\r\nX-Injected: 1", "a\nb", "a\rb", "a\0b", ""])
            default:
                random.string(maximumLength: 32)
        }
        var body = random.bytes(count: random.length(upTo: 4_096))
        if random.chance(0.3) {
            body = random.mutate(body)
        }
        return RandomPart(kind: .data, name: name, fileName: fileName, mimeType: mimeType, body: body)
    }

    /// The MIME type written for this part: the given one, or the file name's, or none.
    var resolvedMimeType: String? {
        mimeType ?? (fileName == nil ? nil : "derived")
    }

    /// Whether the spec rejects the part: NUL in the name or file name, a control character other
    /// than tab in the MIME type.
    var isInvalid: Bool {
        name.unicodeScalars.contains("\0")
            || fileName?.unicodeScalars.contains("\0") == true
            || mimeType?.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F } == true
    }

    func append(to form: inout MultipartFormData) {
        switch kind {
            case .text(let text):
                form.append(text, name: name)
            case .data:
                form.append(body, name: name, fileName: fileName, mimeType: mimeType)
        }
    }

    var debugDescription: String {
        "Part(name: \(name.debugDescription), fileName: \(fileName.debugDescription), mimeType: \(mimeType.debugDescription), body: \(body.count) B)"
    }
}
