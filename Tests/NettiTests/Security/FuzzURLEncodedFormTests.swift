//
//  FuzzURLEncodedFormTests.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/10/26.
//

import Foundation
import NettiTesting
import Testing

@testable import Netti

/// Seeded fuzzing of `URLEncodedFormEncoder`: random nested values (any Unicode, depth up to 100)
/// encode and percent-decode back to the reference pairs at depth 32 or less, and throw
/// `EncodingError.invalidValue` deeper; through `buildRequest` the error is `encodingFailed` (TM-08).
@Suite("Fuzz: URL-encoded form", .timeLimit(.minutes(30)))
struct FuzzURLEncodedFormTests {

    private static let maximumDepth = 32

    // MARK: - Encoder

    @Test("given random nested values, when encoded, then the output decodes to the reference pairs or the depth error is thrown")
    func randomValues_roundTripOrThrow() async {
        await Fuzz.run("form.encoder") { fuzz in
            let value = FormValue.randomObject(using: &fuzz.random, depth: targetDepth(using: &fuzz.random))
            let encoder = URLEncodedFormEncoder(
                alphabetizeKeyValuePairs: fuzz.random.chance(0.7),
                arrayEncoding: fuzz.random.pick([.noBrackets, .brackets, .indexInBrackets]),
                spaceEncoding: fuzz.random.pick([.percentEscaped, .plusReplaced])
            )
            fuzz.input = "depth=\(value.depth) " + FuzzCase.describe(value)

            let output: String
            do {
                output = try encoder.encode(value)
            } catch let error as EncodingError {
                fuzz.check(value.depth > Self.maximumDepth || value.hasNonFiniteNumber, "threw \(error) at depth \(value.depth)")
                return
            } catch {
                fuzz.fail("threw \(String(reflecting: error)), not EncodingError")
                return
            }

            fuzz.check(value.depth <= Self.maximumDepth, "encoded depth \(value.depth), above \(Self.maximumDepth)")
            fuzz.check(value.hasNonFiniteNumber == false, "encoded a non-finite number")
            fuzz.check(output.allSatisfy { $0.isASCII && $0 != " " }, "output has unescaped characters: \(output.debugDescription)")
            let expected = value.pairs(encoder: encoder)
            let decoded = decodePairs(output, spaceEncoding: encoder.spaceEncoding)
            fuzz.check(decoded?.map(Pair.init) == expected.map(Pair.init), firstDifference(decoded, expected))
        }
    }

    // MARK: - Request Building

    /// Multiplier 0.25: every case builds a request through a `Netti` client.
    @Test("given random nested query parameters, when a GET is built, then it has the reference query or throws encodingFailed")
    func randomParameters_buildRequest() async {
        let netti = makeNetti()
        let iterations = Fuzz.iterations(multiplier: 0.25, minimum: 50)

        await Fuzz.run("form.request", iterations: iterations) { fuzz in
            let value = FormValue.randomObject(using: &fuzz.random, depth: targetDepth(using: &fuzz.random))
            fuzz.input = "depth=\(value.depth) " + FuzzCase.describe(value)

            do throws(HTTPRequestError) {
                let request = try netti.buildRequest(TestEndpoint(), parameters: value, method: .get)
                fuzz.check(value.depth <= Self.maximumDepth && value.hasNonFiniteNumber == false, "built a request at depth \(value.depth)")
                let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedQuery
                let decoded = query.map { decodePairs($0, spaceEncoding: .percentEscaped) } ?? []
                let expected = value.pairs(encoder: URLEncodedFormEncoder())
                fuzz.check(decoded?.map(Pair.init) == expected.map(Pair.init), firstDifference(decoded, expected))
            } catch {
                guard case .encodingFailed(let underlying) = error, underlying is EncodingError else {
                    fuzz.fail("threw \(error), not encodingFailed(EncodingError)")
                    return
                }
                fuzz.check(value.depth > Self.maximumDepth || value.hasNonFiniteNumber, "threw at depth \(value.depth)")
            }
        }
    }

    // MARK: - Private Helpers

    private struct Pair: Equatable {
        let key: [UInt8]
        let value: [UInt8]

        init(_ pair: (key: String, value: String)) {
            key = Array(pair.key.utf8)
            value = Array(pair.value.utf8)
        }
    }

    /// The first pair where the decoded output and the reference differ.
    private func firstDifference(_ decoded: [(key: String, value: String)]?, _ expected: [(key: String, value: String)]) -> String {
        guard let decoded else {
            return "output did not percent-decode"
        }
        let index = Array(zip(decoded, expected)).firstIndex { Pair($0.0) != Pair($0.1) } ?? min(decoded.count, expected.count)
        let actual = index < decoded.count ? "\(decoded[index])" : "none"
        let reference = index < expected.count ? "\(expected[index])" : "none"
        return "pair \(index) of \(decoded.count)/\(expected.count): decoded \(actual) != reference \(reference)"
    }

    /// Skewed towards the cap: half the cases sit within two levels of it, the rest anywhere in 0...100.
    private func targetDepth(using random: inout SeededRandom) -> Int {
        random.chance(0.5) ? random.int((Self.maximumDepth - 2)...(Self.maximumDepth + 2)) : random.int(0...100)
    }

    /// Percent-decodes to bytes and validates them as UTF-8. Foundation's `removingPercentEncoding`
    /// is not used: it drops a leading U+FEFF, which would hide or fake a mismatch.
    private func percentDecoded(_ text: String) -> String? {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "%") else {
                bytes.append(byte)
                continue
            }
            guard let high = iterator.next(), let low = iterator.next(),
                  let value = UInt8(String(decoding: [high, low] as [UInt8], as: UTF8.self), radix: 16)
            else {
                return nil
            }
            bytes.append(value)
        }
        let text = String(decoding: bytes, as: UTF8.self)
        return Array(text.utf8) == bytes ? text : nil
    }

    /// Splits on `&` and `=` with `URLComponents`, then percent-decodes each side; `nil` when a
    /// side does not decode.
    private func decodePairs(_ query: String, spaceEncoding: URLEncodedFormEncoder.SpaceEncoding) -> [(key: String, value: String)]? {
        guard query.isEmpty == false else {
            return []
        }
        var components = URLComponents()
        components.percentEncodedQuery = spaceEncoding == .plusReplaced ? query.replacingOccurrences(of: "+", with: "%20") : query
        var pairs: [(key: String, value: String)] = []
        for item in components.percentEncodedQueryItems ?? [] {
            guard let key = percentDecoded(item.name), let value = percentDecoded(item.value ?? "") else {
                return nil
            }
            pairs.append((key, value))
        }
        return pairs
    }
}

// MARK: - FormValue

/// A random `Encodable` tree: strings with any Unicode, numbers, booleans, nulls, arrays and objects.
private indirect enum FormValue: Encodable, Sendable, CustomDebugStringConvertible {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case number(Double)
    case null
    case array([FormValue])
    case object([(key: String, value: FormValue)])

    // MARK: - Generation

    /// An object whose deepest non-null value sits at `depth` (0 = the object holds no values).
    static func randomObject(using random: inout SeededRandom, depth: Int) -> FormValue {
        .object(members(using: &random, spineDepth: depth))
    }

    private static func members(using random: inout SeededRandom, spineDepth: Int) -> [(key: String, value: FormValue)] {
        guard spineDepth > 0 else {
            return []
        }
        var keys = Set<String>()
        var members: [(key: String, value: FormValue)] = []
        let spineKey = uniqueKey(using: &random, avoiding: &keys)
        members.append((spineKey, spine(using: &random, depth: spineDepth - 1)))
        for _ in 0..<random.int(0...2) {
            members.append((uniqueKey(using: &random, avoiding: &keys), leafish(using: &random)))
        }
        return random.chance(0.5) ? members.reversed() : members
    }

    /// A value whose own deepest descendant is `depth` levels below it.
    private static func spine(using random: inout SeededRandom, depth: Int) -> FormValue {
        guard depth > 0 else {
            return scalar(using: &random)
        }
        if random.chance(0.5) {
            var elements = (0..<random.int(0...2)).map { _ in random.chance(0.3) ? FormValue.null : leafish(using: &random) }
            elements.insert(spine(using: &random, depth: depth - 1), at: random.int(0...elements.count))
            return .array(elements)
        }
        return .object(members(using: &random, spineDepth: depth))
    }

    /// A scalar, a null, or a shallow array of scalars.
    private static func leafish(using random: inout SeededRandom) -> FormValue {
        switch random.int(0...5) {
            case 0:
                .null
            case 1:
                .array((0..<random.int(0...3)).map { _ in random.chance(0.2) ? .null : scalar(using: &random) })
            default:
                scalar(using: &random)
        }
    }

    private static func scalar(using random: inout SeededRandom) -> FormValue {
        switch random.int(0...9) {
            case 0:
                .integer(random.pick([0, -1, .max, .min, random.int(-1_000...1_000)]))
            case 1:
                .boolean(random.chance(0.5))
            case 2:
                .number(random.chance(0.97) ? Double(random.int(-1_000_000...1_000_000)) / 64 : random.pick([.infinity, -.infinity, .nan]))
            default:
                .string(random.string(maximumLength: 24))
        }
    }

    private static func uniqueKey(using random: inout SeededRandom, avoiding keys: inout Set<String>) -> String {
        while true {
            let key = random.chance(0.3) ? random.pick(["a", "b", "id", "a[b]", "0", "", "[]", "k=v", "x&y"]) : random.string(maximumLength: 12)
            if keys.insert(key).inserted {
                return key
            }
        }
    }

    // MARK: - Reference

    /// The depth of the deepest non-null value; the root object is depth 0.
    var depth: Int {
        switch self {
            case .array(let elements):
                elements.compactMap { $0.isNull ? nil : $0.depth + 1 }.max() ?? 0
            case .object(let members):
                members.compactMap { $0.value.isNull ? nil : $0.value.depth + 1 }.max() ?? 0
            default:
                0
        }
    }

    var hasNonFiniteNumber: Bool {
        switch self {
            case .number(let number):
                number.isFinite == false
            case .array(let elements):
                elements.contains(where: \.hasNonFiniteNumber)
            case .object(let members):
                members.contains { $0.value.hasNonFiniteNumber }
            default:
                false
        }
    }

    /// The pairs the documented encoding produces: bracketed object keys, array keys per strategy,
    /// nulls and empty containers omitted, keys sorted when alphabetized.
    func pairs(encoder: URLEncodedFormEncoder) -> [(key: String, value: String)] {
        guard case .object(let members) = self else {
            return []
        }
        return sorted(members, encoder: encoder).flatMap { $0.value.pairs(key: $0.key, encoder: encoder) }
    }

    private func pairs(key: String, encoder: URLEncodedFormEncoder) -> [(key: String, value: String)] {
        switch self {
            case .string(let string):
                [(key, string)]
            case .integer(let integer):
                [(key, String(integer))]
            case .boolean(let boolean):
                [(key, boolean ? "true" : "false")]
            case .number(let number):
                [(key, String(describing: number))]
            case .null:
                []
            case .array(let elements):
                elements.enumerated().flatMap { index, element in
                    element.pairs(key: encoder.arrayEncoding.key(key, index: index), encoder: encoder)
                }
            case .object(let members):
                sorted(members, encoder: encoder).flatMap { $0.value.pairs(key: "\(key)[\($0.key)]", encoder: encoder) }
        }
    }

    private func sorted(_ members: [(key: String, value: FormValue)], encoder: URLEncodedFormEncoder) -> [(key: String, value: FormValue)] {
        encoder.alphabetizeKeyValuePairs ? members.sorted { $0.key < $1.key } : members
    }

    private var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    var debugDescription: String {
        switch self {
            case .string(let string):
                string.debugDescription
            case .integer(let integer):
                String(integer)
            case .boolean(let boolean):
                String(boolean)
            case .number(let number):
                String(number)
            case .null:
                "nil"
            case .array(let elements):
                "[" + elements.map(\.debugDescription).joined(separator: ", ") + "]"
            case .object(let members):
                "{" + members.map { "\($0.key.debugDescription): \($0.value.debugDescription)" }.joined(separator: ", ") + "}"
        }
    }

    // MARK: - Encodable

    func encode(to encoder: any Encoder) throws {
        switch self {
            case .string(let string):
                var container = encoder.singleValueContainer()
                try container.encode(string)
            case .integer(let integer):
                var container = encoder.singleValueContainer()
                try container.encode(integer)
            case .boolean(let boolean):
                var container = encoder.singleValueContainer()
                try container.encode(boolean)
            case .number(let number):
                var container = encoder.singleValueContainer()
                try container.encode(number)
            case .null:
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            case .array(let elements):
                var container = encoder.unkeyedContainer()
                for element in elements {
                    if element.isNull {
                        try container.encodeNil()
                    } else {
                        try container.encode(element)
                    }
                }
            case .object(let members):
                var container = encoder.container(keyedBy: DynamicKey.self)
                for member in members {
                    if member.value.isNull {
                        try container.encodeNil(forKey: DynamicKey(member.key))
                    } else {
                        try container.encode(member.value, forKey: DynamicKey(member.key))
                    }
                }
        }
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }
}
