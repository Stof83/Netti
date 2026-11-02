//
//  FuzzLineSequenceTests.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/10/26.
//

import Foundation
import Testing

@testable import Netti

/// Seeded fuzzing of `AsyncLineSequence`: random bytes in random chunks (CRLF split across chunks
/// included) yield exactly the reference split under the cap, and a line above the cap throws
/// `requestFailed(dataLengthExceedsMaximum)` after yielding only lines that precede it.
@Suite("Fuzz: line sequence", .timeLimit(.minutes(30)))
struct FuzzLineSequenceTests {

    // MARK: - Random Bytes

    @Test("given random bytes in random chunks, when split into lines, then the lines match the reference split")
    func randomBytes_matchReference() async {
        await Fuzz.run("lines.random") { fuzz in
            let maximumLineLength = fuzz.random.pick([1, 2, 8, 64, 1_024, 1_048_576])
            let body = randomBody(using: &fuzz.random)
            let chunks = fuzz.random.chunks(of: body, maximumChunk: fuzz.random.pick([1, 3, 16, 256]))
            fuzz.input = FuzzCase.describe(body)

            let outcome = await split(chunks, maximumLineLength: maximumLineLength)
            verify(outcome, body: body, maximumLineLength: maximumLineLength, in: &fuzz)
        }
    }

    @Test("given CRLF line breaks cut between CR and LF, when split into lines, then no line keeps a CR or loses a byte")
    func crlfCutBetweenChunks_matchReference() async {
        await Fuzz.run("lines.crlf") { fuzz in
            let lines = (0..<fuzz.random.int(1...12)).map { _ in
                fuzz.random.utf8Bytes(maximumLength: 24, alphabet: .unicodeWithoutCombiningMarks)
            }
            var body = Data()
            var cuts: [Int] = []
            for line in lines {
                body.append(line)
                body.append(UInt8(ascii: "\r"))
                cuts.append(body.count)
                body.append(UInt8(ascii: "\n"))
            }
            let chunks = zip([0] + cuts, cuts + [body.count]).map { body[$0..<$1] }
            fuzz.input = FuzzCase.describe(body)

            let outcome = await split(chunks, maximumLineLength: 1_048_576)
            verify(outcome, body: body, maximumLineLength: 1_048_576, in: &fuzz)
        }
    }

    // MARK: - Cap

    /// Multiplier 0.02 (minimum 4): every case builds a line of about 1 MB.
    @Test("given a line at the 1 MB default cap plus or minus two bytes, when split, then only a line above the cap throws")
    func lineAroundDefaultCap_throwsOnlyAbove() async {
        let iterations = Fuzz.iterations(multiplier: 0.02, minimum: 4)

        await Fuzz.run("lines.cap", iterations: iterations, timeLimitPerCase: .seconds(20)) { fuzz in
            let delta = fuzz.random.int(-2...2)
            var body = Data(repeating: UInt8(ascii: "a"), count: LineSplitter.defaultMaximumLineLength + delta)
            let terminator = fuzz.random.pick(["", "\n", "\r\n", "\r"])
            body.append(contentsOf: Array(terminator.utf8))
            let chunks = fuzz.random.chunks(of: body, maximumChunk: 65_536)
            fuzz.input = "delta=\(delta) terminator=\(terminator.debugDescription) chunks=\(chunks.count)"

            let outcome = await split(chunks, maximumLineLength: LineSplitter.defaultMaximumLineLength)
            verify(outcome, body: body, maximumLineLength: LineSplitter.defaultMaximumLineLength, in: &fuzz)
        }
    }

    /// Multiplier 0.01 (minimum 2): every case drips up to 1 MB in chunks of at most 16 bytes.
    @Test("given a long line dripped a few bytes at a time, when split, then it completes in linear time")
    func longLineDripped_isLinear() async {
        let iterations = Fuzz.iterations(multiplier: 0.01, minimum: 2)

        await Fuzz.run("lines.drip", iterations: iterations, timeLimitPerCase: .seconds(20)) { fuzz in
            let length = fuzz.random.int(65_536...LineSplitter.defaultMaximumLineLength)
            let body = Data(repeating: UInt8(ascii: "z"), count: length) + Data("\n".utf8)
            var chunks: [Data] = []
            var start = 0
            while start < body.count {
                let end = min(body.count, start + fuzz.random.int(1...16))
                chunks.append(body[start..<end])
                start = end
            }
            fuzz.input = "length=\(length) chunks=\(chunks.count)"

            let outcome = await split(chunks, maximumLineLength: LineSplitter.defaultMaximumLineLength)
            verify(outcome, body: body, maximumLineLength: LineSplitter.defaultMaximumLineLength, in: &fuzz)
        }
    }

    // MARK: - Private Helpers

    private struct Outcome {
        let lines: [[UInt8]]
        let error: (any Error)?
    }

    private func randomBody(using random: inout SeededRandom) -> Data {
        var body = Data()
        for _ in 0..<random.int(0...16) {
            if random.chance(0.5) {
                body.append(random.utf8Bytes(maximumLength: 40, alphabet: .unicodeWithoutCombiningMarks))
            } else {
                body.append(random.bytes(count: random.length(upTo: 2_048)))
            }
            body.append(contentsOf: Array(random.pick(["\n", "\r\n", "\r", "\r\r\n", "\n\n", ""]).utf8))
        }
        return body
    }

    private func split(_ chunks: [Data], maximumLineLength: Int) async -> Outcome {
        var lines: [[UInt8]] = []
        do {
            for try await line in AsyncLineSequence(FuzzSequence(chunks), maximumLineLength: maximumLineLength) {
                lines.append(Array(line.utf8))
            }
            return Outcome(lines: lines, error: nil)
        } catch {
            return Outcome(lines: lines, error: error)
        }
    }

    private func verify(_ outcome: Outcome, body: Data, maximumLineLength: Int, in fuzz: inout FuzzCase) {
        let reference = FuzzReferenceLines.split(body)
        let expected = reference.map { Array($0.text.utf8) }

        if let error = outcome.error {
            let isCapError = (error as? HTTPRequestError)?.urlErrorCode == .dataLengthExceedsMaximum
            fuzz.check(isCapError, "unexpected error \(String(reflecting: error))")
        }

        guard let firstOversized = reference.firstIndex(where: { $0.content.count > maximumLineLength }) else {
            fuzz.check(outcome.error == nil, "threw \(String(describing: outcome.error)) with every line under the cap")
            fuzz.check(outcome.lines == expected, "lines \(outcome.lines.count) differ from the reference \(expected.count)")
            return
        }
        fuzz.check(outcome.error != nil, "line \(firstOversized) is above \(maximumLineLength) bytes and did not throw")
        fuzz.check(outcome.lines.count <= firstOversized, "yielded \(outcome.lines.count) lines, past the oversized line \(firstOversized)")
        fuzz.check(Array(expected.prefix(outcome.lines.count)) == outcome.lines, "yielded lines are not a prefix of the reference")
    }
}
