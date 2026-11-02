//
//  FuzzJSONDecodingTests.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/10/26.
//

import Foundation
import Testing

@testable import Netti

/// Seeded fuzzing of response decoding: malformed, huge (several MB) and deeply nested (10,000
/// levels) JSON never traps; `JSONManager` throws `DecodingError` and `Netti.decode` throws
/// `decodingFailed`.
@Suite("Fuzz: JSON decoding", .timeLimit(.minutes(30)))
struct FuzzJSONDecodingTests {

    private struct Item: Codable, Equatable, Sendable {
        let id: Int
        let name: String
        let tags: [String]?
        let child: [String: Double]?
    }

    // MARK: - Malformed

    @Test("given mutated and random JSON, when decoded, then it decodes or throws a decoding error")
    func malformedJSON_throwsDecodingError() async {
        let manager = JSONManager()
        let netti = makeNetti(jsonManager: manager)

        await Fuzz.run("json.malformed") { fuzz in
            let data = JSONGenerator.malformed(using: &fuzz.random)
            fuzz.input = FuzzCase.describe(String(decoding: data, as: UTF8.self))

            checkDecoding(Item.self, data, manager: manager, netti: netti, in: &fuzz)
            checkDecoding(JSONValue.self, data, manager: manager, netti: netti, in: &fuzz)
        }
    }

    // MARK: - Nesting

    /// Multiplier 0.05 (minimum 10): every case builds about 10,000 levels of nesting.
    @Test("given JSON nested up to 10,000 levels, when decoded, then it throws a decoding error without trapping")
    func deeplyNested_throwsDecodingError() async {
        let manager = JSONManager()
        let netti = makeNetti(jsonManager: manager)
        let iterations = Fuzz.iterations(multiplier: 0.05, minimum: 10)

        await Fuzz.run("json.nested", iterations: iterations, timeLimitPerCase: .seconds(10)) { fuzz in
            let depth = fuzz.random.chance(0.5) ? 10_000 : fuzz.random.int(513...10_000)
            let data = JSONGenerator.nested(depth: depth, using: &fuzz.random)
            fuzz.input = "depth=\(depth) prefix=\(String(decoding: data.prefix(24), as: UTF8.self))"

            for outcome in [decodeOutcome(JSONValue.self, data, manager: manager), decodeOutcome(Item.self, data, manager: manager)] {
                fuzz.check(outcome == .decodingError, "decoding \(depth) levels: \(outcome)")
            }
            checkDecoding(JSONValue.self, data, manager: manager, netti: netti, in: &fuzz)
        }
    }

    // MARK: - Size

    /// Multiplier 0.01 (minimum 4): every case builds 2 to 6 MB of JSON.
    @Test("given several megabytes of JSON, valid or cut, when decoded, then valid input decodes and cut input throws a decoding error")
    func hugeJSON_decodesOrThrows() async {
        let manager = JSONManager()
        let netti = makeNetti(jsonManager: manager)
        let iterations = Fuzz.iterations(multiplier: 0.01, minimum: 4)

        await Fuzz.run("json.huge", iterations: iterations, timeLimitPerCase: .seconds(30)) { fuzz in
            let size = fuzz.random.int(2_000_000...6_000_000)
            let valid = JSONGenerator.huge(size: size, using: &fuzz.random)
            let isCut = fuzz.random.chance(0.5)
            let data = isCut ? valid.prefix(fuzz.random.int(1...(valid.count - 1))) : valid
            fuzz.input = "size=\(data.count) cut=\(isCut)"

            let outcome = decodeOutcome(Item.self, data, manager: manager)
            fuzz.check(outcome == (isCut ? .decodingError : .decoded), "\(data.count) B, cut=\(isCut): \(outcome)")
            checkDecoding(Item.self, data, manager: manager, netti: netti, in: &fuzz)
        }
    }

    // MARK: - Private Helpers

    private enum Outcome: Equatable {
        case decoded
        case decodingError
        case otherError(String)
    }

    private func decodeOutcome<Value: Decodable>(_ type: Value.Type, _ data: Data, manager: JSONManager) -> Outcome {
        do {
            _ = try manager.decode(type, from: data)
            return .decoded
        } catch is DecodingError {
            return .decodingError
        } catch {
            return .otherError(String(reflecting: error))
        }
    }

    /// `JSONManager` throws only `DecodingError`; `Netti.decode` agrees and wraps it in `decodingFailed`.
    private func checkDecoding<Value: Decodable & Sendable>(
        _ type: Value.Type,
        _ data: Data,
        manager: JSONManager,
        netti: Netti,
        in fuzz: inout FuzzCase
    ) {
        let outcome = decodeOutcome(type, data, manager: manager)
        if case .otherError(let error) = outcome {
            fuzz.fail("JSONManager threw \(error), not DecodingError")
        }
        do throws(HTTPRequestError) {
            let _: HTTPResponse<Value> = try netti.decode(data, request: nil)
            fuzz.check(outcome == .decoded, "Netti decoded what JSONManager rejected")
        } catch {
            guard case .decodingFailed(let underlying, _) = error, underlying is DecodingError else {
                fuzz.fail("Netti threw \(error), not decodingFailed(DecodingError)")
                return
            }
            fuzz.check(outcome == .decodingError, "Netti rejected what JSONManager decoded")
        }
    }
}

// MARK: - JSONValue

/// Any JSON value, decoded recursively.
private indirect enum JSONValue: Decodable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}

// MARK: - JSONGenerator

private enum JSONGenerator {
    private static let seeds: [String] = [
        #"{"id":1,"name":"a","tags":["x","y"],"child":{"k":1.5}}"#,
        #"{"id":-9223372036854775808,"name":"\u0000😀","tags":[],"child":null}"#,
        #"[{"id":1,"name":""},{"id":2,"name":"\"\\\/\b\f\n\r\t"}]"#,
        #"{"id":1e400,"name":"x"}"#,
        #"{"id":1,"name":"x","name":"y"}"#,
        #"{"id":9223372036854775808,"name":"overflow"}"#,
        #""\ud800""#,
        "true", "null", "0", "-0.0e-0",
    ]

    private static let fragments: [Data] = [
        "{", "}", "[", "]", ",", ":", "\"", "\\", "\\u", "\\ud800", "nul", "tru", "1e", "-", "NaN", "Infinity",
        "\u{FEFF}", "\0", "/*", "//", ",]", ",}",
    ].map { Data($0.utf8) }

    static func malformed(using random: inout SeededRandom) -> Data {
        switch random.int(0...9) {
            case 0:
                return random.bytes(count: random.length(upTo: 512))
            case 1:
                return random.utf8Bytes(maximumLength: 128)
            default:
                let seed = Data(random.pick(seeds).utf8)
                return random.mutate(seed, times: random.int(0...4), fragments: fragments)
        }
    }

    /// `depth` opening brackets or `{"a":` keys, then a scalar and the matching closers;
    /// sometimes the closers are missing.
    static func nested(depth: Int, using random: inout SeededRandom) -> Data {
        let usesObjects = random.chance(0.5)
        var text = String(repeating: usesObjects ? #"{"a":"# : "[", count: depth)
        text += "1"
        if random.chance(0.8) {
            text += String(repeating: usesObjects ? "}" : "]", count: depth)
        }
        return Data(text.utf8)
    }

    /// A valid `Item` of about `size` bytes: a long name, many tags, or a wide child object.
    static func huge(size: Int, using random: inout SeededRandom) -> Data {
        switch random.int(0...2) {
            case 0:
                let name = String(repeating: random.pick(["a", "é", "😀", "\\n", "\\u0041"]), count: size / 6)
                return Data(#"{"id":1,"name":"\#(name)"}"#.utf8)
            case 1:
                let tags = Array(repeating: #""tag""#, count: size / 6).joined(separator: ",")
                return Data(#"{"id":2,"name":"t","tags":[\#(tags)]}"#.utf8)
            default:
                let members = (0..<(size / 16)).map { #""k\#($0)":\#($0).5"# }.joined(separator: ",")
                return Data(#"{"id":3,"name":"c","child":{\#(members)}}"#.utf8)
        }
    }
}
