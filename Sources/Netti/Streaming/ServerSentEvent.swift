//
//  ServerSentEvent.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation

/// One event of a `text/event-stream` response.
public struct ServerSentEvent: Sendable, Equatable {
    /// The event type from the `event:` field; `nil` for the default `message` type.
    public var event: String?

    /// The `data:` lines of the event, joined by `\n`.
    public var data: String

    /// The last event ID the stream set with an `id:` field, carried until the stream changes it.
    public var id: String?

    /// The reconnection delay the server asked for with a `retry:` field in this event.
    public var retry: Duration?

    /// Creates an event.
    ///
    /// - Parameters:
    ///   - event: The event type; `nil` for `message`.
    ///   - data: The event's data.
    ///   - id: The last event ID. Optional.
    ///   - retry: The requested reconnection delay. Optional.
    public init(event: String? = nil, data: String, id: String? = nil, retry: Duration? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// The events of a `text/event-stream` body.
///
/// One event's data is capped at ``maximumDataLength``; a longer one throws
/// ``HTTPRequestError/requestFailed(_:)`` with `URLError.dataLengthExceedsMaximum`. A `retry:` field
/// above one hour is ignored.
///
/// ```swift
/// for try await event in try await netti.stream(FeedAPI.live).serverSentEvents {
///     handle(event.data)
/// }
/// ```
public struct ServerSentEventSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == String {
    /// A dispatched event.
    public typealias Element = ServerSentEvent

    /// The most data one event may carry, in bytes, `data:` lines joined. 1 MB by default.
    public let maximumDataLength: Int

    private let base: Base

    /// Creates the event view of a line sequence.
    ///
    /// - Parameters:
    ///   - base: The lines of the stream.
    ///   - maximumDataLength: The most data one event may carry, in bytes. 1 MB by default.
    public init(_ base: Base, maximumDataLength: Int = 1_048_576) {
        self.base = base
        self.maximumDataLength = Swift.max(0, maximumDataLength)
    }

    /// Creates the iterator over the events.
    ///
    /// - Returns: An iterator that reads the lines as it advances.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), maximumDataLength: maximumDataLength)
    }

    /// Yields the events of the lines in order.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var base: Base.AsyncIterator
        private var parser: ServerSentEventParser

        init(base: Base.AsyncIterator, maximumDataLength: Int) {
            self.base = base
            self.parser = ServerSentEventParser(maximumDataLength: maximumDataLength)
        }

        /// Asynchronously returns the next dispatched event.
        ///
        /// - Returns: The event, or `nil` once the lines end; an incomplete last event is dropped.
        /// - Throws: The error the line sequence throws, or ``HTTPRequestError/requestFailed(_:)``
        ///   with `URLError.dataLengthExceedsMaximum` when an event's data exceeds the maximum.
        public mutating func next() async throws -> ServerSentEvent? {
            while let line = try await base.next() {
                if let event = try parser.parse(line) {
                    return event
                }
            }
            return nil
        }
    }
}

extension ServerSentEventSequence: Sendable where Base: Sendable {}

/// Parses event-stream lines into events, following the WHATWG HTML event-stream interpretation on
/// Unicode code points: a blank line dispatches the event, `:` starts a comment, and an incomplete
/// event at the end of the stream is dropped. One event's data is capped, and a `retry` above one hour is ignored.
struct ServerSentEventParser {
    private static let byteOrderMark: Unicode.Scalar = "\u{FEFF}"
    private static let asciiDigits: ClosedRange<Unicode.Scalar> = "0"..."9"
    private static let maximumRetryMilliseconds = 3_600_000

    private let maximumDataLength: Int
    /// The bytes of `dataLines` joined by `\n`.
    private var dataLength = 0

    private var eventType: String?
    private var dataLines: [String] = []
    private var lastEventID: String?
    private var retry: Duration?
    private var isFirstLine = true

    init(maximumDataLength: Int = 1_048_576) {
        self.maximumDataLength = maximumDataLength
    }

    /// Feeds one line; returns the event it dispatches, if any.
    ///
    /// - Throws: ``HTTPRequestError/requestFailed(_:)`` with `URLError.dataLengthExceedsMaximum`
    ///   when the event's data would exceed the maximum.
    mutating func parse(_ line: String) throws(HTTPRequestError) -> ServerSentEvent? {
        // Code points, not characters: a combining mark after `:`, a space or the BOM would
        // otherwise merge with it into one grapheme cluster and hide the delimiter.
        var scalars = line.unicodeScalars[...]
        if isFirstLine {
            isFirstLine = false
            if scalars.first == Self.byteOrderMark {
                scalars = scalars.dropFirst()
            }
        }

        guard scalars.isEmpty == false else {
            return dispatch()
        }
        guard scalars.first != ":" else {
            return nil
        }

        let field: Substring.UnicodeScalarView
        var value: Substring.UnicodeScalarView
        if let colon = scalars.firstIndex(of: ":") {
            field = scalars[..<colon]
            value = scalars[scalars.index(after: colon)...]
            if value.first == " " {
                value = value.dropFirst()
            }
        } else {
            field = scalars
            value = scalars[scalars.endIndex...]
        }

        let text = String(Substring(value))
        switch String(Substring(field)) {
            case "event":
                eventType = text
            case "data":
                dataLength += text.utf8.count + (dataLines.isEmpty ? 0 : 1)
                guard dataLength <= maximumDataLength else {
                    throw .requestFailed(URLError(.dataLengthExceedsMaximum))
                }
                dataLines.append(text)
            case "id" where value.contains("\0") == false:
                lastEventID = text
            case "retry" where value.isEmpty == false && value.allSatisfy(Self.asciiDigits.contains):
                if let milliseconds = Int(text), milliseconds <= Self.maximumRetryMilliseconds {
                    retry = .milliseconds(milliseconds)
                }
            default:
                break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            eventType = nil
            dataLines = []
            dataLength = 0
            retry = nil
        }
        guard dataLines.isEmpty == false else {
            return nil
        }
        return ServerSentEvent(event: eventType, data: dataLines.joined(separator: "\n"), id: lastEventID, retry: retry)
    }
}
