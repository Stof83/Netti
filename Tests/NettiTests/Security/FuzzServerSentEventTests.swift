//
//  FuzzServerSentEventTests.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/10/26.
//

import Foundation
import Testing

@testable import Netti

/// Seeded fuzzing of the event-stream parser (TM-21): random line streams never trap, fail only with
/// `requestFailed(dataLengthExceedsMaximum)`, keep each event's data under the cap, drop a `retry`
/// above one hour, and match a code-point reference of the WHATWG event-stream rules.
@Suite("Fuzz: server-sent events", .timeLimit(.minutes(30)))
struct FuzzServerSentEventTests {

    // MARK: - Parser

    @Test("given random event-stream lines, when parsed, then caps hold and events match the reference")
    func randomLines_matchReference() async {
        await Fuzz.run("sse.lines") { fuzz in
            let maximumDataLength = fuzz.random.pick([0, 1, 16, 256, 4_096])
            let lines = EventStreamGenerator.lines(using: &fuzz.random, maximumDataLength: maximumDataLength)
            fuzz.input = FuzzCase.describe(lines)

            let outcome = parse(lines, maximumDataLength: maximumDataLength)
            check(outcome, maximumDataLength: maximumDataLength, in: &fuzz)

            let expected = ReferenceEventStream.parse(lines, maximumDataLength: maximumDataLength)
            fuzz.check(outcome.events == expected.events, "events \(outcome.events) != reference \(expected.events)")
            fuzz.check(outcome.overflowed == expected.overflowed, "overflow \(outcome.overflowed) != reference \(expected.overflowed)")
        }
    }

    /// Multiplier 0.02 (minimum 4): every case builds about 1 MB of data lines.
    @Test("given data lines totalling the 1 MB default cap plus or minus two bytes, when parsed, then only an event above the cap throws")
    func dataAroundDefaultCap_throwsOnlyAbove() async {
        let iterations = Fuzz.iterations(multiplier: 0.02, minimum: 4)

        await Fuzz.run("sse.cap", iterations: iterations, timeLimitPerCase: .seconds(20)) { fuzz in
            let cap = 1_048_576
            let delta = fuzz.random.int(-2...2)
            let lineCount = fuzz.random.int(1...8)
            let target = cap + delta
            // `lineCount` lines joined by `lineCount - 1` newlines carry `target` bytes.
            let payload = target - (lineCount - 1)
            var lines = (0..<lineCount).map { index in
                String(repeating: "x", count: payload / lineCount + (index < payload % lineCount ? 1 : 0))
            }.map { "data:" + $0 }
            lines.append("")
            fuzz.input = "lines=\(lineCount) delta=\(delta)"

            let outcome = parse(lines, maximumDataLength: cap)

            fuzz.check(outcome.overflowed == (delta > 0), "overflowed=\(outcome.overflowed) for delta \(delta)")
            fuzz.check(outcome.events.first.map { $0.data.utf8.count == target } ?? (delta > 0), "event size wrong for delta \(delta)")
        }
    }

    /// TM-fuzz-1 (fixed): a combining mark right after the field colon (`data:\u{301}x`) or the
    /// optional space (`data: \u{301}x`) must not hide the delimiter. WHATWG splits on code points,
    /// dispatches `\u{301}x`, and strips exactly one leading U+0020.
    @Test("given a combining mark right after the field colon, when parsed, then the event follows the code-point rules")
    func combiningMarkAfterColon_followsCodePointRules() async {
        await Fuzz.run("sse.combining") { fuzz in
            let mark = Unicode.Scalar(UInt32(fuzz.random.int(0x0300...0x036F))) ?? "\u{301}"
            let separator = fuzz.random.pick([":", ": "])
            let value = fuzz.random.string(maximumLength: 16, alphabet: .printableASCII)
            let lines = ["data\(separator)\(Character(mark))\(value)", ""]
            fuzz.input = FuzzCase.describe(lines)

            let outcome = parse(lines, maximumDataLength: 4_096)
            let expected = ReferenceEventStream.parse(lines, maximumDataLength: 4_096)

            fuzz.check(outcome.events == expected.events, "events \(outcome.events) != reference \(expected.events)")
        }
    }

    // MARK: - Bytes To Events

    @Test("given random event-stream bytes in random chunks, when read as events, then caps hold and events match the reference")
    func randomBytes_chunked_matchReference() async {
        await Fuzz.run("sse.bytes") { fuzz in
            let maximumLineLength = fuzz.random.pick([1, 8, 64, 1_024, 1_048_576])
            let maximumDataLength = fuzz.random.pick([0, 16, 256, 4_096])
            let body = EventStreamGenerator.bytes(using: &fuzz.random, maximumDataLength: maximumDataLength)
            let chunks = fuzz.random.chunks(of: body)
            fuzz.input = FuzzCase.describe(body)

            var events: [ServerSentEvent] = []
            var thrown: (any Error)?
            let sequence = ServerSentEventSequence(
                AsyncLineSequence(FuzzSequence(chunks), maximumLineLength: maximumLineLength),
                maximumDataLength: maximumDataLength
            )
            do {
                for try await event in sequence {
                    events.append(event)
                }
            } catch {
                thrown = error
            }

            fuzz.check(thrown.map(isDataLengthExceeded) ?? true, "unexpected error \(String(describing: thrown))")
            check(ParseOutcome(events: events, overflowed: thrown != nil), maximumDataLength: maximumDataLength, in: &fuzz)

            let lines = FuzzReferenceLines.split(body)
            if lines.contains(where: { $0.content.count > maximumLineLength }) {
                fuzz.check(thrown != nil, "a line above \(maximumLineLength) bytes did not throw")
                return
            }
            let strings = lines.map(\.text)
            // An unterminated last line is still a line, but the last event needs a blank line to dispatch.
            let expected = ReferenceEventStream.parse(strings, maximumDataLength: maximumDataLength)
            fuzz.check(events == expected.events, "events \(events) != reference \(expected.events)")
            fuzz.check((thrown != nil) == expected.overflowed, "threw=\(thrown != nil), reference overflow=\(expected.overflowed)")
        }
    }

    // MARK: - Private Helpers

    private struct ParseOutcome {
        let events: [ServerSentEvent]
        let overflowed: Bool
    }

    private func parse(_ lines: [String], maximumDataLength: Int) -> ParseOutcome {
        var parser = ServerSentEventParser(maximumDataLength: maximumDataLength)
        var events: [ServerSentEvent] = []
        for line in lines {
            do {
                if let event = try parser.parse(line) {
                    events.append(event)
                }
            } catch {
                guard case .requestFailed(let urlError) = error, urlError.code == .dataLengthExceedsMaximum else {
                    return ParseOutcome(events: events + [ServerSentEvent(data: "<wrong error \(error)>")], overflowed: true)
                }
                return ParseOutcome(events: events, overflowed: true)
            }
        }
        return ParseOutcome(events: events, overflowed: false)
    }

    private func check(_ outcome: ParseOutcome, maximumDataLength: Int, in fuzz: inout FuzzCase) {
        for event in outcome.events {
            fuzz.check(event.data.utf8.count <= maximumDataLength, "event data \(event.data.utf8.count) B above cap \(maximumDataLength)")
            fuzz.check(event.retry.map { $0 <= .seconds(3_600) } ?? true, "retry \(String(describing: event.retry)) above one hour")
            fuzz.check(event.id?.unicodeScalars.contains("\0") != true, "id carries NUL")
        }
    }

    private func isDataLengthExceeded(_ error: any Error) -> Bool {
        guard case .requestFailed(let urlError) = error as? HTTPRequestError else {
            return false
        }
        return urlError.code == .dataLengthExceedsMaximum
    }
}

// MARK: - Generator

private enum EventStreamGenerator {
    private static let fieldNames = ["data", "data", "data", "event", "id", "retry", "", "Data", "data ", "unknown"]

    /// Lines as the line splitter yields them: no LF, CR allowed.
    static func lines(using random: inout SeededRandom, maximumDataLength: Int) -> [String] {
        var lines: [String] = []
        if random.chance(0.1) {
            lines.append("\u{FEFF}" + line(using: &random, maximumDataLength: maximumDataLength))
        }
        for _ in 0..<random.int(0...24) {
            lines.append(random.chance(0.25) ? "" : line(using: &random, maximumDataLength: maximumDataLength))
        }
        return lines.map { String(String.UnicodeScalarView($0.unicodeScalars.filter { $0 != "\n" })) }
    }

    /// An event stream as bytes: lines ended by LF, CRLF or a lone CR, invalid UTF-8 mixed in.
    static func bytes(using random: inout SeededRandom, maximumDataLength: Int) -> Data {
        var body = Data()
        for line in lines(using: &random, maximumDataLength: maximumDataLength) {
            body.append(contentsOf: Array(line.utf8))
            if random.chance(0.1) {
                body.append(random.utf8Bytes(maximumLength: 8))
            }
            body.append(contentsOf: Array(random.pick(["\n", "\n", "\r\n", "\r"]).utf8))
        }
        return random.chance(0.2) ? random.mutate(body) : body
    }

    private static func line(using random: inout SeededRandom, maximumDataLength: Int) -> String {
        if random.chance(0.1) {
            return ":" + random.string(maximumLength: 32)
        }
        let field = random.chance(0.05) ? random.string(maximumLength: 6) : random.pick(fieldNames)
        let separator = random.pick([":", ": ", ":  ", ""])
        let value: String
        switch field {
            case "retry":
                value = random.pick([
                    String(random.int(0...4_000_000)), "3600000", "3600001", "9999999999", "99999999999999999999",
                    "-1", "1e3", " 5", "", "٣", "５", String(repeating: "9", count: random.int(1...40)),
                ])
            case "data" where random.chance(0.1):
                value = String(repeating: "d", count: random.int(0...(maximumDataLength + 2)))
            default:
                value = random.string(maximumLength: 48, alphabet: .unicode)
        }
        return field + separator + value
    }
}

// MARK: - Reference

/// The WHATWG event-stream interpretation on code points, with Netti's documented choices: data
/// capped per event, a `retry` above one hour ignored, and `retry` reset with each event.
private enum ReferenceEventStream {
    private static let asciiDigits: ClosedRange<Unicode.Scalar> = "0"..."9"

    static func parse(_ lines: [String], maximumDataLength: Int) -> (events: [ServerSentEvent], overflowed: Bool) {
        var events: [ServerSentEvent] = []
        var eventType: String?
        var data: [String] = []
        var dataLength = 0
        var lastEventID: String?
        var retry: Duration?

        for (index, line) in lines.enumerated() {
            var scalars = Array(line.unicodeScalars)
            if index == 0, scalars.first == "\u{FEFF}" {
                scalars.removeFirst()
            }
            if scalars.isEmpty {
                if data.isEmpty == false {
                    events.append(ServerSentEvent(event: eventType, data: data.joined(separator: "\n"), id: lastEventID, retry: retry))
                }
                eventType = nil
                data = []
                dataLength = 0
                retry = nil
                continue
            }
            if scalars.first == ":" {
                continue
            }
            var field = scalars[...]
            var value = scalars[scalars.endIndex...]
            if let colon = scalars.firstIndex(of: ":") {
                field = scalars[..<colon]
                value = scalars[(colon + 1)...]
                if value.first == " " {
                    value = value.dropFirst()
                }
            }
            let text = String(String.UnicodeScalarView(value))
            switch String(String.UnicodeScalarView(field)) {
                case "event":
                    eventType = text
                case "data":
                    dataLength += text.utf8.count + (data.isEmpty ? 0 : 1)
                    if dataLength > maximumDataLength {
                        return (events, true)
                    }
                    data.append(text)
                case "id" where value.contains("\0") == false:
                    lastEventID = text
                case "retry" where value.isEmpty == false && value.allSatisfy({ asciiDigits.contains($0) }):
                    if let milliseconds = Int(text), milliseconds <= 3_600_000 {
                        retry = .milliseconds(milliseconds)
                    }
                default:
                    break
            }
        }
        return (events, false)
    }
}

/// Splits bytes on LF, drops one CR before it, and keeps an unterminated last line.
enum FuzzReferenceLines {
    struct Line {
        let content: [UInt8]

        var text: String {
            String(decoding: content, as: UTF8.self)
        }
    }

    static func split(_ bytes: Data) -> [Line] {
        var lines: [Line] = []
        var current: [UInt8] = []
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                lines.append(Line(content: current.last == UInt8(ascii: "\r") ? current.dropLast() : current))
                current = []
            } else {
                current.append(byte)
            }
        }
        if current.isEmpty == false {
            lines.append(Line(content: current.last == UInt8(ascii: "\r") ? current.dropLast() : current))
        }
        return lines
    }
}
