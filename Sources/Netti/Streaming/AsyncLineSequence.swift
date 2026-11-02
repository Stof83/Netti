//
//  AsyncLineSequence.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation

/// The lines of a streamed body, split on LF and CRLF.
///
/// A line that arrives across several chunks is yielded once, whole. The last line is yielded
/// even without a trailing line break. Bytes that are not valid UTF-8 are replaced with `U+FFFD`.
///
/// Each byte is scanned once, and a line longer than ``maximumLineLength`` throws
/// ``HTTPRequestError/requestFailed(_:)`` with `URLError.dataLengthExceedsMaximum` instead of
/// buffering further.
///
/// ```swift
/// for try await line in try await netti.stream(LogAPI.tail).lines { console.append(line) }
/// ```
public struct AsyncLineSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == Data {
    /// A line, without its line break.
    public typealias Element = String

    /// The longest line accepted, in bytes, without its line break. 1 MB by default.
    public let maximumLineLength: Int

    private let base: Base

    /// Creates the line view of a chunk sequence.
    ///
    /// - Parameters:
    ///   - base: The chunks.
    ///   - maximumLineLength: The longest line accepted, in bytes. 1 MB by default.
    public init(_ base: Base, maximumLineLength: Int = 1_048_576) {
        self.base = base
        self.maximumLineLength = Swift.max(1, maximumLineLength)
    }

    /// Creates the iterator over the lines.
    ///
    /// - Returns: An iterator that reads the chunks as it advances.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), maximumLineLength: maximumLineLength)
    }

    /// Yields the lines of the chunks in order.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var base: Base.AsyncIterator
        private var splitter: LineSplitter
        private var ready: [String] = []
        private var nextReady = 0
        private var isFinished = false

        init(base: Base.AsyncIterator, maximumLineLength: Int) {
            self.base = base
            self.splitter = LineSplitter(maximumLineLength: maximumLineLength)
        }

        /// Asynchronously returns the next complete line.
        ///
        /// - Returns: The line, or `nil` once the chunks end and every line is yielded.
        /// - Throws: The error the chunk sequence throws, or ``HTTPRequestError/requestFailed(_:)``
        ///   with `URLError.dataLengthExceedsMaximum` when a line exceeds the maximum length.
        public mutating func next() async throws -> String? {
            while nextReady == ready.count {
                guard isFinished == false else {
                    return nil
                }
                if let chunk = try await base.next() {
                    ready = try splitter.append(chunk)
                } else {
                    isFinished = true
                    ready = splitter.finish()
                }
                nextReady = 0
            }
            defer { nextReady += 1 }
            return ready[nextReady]
        }
    }
}

extension AsyncLineSequence: Sendable where Base: Sendable {}

/// Splits chunks of bytes into lines on LF, dropping a CR right before it.
///
/// The bytes after the last line break are scanned once and remembered, so a line dripped one
/// byte at a time costs linear work.
struct LineSplitter: Sendable {
    /// The default longest line, in bytes: 1 MB.
    static let defaultMaximumLineLength = 1_048_576

    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    private let maximumLineLength: Int
    /// The bytes of the unterminated line, always starting at index 0.
    private var buffer = Data()

    init(maximumLineLength: Int = defaultMaximumLineLength) {
        self.maximumLineLength = maximumLineLength
    }

    /// Adds a chunk and returns the lines it completes.
    ///
    /// Only the new chunk is scanned: the buffered bytes are known to hold no line break.
    mutating func append(_ chunk: Data) throws(HTTPRequestError) -> [String] {
        var lines: [String] = []
        var lineStart = chunk.startIndex
        while let lineFeed = chunk[lineStart...].firstIndex(of: Self.lineFeed) {
            let line: Data
            if buffer.isEmpty {
                line = Data(chunk[lineStart..<lineFeed])
            } else {
                buffer.append(chunk[lineStart..<lineFeed])
                line = buffer
                buffer = Data()
            }
            try checkLength(Self.contentLength(of: line))
            lines.append(Self.line(line))
            lineStart = chunk.index(after: lineFeed)
        }
        buffer.append(chunk[lineStart...])
        // A trailing CR may still belong to a CRLF, so it does not count yet.
        try checkLength(buffer.count - (buffer.last == Self.carriageReturn ? 1 : 0))
        return lines
    }

    /// Returns the unterminated last line, if any.
    mutating func finish() -> [String] {
        defer { buffer = Data() }
        return buffer.isEmpty ? [] : [Self.line(buffer)]
    }

    private func checkLength(_ length: Int) throws(HTTPRequestError) {
        guard length <= maximumLineLength else {
            throw .requestFailed(URLError(.dataLengthExceedsMaximum))
        }
    }

    private static func contentLength(of bytes: Data) -> Int {
        bytes.last == carriageReturn ? bytes.count - 1 : bytes.count
    }

    private static func line(_ bytes: Data) -> String {
        let content = bytes.last == carriageReturn ? bytes.dropLast() : bytes[...]
        return String(decoding: content, as: UTF8.self)
    }
}
