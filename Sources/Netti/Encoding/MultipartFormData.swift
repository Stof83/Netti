//
//  MultipartFormData.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation
import UniformTypeIdentifiers

/// A `multipart/form-data` body built from text fields, in-memory data, files and streams.
///
/// ```swift
/// var form = MultipartFormData()
/// form.append("Ada", name: "name")
/// form.append(fileURL: avatarURL, name: "avatar")
/// ```
///
/// Files and streams are read only when the form is encoded, in fixed-size chunks, so a form
/// larger than ``encodingMemoryThreshold`` can be written to disk without loading it into memory.
///
/// Encoding throws ``HTTPRequestError/encodingFailed(_:)`` when a custom boundary is not valid
/// under RFC 2046, when a MIME type holds a control character other than tab (CR, LF, NUL, ...),
/// or when a name or file name holds NUL.
/// Quotes, CR and LF in names and file names are percent-escaped.
public struct MultipartFormData: Sendable {

    // MARK: - Types

    /// The encoded form: in memory, or in a temporary file the uploader deletes when done.
    enum EncodedForm: Equatable {
        case data(Data)
        case file(URL)
    }

    private enum Source: Sendable {
        case data(Data)
        case file(URL)
        case stream(@Sendable () -> InputStream, length: UInt64)
    }

    private struct BodyPart: Sendable {
        let fileName: String?
        let mimeType: String?
        let name: String
        let source: Source
    }

    // MARK: - Constants

    /// Forms at or above this size (10 MB) are encoded to a temporary file instead of memory.
    public static let encodingMemoryThreshold: UInt64 = 10_000_000

    private static let boundaryPrefix = "netti.boundary."
    private static let defaultMimeType = "application/octet-stream"
    private static let lineBreak = "\r\n"
    private static let streamBufferSize = 64 * 1024
    private static let temporaryDirectoryName = "netti.multipart"
    private static let maximumBoundaryLength = 70
    /// RFC 2046 `bcharsnospace` beyond letters and digits.
    private static let boundarySymbols = Set("'()+_,-./:=?".utf8)
    /// RFC 2045 `tspecials` and space that may appear in a boundary.
    private static let boundaryCharactersNeedingQuotes = Set("(),/:=? ".utf8)

    // MARK: - Properties

    /// The boundary separating parts.
    public let boundary: String

    private var bodyParts: [BodyPart] = []

    /// The request `Content-Type`, carrying the boundary.
    ///
    /// A boundary holding a space or a MIME special character such as `:` is quoted.
    public var contentType: String {
        let needsQuoting = boundary.utf8.contains { Self.boundaryCharactersNeedingQuotes.contains($0) }
        return HTTPHeader.multipartFormDataContentType(boundary: needsQuoting ? "\"\(boundary)\"" : boundary).value
    }

    // MARK: - Initialization

    /// Creates an empty form.
    ///
    /// - Parameter boundary: A custom boundary: 1 to 70 letters, digits or `'()+_,-./:=?` and
    ///   spaces, not ending in a space (RFC 2046). Defaults to a random, unique boundary. An invalid
    ///   one makes encoding throw ``HTTPRequestError/encodingFailed(_:)``.
    public init(boundary: String? = nil) {
        self.boundary = boundary ?? Self.makeBoundary()
    }

    // MARK: - Appending Parts

    /// Appends a text field.
    ///
    /// - Parameters:
    ///   - value: The field value, sent as UTF-8.
    ///   - name: The field name.
    public mutating func append(
        _ value: String,
        name: String
    ) {
        bodyParts.append(BodyPart(fileName: nil, mimeType: nil, name: name, source: .data(Data(value.utf8))))
    }

    /// Appends in-memory content.
    ///
    /// - Parameters:
    ///   - content: The part body.
    ///   - name: The field name.
    ///   - fileName: The file name reported to the server, if any.
    ///   - mimeType: The part `Content-Type`. Inferred from `fileName` when omitted.
    public mutating func append(
        _ content: Data,
        name: String,
        fileName: String? = nil,
        mimeType: String? = nil
    ) {
        let resolvedMimeType = mimeType ?? fileName.map(Self.mimeType(forFileName:))
        bodyParts.append(BodyPart(fileName: fileName, mimeType: resolvedMimeType, name: name, source: .data(content)))
    }

    /// Appends a file, read when the form is encoded.
    ///
    /// A missing file makes encoding throw `HTTPRequestError.fileSystem`, before any network traffic.
    ///
    /// - Parameters:
    ///   - fileURL: The file to send.
    ///   - name: The field name.
    ///   - fileName: The reported file name. Defaults to the URL's last path component.
    ///   - mimeType: The part `Content-Type`. Defaults to the type inferred from the file extension.
    public mutating func append(
        fileURL: URL,
        name: String,
        fileName: String? = nil,
        mimeType: String? = nil
    ) {
        let resolvedFileName = fileName ?? fileURL.lastPathComponent
        let resolvedMimeType = mimeType ?? Self.mimeType(forFileName: resolvedFileName)
        bodyParts.append(BodyPart(fileName: resolvedFileName, mimeType: resolvedMimeType, name: name, source: .file(fileURL)))
    }

    /// Appends a stream of known length.
    ///
    /// The closure is called each time the form is encoded, so a retried upload reads a fresh stream.
    ///
    /// - Parameters:
    ///   - stream: Returns a new, unopened stream positioned at its start.
    ///   - length: The exact number of bytes the stream yields.
    ///   - name: The field name.
    ///   - fileName: The file name reported to the server, if any.
    ///   - mimeType: The part `Content-Type`, if any.
    public mutating func append(
        stream: @escaping @Sendable () -> InputStream,
        length: UInt64,
        name: String,
        fileName: String? = nil,
        mimeType: String? = nil
    ) {
        bodyParts.append(BodyPart(fileName: fileName, mimeType: mimeType, name: name, source: .stream(stream, length: length)))
    }

    // MARK: - Encoding

    /// Encodes the whole form into memory.
    ///
    /// - Throws: ``HTTPRequestError/fileSystem(_:)`` when a file part cannot be read,
    ///   ``HTTPRequestError/encodingFailed(_:)`` when a stream fails, the boundary is invalid, or
    ///   a part header holds a forbidden character.
    /// - Returns: The encoded body.
    public func encode() throws(HTTPRequestError) -> Data {
        var encoded = Data()
        try write { (chunk: Data) throws(HTTPRequestError) in
            encoded.append(chunk)
        }
        return encoded
    }

    /// Encodes the form into a new file, streaming every part.
    ///
    /// - Parameter fileURL: The destination. It must not exist yet.
    /// - Throws: ``HTTPRequestError/fileSystem(_:)`` when the destination exists or cannot be written, or a
    ///   file part cannot be read; ``HTTPRequestError/encodingFailed(_:)`` when a stream fails, the
    ///   boundary is invalid, or a part header holds a forbidden character.
    public func writeEncodedData(to fileURL: URL) throws(HTTPRequestError) {
        try validate()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) == false else {
            throw .fileSystem(CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: fileURL.path]))
        }
        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
            throw .fileSystem(CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path]))
        }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try write { (chunk: Data) throws(HTTPRequestError) in
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    throw .fileSystem(error)
                }
            }
        } catch {
            try? fileManager.removeItem(at: fileURL)
            throw Self.fileSystemError(error)
        }
    }

    /// The encoded body size in bytes.
    ///
    /// - Throws: `fileSystem` when a file part is missing or is a directory.
    func contentLength() throws(HTTPRequestError) -> UInt64 {
        try validate()
        var total = UInt64(closingBoundary.utf8.count)
        for part in bodyParts {
            let framingLength = openingBoundary.utf8.count + headers(for: part).utf8.count + Self.lineBreak.utf8.count
            total += UInt64(framingLength) + (try Self.length(of: part.source))
        }
        return total
    }

    /// Encodes in memory below `memoryThreshold`, otherwise into a new temporary file.
    ///
    /// - Parameter memoryThreshold: The size from which the form goes to disk. Defaults to ``encodingMemoryThreshold``.
    /// - Returns: The in-memory body or the temporary file; the caller deletes the file after uploading it.
    func encodedForUpload(memoryThreshold: UInt64 = encodingMemoryThreshold) throws(HTTPRequestError) -> EncodedForm {
        guard try contentLength() >= memoryThreshold else {
            return .data(try encode())
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Self.temporaryDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .fileSystem(error)
        }
        let fileURL = directory.appendingPathComponent(UUID().uuidString)
        try writeEncodedData(to: fileURL)
        return .file(fileURL)
    }

    // MARK: - Private Helpers

    private var openingBoundary: String {
        "--\(boundary)\(Self.lineBreak)"
    }

    private var closingBoundary: String {
        "--\(boundary)--\(Self.lineBreak)"
    }

    private func write(to sink: (Data) throws(HTTPRequestError) -> Void) throws(HTTPRequestError) {
        try validate()
        for part in bodyParts {
            try sink(Data((openingBoundary + headers(for: part)).utf8))
            try Self.write(part.source, to: sink)
            try sink(Data(Self.lineBreak.utf8))
        }
        try sink(Data(closingBoundary.utf8))
    }

    private func headers(for part: BodyPart) -> String {
        var disposition = "form-data; name=\"\(Self.escapedQuotedValue(part.name))\""
        if let fileName = part.fileName {
            disposition += "; filename=\"\(Self.escapedQuotedValue(fileName))\""
        }

        var lines = ["Content-Disposition: \(disposition)"]
        if let mimeType = part.mimeType {
            lines.append("Content-Type: \(mimeType)")
        }
        return lines.map { $0 + Self.lineBreak }.joined() + Self.lineBreak
    }

    private static func write(
        _ source: Source,
        to sink: (Data) throws(HTTPRequestError) -> Void
    ) throws(HTTPRequestError) {
        switch source {
            case .data(let content):
                try sink(content)
            case .file(let fileURL):
                _ = try fileSize(of: fileURL)
                guard let stream = InputStream(url: fileURL) else {
                    throw .fileSystem(CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: fileURL.path]))
                }
                try copy(stream, to: sink) { .fileSystem($0) }
            case .stream(let makeStream, _):
                try copy(makeStream(), to: sink) { .encodingFailed($0) }
        }
    }

    private static func copy(
        _ stream: InputStream,
        to sink: (Data) throws(HTTPRequestError) -> Void,
        mapError: (any Error) -> HTTPRequestError
    ) throws(HTTPRequestError) {
        stream.open()
        defer { stream.close() }

        var buffer = [UInt8](repeating: 0, count: streamBufferSize)
        while true {
            let readCount = stream.read(&buffer, maxLength: buffer.count)
            guard readCount >= 0 else {
                throw mapError(stream.streamError ?? CocoaError(.fileReadUnknown))
            }
            guard readCount > 0 else {
                return
            }
            try sink(Data(buffer[0..<readCount]))
        }
    }

    private static func length(of source: Source) throws(HTTPRequestError) -> UInt64 {
        switch source {
            case .data(let content):
                UInt64(content.count)
            case .file(let fileURL):
                try fileSize(of: fileURL)
            case .stream(_, let length):
                length
        }
    }

    private static func fileSize(of fileURL: URL) throws(HTTPRequestError) -> UInt64 {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        } catch {
            throw .fileSystem(error)
        }
        guard values.isDirectory == false, let fileSize = values.fileSize else {
            throw .fileSystem(CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: fileURL.path]))
        }
        return UInt64(fileSize)
    }

    /// Throws when the boundary breaks RFC 2046 or a part header could split or truncate.
    private func validate() throws(HTTPRequestError) {
        guard Self.isValidBoundary(boundary) else {
            throw .encodingFailed(InvalidMultipartFormError(field: "boundary"))
        }
        for part in bodyParts {
            if part.name.utf8.contains(0) {
                throw .encodingFailed(InvalidMultipartFormError(field: "name"))
            }
            if part.fileName?.utf8.contains(0) == true {
                throw .encodingFailed(InvalidMultipartFormError(field: "filename"))
            }
            if let mimeType = part.mimeType, HTTPHeader.isSafe(name: "Content-Type", value: mimeType) == false {
                throw .encodingFailed(InvalidMultipartFormError(field: "Content-Type"))
            }
        }
    }

    /// RFC 2046: `0*69<bchars> bcharsnospace`, so 1 to 70 characters, not ending in a space.
    private static func isValidBoundary(_ boundary: String) -> Bool {
        let bytes = boundary.utf8
        guard (1...maximumBoundaryLength).contains(bytes.count), bytes.last != UInt8(ascii: " ") else {
            return false
        }
        return bytes.allSatisfy { byte in
            switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
                    true
                default:
                    byte == UInt8(ascii: " ") || boundarySymbols.contains(byte)
            }
        }
    }

    private static func fileSystemError(_ error: any Error) -> HTTPRequestError {
        (error as? HTTPRequestError) ?? .fileSystem(error)
    }

    /// Percent-escapes `"`, CR and LF in quoted header parameters, as the WHATWG multipart encoding does.
    ///
    /// Works on Unicode scalars, not characters: a combining mark or joiner after `"`, CR or LF
    /// joins them into one grapheme cluster, which character-level replacement would skip.
    private static func escapedQuotedValue(_ value: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
                case "\"":
                    escaped.append(contentsOf: "%22".unicodeScalars)
                case "\r":
                    escaped.append(contentsOf: "%0D".unicodeScalars)
                case "\n":
                    escaped.append(contentsOf: "%0A".unicodeScalars)
                default:
                    escaped.append(scalar)
            }
        }
        return String(escaped)
    }

    private static func mimeType(forFileName fileName: String) -> String {
        let pathExtension = (fileName as NSString).pathExtension
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? defaultMimeType
    }

    private static func makeBoundary() -> String {
        boundaryPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

// MARK: - InvalidMultipartFormError

/// A multipart form that cannot be encoded safely; names the offending field, never its value.
struct InvalidMultipartFormError: Error, CustomStringConvertible {
    /// The boundary or part header field that was rejected.
    let field: String

    var description: String {
        "The multipart \(field) is not valid: a boundary must follow RFC 2046, and part headers must not hold control characters such as CR, LF or NUL"
    }
}
