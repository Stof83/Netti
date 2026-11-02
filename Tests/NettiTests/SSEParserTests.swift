import Foundation
import Testing

@testable import Netti

@Suite("Server-sent event parser")
struct SSEParserTests {

    @Test("given two data lines, when the event is dispatched, then its data is both lines joined by a newline")
    func multiLineData() {
        let events = parse("data: first", "data: second", "")

        #expect(events == [ServerSentEvent(data: "first\nsecond")])
    }

    @Test("given event, id and retry fields, when dispatched, then the event carries them")
    func allFields() {
        let events = parse("event: update", "id: 42", "retry: 1500", "data: {}", "")

        #expect(events == [ServerSentEvent(event: "update", data: "{}", id: "42", retry: .milliseconds(1500))])
    }

    @Test("given comment lines, when parsed, then they are ignored")
    func commentsIgnored() {
        let events = parse(": keep-alive", "data: x", ": another", "")

        #expect(events == [ServerSentEvent(data: "x")])
    }

    @Test("given an id, when later events omit it, then they keep the last event ID; retry and type reset")
    func lastEventIDPersists() {
        let events = parse("id: 7", "event: a", "retry: 10", "data: one", "", "data: two", "")

        #expect(events == [
            ServerSentEvent(event: "a", data: "one", id: "7", retry: .milliseconds(10)),
            ServerSentEvent(data: "two", id: "7"),
        ])
    }

    @Test("given fields without a space after the colon or without a value, when parsed, then they follow the event-stream rules")
    func fieldSyntax() {
        let events = parse("data:tight", "data", "data:  two spaces", "retry: soon", "unknown: ignored", "")

        #expect(events == [ServerSentEvent(data: "tight\n\n two spaces")])
    }

    @Test("given a blank line with no data or an unterminated event at the end, when parsed, then nothing is dispatched")
    func noDispatchWithoutData() {
        let events = parse("event: ping", "", "data: incomplete")

        #expect(events.isEmpty)
    }

    @Test("given a byte order mark on the first line, when parsed, then it is ignored")
    func byteOrderMarkIgnored() {
        let events = parse("\u{FEFF}data: x", "")

        #expect(events == [ServerSentEvent(data: "x")])
    }

    @Test("given a CRLF event stream split across chunks, when read as events, then they are parsed")
    func sequenceOverChunks() async throws {
        let sequence = ServerSentEventSequence(AsyncLineSequence(chunks("data: a\r\n", "\r\ndata", ": b\r\n\r\n")))

        var events: [ServerSentEvent] = []
        for try await event in sequence {
            events.append(event)
        }

        #expect(events == [ServerSentEvent(data: "a"), ServerSentEvent(data: "b")])
    }

    // MARK: - Bounds

    @Test("given a retry above one hour, when parsed, then it is ignored", arguments: ["9999999999", "3600001", "99999999999999999999999"])
    func retryAboveOneHour_isIgnored(value: String) {
        let events = parse("retry: \(value)", "data: x", "")

        #expect(events == [ServerSentEvent(data: "x")])
    }

    @Test("given a retry of exactly one hour, when parsed, then it is kept")
    func retryOfOneHour_isKept() {
        let events = parse("retry: 3600000", "data: x", "")

        #expect(events == [ServerSentEvent(data: "x", retry: .seconds(3600))])
    }

    @Test("given an event whose data passes the cap, when parsed, then it throws")
    func dataAboveCap_throws() {
        var parser = ServerSentEventParser(maximumDataLength: 8)

        #expect(throws: HTTPRequestError.self) {
            _ = try parser.parse("data: 1234")
            _ = try parser.parse("data: 5678")
        }
    }

    @Test("given an event whose data is exactly at the cap, when parsed, then it is dispatched, and the next event starts from zero")
    func dataAtCap_isDispatched() throws {
        var parser = ServerSentEventParser(maximumDataLength: 9)
        let lines = ["data: 1234", "data: 5678", "", "data: 123456789", ""]

        var events: [ServerSentEvent] = []
        for line in lines {
            if let event = try parser.parse(line) {
                events.append(event)
            }
        }

        #expect(events == [ServerSentEvent(data: "1234\n5678"), ServerSentEvent(data: "123456789")])
    }

    @Test("given more than 1 MB of data lines in one event, when read as events, then the sequence throws")
    func sequence_dataAboveDefaultCap_throws() async {
        let line = "data: " + String(repeating: "a", count: 1_000) + "\n"
        let body = String(repeating: line, count: 1_100) + "\n"
        var thrown: (any Error)?
        do {
            for try await _ in ServerSentEventSequence(AsyncLineSequence(chunks(body))) {}
        } catch {
            thrown = error
        }

        #expect((thrown as? HTTPRequestError)?.urlErrorCode == .dataLengthExceedsMaximum)
    }

    private func parse(_ lines: String...) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        return lines.compactMap { try? parser.parse($0) }
    }
}
