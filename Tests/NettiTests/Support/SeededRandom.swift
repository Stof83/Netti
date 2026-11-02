//
//  SeededRandom.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/10/26.
//

import Foundation
import Testing

// MARK: - SeededRandom

/// A SplitMix64 generator: fast, tiny state, and the same sequence for the same seed on every
/// platform, so a fuzz case replays from its seed alone.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

// MARK: - Primitives

extension SeededRandom {
    /// A uniform integer in `range`.
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    /// `true` with probability `probability`.
    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }

    /// A uniform element of a non-empty array.
    mutating func pick<Element>(_ elements: [Element]) -> Element {
        elements[int(0...(elements.count - 1))]
    }

    /// A length skewed towards small values, with a tail up to `maximum`: most inputs stay
    /// cheap while every run still reaches the large ones.
    mutating func length(upTo maximum: Int) -> Int {
        let roll = int(0...99)
        switch roll {
            case 0..<55:
                return int(0...min(8, maximum))
            case 55..<85:
                return int(0...min(64, maximum))
            case 85..<97:
                return int(0...min(1_024, maximum))
            default:
                return int(0...maximum)
        }
    }

    /// `count` uniform random bytes.
    mutating func bytes(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in buffer.indices {
                buffer[index] = UInt8.random(in: 0...UInt8.max, using: &self)
            }
        }
        return data
    }
}

// MARK: - Strings

extension SeededRandom {
    /// The characters a random string draws from.
    enum Alphabet {
        /// Printable ASCII, `0x20...0x7E`.
        case printableASCII
        /// All of ASCII, controls, CR, LF and NUL included.
        case ascii
        /// Every class below, combining marks excluded.
        case unicodeWithoutCombiningMarks
        /// Every class: ASCII, controls, Latin-1, combining marks, BMP, astral, specials.
        case unicode
    }

    /// Scalars that break naive parsers: line and paragraph separators, BOM, noncharacters,
    /// zero-width and bidi overrides, the replacement character.
    static let specialScalars: [Unicode.Scalar] = [
        "\u{0085}", "\u{00A0}", "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{FFFD}", "\u{FFFE}", "\u{FFFF}",
        "\u{200B}", "\u{200D}", "\u{202E}", "\u{3000}", "\u{1F600}", "\u{10FFFF}", "\u{E000}",
    ]

    /// One scalar of `alphabet`.
    mutating func scalar(_ alphabet: Alphabet) -> Unicode.Scalar {
        switch alphabet {
            case .printableASCII:
                return Unicode.Scalar(UInt8(int(0x20...0x7E)))
            case .ascii:
                if chance(0.15) {
                    return pick(["\r", "\n", "\0", "\t"])
                }
                return Unicode.Scalar(UInt8(int(0x00...0x7F)))
            case .unicodeWithoutCombiningMarks, .unicode:
                let allowsCombining = alphabet == .unicode
                switch int(0...9) {
                    case 0...3:
                        return scalar(.ascii)
                    case 4:
                        return Unicode.Scalar(UInt8(int(0x80...0xFF)))
                    case 5 where allowsCombining:
                        return Unicode.Scalar(UInt32(int(0x0300...0x036F))) ?? "?"
                    case 6:
                        return pick(Self.specialScalars)
                    case 7:
                        return Unicode.Scalar(UInt32(int(0x1_0000...0x10_FFFF))) ?? "?"
                    default:
                        let value = UInt32(int(0x0100...0xFFFD))
                        let scalar = Unicode.Scalar(value) ?? "?"
                        if allowsCombining == false, Self.isCombiningMark(scalar) {
                            return "?"
                        }
                        return scalar
                }
        }
    }

    /// A string of up to `maximumLength` scalars from `alphabet`.
    mutating func string(maximumLength: Int, alphabet: Alphabet = .unicode) -> String {
        let count = length(upTo: maximumLength)
        var scalars = String.UnicodeScalarView()
        for _ in 0..<count {
            scalars.append(scalar(alphabet))
        }
        return String(scalars)
    }

    /// Byte sequences that are not valid UTF-8: a lone continuation byte, an overlong encoding, a
    /// surrogate, a code point above U+10FFFF, a byte that never appears, truncated sequences.
    static let invalidUTF8Sequences: [[UInt8]] = [
        [0x80], [0xBF], [0xC0, 0x80], [0xC1, 0xBF], [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80],
        [0xF4, 0x90, 0x80, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80], [0xFE], [0xFF], [0xE2, 0x82], [0xF0, 0x9F],
    ]

    /// Up to `maximumLength` scalars as UTF-8, with invalid sequences mixed in.
    mutating func utf8Bytes(maximumLength: Int, alphabet: Alphabet = .unicode) -> Data {
        let count = length(upTo: maximumLength)
        var data = Data()
        for _ in 0..<count {
            if chance(0.1) {
                data.append(contentsOf: pick(Self.invalidUTF8Sequences))
            } else {
                data.append(contentsOf: Array(String(scalar(alphabet)).utf8))
            }
        }
        return data
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                true
            default:
                false
        }
    }
}

// MARK: - Mutations

extension SeededRandom {
    /// Fragments that look like framing in the formats under test: line breaks, multipart
    /// boundaries and headers, SSE fields, percent-escapes, quotes and NUL.
    static let framingFragments: [Data] = [
        "\r\n", "\n", "\r", "\r\n\r\n", "\0", "--", "\r\n--", "--\r\n", "\"", "%0D%0A", "%00",
        ": ", "Content-Type: text/html", "Content-Disposition: form-data; name=\"x\"", "data:", "retry: 99999999999",
        "id:\0", "\u{FEFF}", "[", "{", "]", "}", "\\", "\\u0000",
    ].map { Data($0.utf8) }

    /// `data` with one random mutation: a bit flip, an interesting byte, truncation, deletion,
    /// a duplicated range or an inserted framing fragment.
    mutating func mutate(_ data: Data, fragments: [Data] = framingFragments) -> Data {
        var bytes = [UInt8](data)
        switch int(0...6) {
            case 0 where bytes.isEmpty == false:
                let index = int(0...(bytes.count - 1))
                bytes[index] ^= UInt8(1) << UInt8(int(0...7))
            case 1 where bytes.isEmpty == false:
                bytes[int(0...(bytes.count - 1))] = pick([0x00, 0x7F, 0x80, 0xFF, 0x0A, 0x0D, 0x22, 0x30])
            case 2:
                bytes = Array(bytes.prefix(int(0...bytes.count)))
            case 3 where bytes.isEmpty == false:
                let start = int(0...(bytes.count - 1))
                let end = int(start...min(bytes.count, start + 64))
                bytes.removeSubrange(start..<end)
            case 4 where bytes.isEmpty == false:
                let start = int(0...(bytes.count - 1))
                let end = int(start...min(bytes.count, start + 64))
                bytes.insert(contentsOf: bytes[start..<end], at: int(0...bytes.count))
            default:
                bytes.insert(contentsOf: pick(fragments), at: int(0...bytes.count))
        }
        return Data(bytes)
    }

    /// `data` after `count` random mutations.
    mutating func mutate(_ data: Data, times count: Int, fragments: [Data] = framingFragments) -> Data {
        (0..<count).reduce(data) { mutated, _ in mutate(mutated, fragments: fragments) }
    }

    /// Cuts `data` into random chunks, sometimes one byte at a time.
    mutating func chunks(of data: Data, maximumChunk: Int = 64) -> [Data] {
        var chunks: [Data] = []
        var start = data.startIndex
        let drips = chance(0.1)
        while start < data.endIndex {
            let size = drips ? 1 : int(0...maximumChunk)
            let end = min(data.endIndex, start + size)
            chunks.append(data[start..<end])
            start = end
        }
        if chance(0.2) {
            chunks.insert(Data(), at: int(0...chunks.count))
        }
        return chunks
    }
}

// MARK: - Fuzz Configuration

/// Settings and the case runner shared by the fuzz suites in `Tests/NettiTests/Security`.
///
/// - `NETTI_FUZZ_ITERATIONS`: cases per fuzz test, 200 by default. Heavy targets run
///   `iterations × multiplier` cases (never fewer than their minimum); each test documents its multiplier.
/// - `NETTI_FUZZ_SEED`: the base seed, decimal or `0x` hex. Each case derives its own seed from the
///   base seed, the target name and its index.
/// - `NETTI_FUZZ_REPLAY`: one case seed, as printed in a failure (`seed=0x…`). Every fuzz test then
///   runs only that case; filter to the failing test to replay it.
enum Fuzz {
    /// The base seed when `NETTI_FUZZ_SEED` is not set.
    static let defaultSeed: UInt64 = 0x4E45_5454_4946_555A

    /// The base seed of this run.
    static let baseSeed: UInt64 = environmentSeed("NETTI_FUZZ_SEED") ?? defaultSeed

    /// The case count of a regular target.
    static let iterations: Int = ProcessInfo.processInfo.environment["NETTI_FUZZ_ITERATIONS"]
        .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        .map { max(1, $0) } ?? 200

    /// The single case seed to replay, when set.
    static let replaySeed: UInt64? = environmentSeed("NETTI_FUZZ_REPLAY")

    /// Failing cases reported in full per test; the rest are counted.
    private static let reportedFailureLimit = 5

    /// The case count of a target that runs `multiplier` times the regular count.
    static func iterations(multiplier: Double, minimum: Int = 1) -> Int {
        max(min(minimum, iterations), Int((Double(iterations) * multiplier).rounded(.up)))
    }

    /// The seed of case `index` of `target`.
    static func caseSeed(target: String, index: Int) -> UInt64 {
        var mixer = SeededRandom(seed: baseSeed ^ fnv1a(target) ^ UInt64(truncatingIfNeeded: index) &* 0x2545_F491_4F6C_DD1D)
        return mixer.next()
    }

    /// Runs `iterations` cases of `target`, each with its own seeded generator.
    ///
    /// A violation, an error escaping `body`, or a case slower than `timeLimitPerCase` is
    /// recorded as an issue naming the case seed, so `NETTI_FUZZ_REPLAY=<seed>` replays it.
    static func run(
        _ target: String,
        iterations: Int = Fuzz.iterations,
        timeLimitPerCase: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: (inout FuzzCase) async throws -> Void
    ) async {
        let seeds: [(index: Int, seed: UInt64)] = if let replaySeed {
            [(0, replaySeed)]
        } else {
            (0..<iterations).map { ($0, caseSeed(target: target, index: $0)) }
        }

        var failingCases = 0
        let clock = ContinuousClock()
        for (index, seed) in seeds {
            // Most targets never suspend; yielding keeps them from starving the cooperative pool,
            // which would stall the suites that await URLSession or actors and fail their time bound.
            await Task.yield()
            var fuzzCase = FuzzCase(index: index, seed: seed)
            let start = clock.now
            do {
                try await body(&fuzzCase)
            } catch {
                fuzzCase.fail("unexpected error escaped the case: \(String(reflecting: error))")
            }
            let elapsed = clock.now - start
            if elapsed > timeLimitPerCase {
                fuzzCase.fail("case took \(elapsed), above the \(timeLimitPerCase) bound")
            }
            guard fuzzCase.violations.isEmpty == false else {
                continue
            }
            failingCases += 1
            if failingCases <= reportedFailureLimit {
                Issue.record(
                    Comment(rawValue: fuzzCase.report(target: target)),
                    sourceLocation: sourceLocation
                )
            }
        }
        if failingCases > reportedFailureLimit {
            Issue.record(
                "\(target): \(failingCases - reportedFailureLimit) more failing cases (base seed=\(hex(baseSeed)))",
                sourceLocation: sourceLocation
            )
        }
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    private static func environmentSeed(_ name: String) -> UInt64? {
        guard let raw = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespaces), raw.isEmpty == false else {
            return nil
        }
        if raw.lowercased().hasPrefix("0x") {
            return UInt64(raw.dropFirst(2), radix: 16)
        }
        return UInt64(raw)
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
}

// MARK: - FuzzCase

/// One fuzz case: its generator and the invariant violations it found.
struct FuzzCase {
    let index: Int
    let seed: UInt64
    var random: SeededRandom

    /// A short description of the input, shown with any violation.
    var input = ""

    private(set) var violations: [String] = []

    init(index: Int, seed: UInt64) {
        self.index = index
        self.seed = seed
        self.random = SeededRandom(seed: seed)
    }

    /// Records `message` when `condition` is false.
    mutating func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition == false {
            violations.append(message())
        }
    }

    /// Records `message` as a violation.
    mutating func fail(_ message: String) {
        violations.append(message)
    }

    /// Describes `value` for ``input``, cut to a readable length.
    static func describe(_ value: some Any, limit: Int = 400) -> String {
        let text = String(reflecting: value)
        return text.count > limit ? "\(text.prefix(limit))… (\(text.count) chars)" : text
    }

    func report(target: String) -> String {
        "\(target) seed=\(Fuzz.hex(seed)) case=\(index) base=\(Fuzz.hex(Fuzz.baseSeed)) "
            + "[replay: NETTI_FUZZ_REPLAY=\(Fuzz.hex(seed))]: "
            + violations.prefix(3).joined(separator: " | ")
            + (input.isEmpty ? "" : " | input=\(input)")
    }
}

// MARK: - FuzzSequence

/// An `AsyncSequence` over fixed elements, for feeding stream parsers without a network.
struct FuzzSequence<Element: Sendable>: AsyncSequence, Sendable {
    let elements: [Element]

    init(_ elements: [Element]) {
        self.elements = elements
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(elements: elements)
    }

    struct Iterator: AsyncIteratorProtocol {
        let elements: [Element]
        var index = 0

        mutating func next() async -> Element? {
            guard index < elements.count else {
                return nil
            }
            defer { index += 1 }
            return elements[index]
        }
    }
}
