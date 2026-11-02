//
//  HTTPHeaders.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation

/// An order-preserving and case-insensitive representation of HTTP headers.
///
/// Build it from a dictionary or an array literal, and read or write values by name:
///
/// ```swift
/// var headers: HTTPHeaders = [.accept("application/json"), .authorization(bearerToken: token)]
/// headers["X-Request-ID"] = UUID().uuidString
/// let type = headers["content-type"]
/// ```
public struct HTTPHeaders: Equatable, Hashable, Sendable {
    private var headers: [HTTPHeader] = []

    /// Creates an empty instance.
    public init() {}

    /// Creates an instance from an array of `HTTPHeader`s. Duplicate case-insensitive names are collapsed into the last
    /// name and value encountered.
    ///
    /// - Parameter headers: The headers, in order.
    public init(_ headers: [HTTPHeader]) {
        headers.forEach { update($0) }
    }

    /// Creates an instance from a `[String: String]`. Duplicate case-insensitive names are collapsed into the last name
    /// and value encountered.
    ///
    /// - Parameter dictionary: The header values, keyed by name.
    public init(_ dictionary: [String: String]) {
        dictionary.forEach { update(HTTPHeader(name: $0.key, value: $0.value)) }
    }

    /// Case-insensitively updates or appends an `HTTPHeader` into the instance using the provided `name` and `value`.
    ///
    /// - Parameters:
    ///   - name:  The `HTTPHeader` name.
    ///   - value: The `HTTPHeader` value.
    public mutating func add(name: String, value: String) {
        update(HTTPHeader(name: name, value: value))
    }

    /// Case-insensitively updates or appends the provided `HTTPHeader` into the instance.
    ///
    /// - Parameter header: The `HTTPHeader` to update or append.
    public mutating func add(_ header: HTTPHeader) {
        update(header)
    }

    /// Case-insensitively updates or appends an `HTTPHeader` into the instance using the provided `name` and `value`.
    ///
    /// - Parameters:
    ///   - name:  The `HTTPHeader` name.
    ///   - value: The `HTTPHeader` value.
    public mutating func update(name: String, value: String) {
        update(HTTPHeader(name: name, value: value))
    }

    /// Case-insensitively updates or appends the provided `HTTPHeader` into the instance.
    ///
    /// - Parameter header: The `HTTPHeader` to update or append.
    public mutating func update(_ header: HTTPHeader) {
        guard let index = headers.index(of: header.name) else {
            headers.append(header)
            return
        }

        headers.replaceSubrange(index...index, with: [header])
    }

    /// Case-insensitively removes an `HTTPHeader`, if it exists, from the instance.
    ///
    /// - Parameter name: The name of the `HTTPHeader` to remove.
    public mutating func remove(name: String) {
        guard let index = headers.index(of: name) else { return }

        headers.remove(at: index)
    }

    /// Sort the current instance by header name, case insensitively.
    public mutating func sort() {
        headers.sort { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Returns an instance sorted by header name.
    ///
    /// - Returns: A copy of the current instance sorted by name.
    public func sorted() -> HTTPHeaders {
        var headers = self
        headers.sort()

        return headers
    }

    /// Case-insensitively find a header's value by name.
    ///
    /// - Parameter name: The name of the header to search for, case-insensitively.
    ///
    /// - Returns:        The value of header, if it exists.
    public func value(for name: String) -> String? {
        guard let index = headers.index(of: name) else { return nil }

        return headers[index].value
    }

    /// Case-insensitively access the header with the given name.
    ///
    /// Setting a value updates or appends the header; setting `nil` removes it.
    ///
    /// - Parameter name: The name of the header.
    public subscript(_ name: String) -> String? {
        get { value(for: name) }
        set {
            if let value = newValue {
                update(name: name, value: value)
            } else {
                remove(name: name)
            }
        }
    }

    /// The dictionary representation of all headers.
    ///
    /// This representation does not preserve the current order of the instance.
    public var dictionary: [String: String] {
        let namesAndValues = headers.map { ($0.name, $0.value) }

        return Dictionary(namesAndValues, uniquingKeysWith: { _, last in last })
    }
}

extension HTTPHeaders: ExpressibleByDictionaryLiteral {
    /// Creates an instance from a dictionary literal of names and values, in order.
    ///
    /// - Parameter elements: The name and value pairs; a later duplicate name replaces an earlier one.
    public init(dictionaryLiteral elements: (String, String)...) {
        elements.forEach { update(name: $0.0, value: $0.1) }
    }
}

extension HTTPHeaders: ExpressibleByArrayLiteral {
    /// Creates an instance from an array literal of headers, in order.
    ///
    /// - Parameter elements: The headers; a later duplicate name replaces an earlier one.
    public init(arrayLiteral elements: HTTPHeader...) {
        self.init(elements)
    }
}

extension HTTPHeaders: Sequence {
    /// Returns an iterator over the headers, in order.
    ///
    /// - Returns: The iterator.
    public func makeIterator() -> IndexingIterator<[HTTPHeader]> {
        headers.makeIterator()
    }
}

extension HTTPHeaders: Collection {
    /// The position of the first header.
    public var startIndex: Int {
        headers.startIndex
    }

    /// The position one past the last header.
    public var endIndex: Int {
        headers.endIndex
    }

    /// Accesses the header at a position.
    ///
    /// - Parameter position: A valid index of the collection.
    public subscript(position: Int) -> HTTPHeader {
        headers[position]
    }

    /// Returns the position after a given one.
    ///
    /// - Parameter i: A valid index of the collection.
    /// - Returns: The next index.
    public func index(after i: Int) -> Int {
        headers.index(after: i)
    }
}

extension HTTPHeaders: CustomStringConvertible {
    /// The headers as `Name: value` lines, in order, with every credential value shown as
    /// `<redacted>`. A name marks a credential under the logger's rules, defined in
    /// `Logger/Redaction.swift` and listed in <doc:Observability#What-the-logger-redacts>. Read a
    /// value by name to get it.
    public var description: String {
        headers.map(\.description)
            .joined(separator: "\n")
    }
}

// MARK: - HTTPHeader

/// A representation of a single HTTP header's name / value pair.
public struct HTTPHeader: Equatable, Hashable, Sendable {
    /// Name of the header.
    public let name: String

    /// Value of the header.
    public let value: String

    /// Creates an instance from the given `name` and `value`.
    ///
    /// - Parameters:
    ///   - name:  The name of the header.
    ///   - value: The value of the header.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

extension HTTPHeader: CustomStringConvertible {
    /// The header as `Name: value`, with the value redacted when the name marks a credential.
    public var description: String {
        "\(name): \(Redaction.value(value, named: name))"
    }
}

extension HTTPHeader {
    /// Returns an `Accept` header.
    ///
    /// - Parameter value: The `Accept` value.
    /// - Returns:         The header.
    public static func accept(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept", value: value)
    }

    /// Returns an `Accept-Charset` header.
    ///
    /// - Parameter value: The `Accept-Charset` value.
    /// - Returns:         The header.
    public static func acceptCharset(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept-Charset", value: value)
    }

    /// Returns an `Accept-Language` header.
    ///
    /// Netti offers a default Accept-Language header that accumulates and encodes the system's preferred languages.
    /// Use ``HTTPHeader/defaultAcceptLanguage``.
    ///
    /// - Parameter value: The `Accept-Language` value.
    ///
    /// - Returns:         The header.
    public static func acceptLanguage(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept-Language", value: value)
    }

    /// Returns an `Accept-Encoding` header.
    ///
    /// Netti offers a default accept encoding value that provides the most common values. Use
    /// ``HTTPHeader/defaultAcceptEncoding``.
    ///
    /// - Parameter value: The `Accept-Encoding` value.
    ///
    /// - Returns:         The header
    public static func acceptEncoding(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Accept-Encoding", value: value)
    }

    /// Returns a `Basic` `Authorization` header using the `username` and `password` provided.
    ///
    /// - Parameters:
    ///   - username: The username of the header.
    ///   - password: The password of the header.
    ///
    /// - Returns:    The header.
    public static func authorization(username: String, password: String) -> HTTPHeader {
        let credential = Data("\(username):\(password)".utf8).base64EncodedString()

        return authorization("Basic \(credential)")
    }

    /// Returns a `Bearer` `Authorization` header using the `bearerToken` provided.
    ///
    /// - Parameter bearerToken: The bearer token.
    ///
    /// - Returns:               The header.
    public static func authorization(bearerToken: String) -> HTTPHeader {
        authorization("Bearer \(bearerToken)")
    }

    /// Returns an `Authorization` header.
    ///
    /// Netti provides built-in methods to produce `Authorization` headers. For a Basic `Authorization` header use
    /// ``HTTPHeader/authorization(username:password:)``. For a Bearer `Authorization` header, use
    /// ``HTTPHeader/authorization(bearerToken:)``.
    ///
    /// - Parameter value: The `Authorization` value.
    ///
    /// - Returns:         The header.
    public static func authorization(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Authorization", value: value)
    }

    /// Returns a `Content-Disposition` header.
    ///
    /// - Parameter value: The `Content-Disposition` value.
    ///
    /// - Returns:         The header.
    public static func contentDisposition(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Content-Disposition", value: value)
    }

    /// Returns a `Content-Encoding` header.
    ///
    /// - Parameter value: The `Content-Encoding`.
    ///
    /// - Returns:         The header.
    public static func contentEncoding(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Content-Encoding", value: value)
    }

    /// Returns a `Content-Type` header.
    ///
    /// ``JSONParameterEncoder``, ``URLEncodedFormParameterEncoder`` and multipart uploads set the `Content-Type` of the
    /// request, so it may not be necessary to manually set this value.
    ///
    /// - Parameter value: The `Content-Type` value.
    ///
    /// - Returns:         The header.
    public static func contentType(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Content-Type", value: value)
    }

    /// `Content-Type: application/json`, set by the JSON body encoder.
    public static let jsonContentType: HTTPHeader = contentType("application/json")

    /// `Content-Type: application/x-www-form-urlencoded; charset=utf-8`, set by the form encoder for body destinations.
    public static let formURLEncodedContentType: HTTPHeader = contentType("application/x-www-form-urlencoded; charset=utf-8")

    /// Returns a `multipart/form-data` `Content-Type` header carrying `boundary`.
    ///
    /// - Parameter boundary: The multipart boundary.
    ///
    /// - Returns:            The header.
    public static func multipartFormDataContentType(boundary: String) -> HTTPHeader {
        contentType("multipart/form-data; boundary=\(boundary)")
    }

    /// Returns a `User-Agent` header.
    ///
    /// - Parameter value: The `User-Agent` value.
    ///
    /// - Returns:         The header.
    public static func userAgent(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "User-Agent", value: value)
    }

    /// Returns a `Sec-WebSocket-Protocol` header.
    ///
    /// - Parameter value: The `Sec-WebSocket-Protocol` value.
    /// - Returns:         The header.
    public static func websocketProtocol(_ value: String) -> HTTPHeader {
        HTTPHeader(name: "Sec-WebSocket-Protocol", value: value)
    }
}

extension [HTTPHeader] {
    /// Case-insensitively finds the index of an `HTTPHeader` with the provided name, if it exists.
    func index(of name: String) -> Int? {
        let lowercasedName = name.lowercased()
        return firstIndex { $0.name.lowercased() == lowercasedName }
    }
}

// MARK: - Validation

/// A header that cannot be sent: its name is not an RFC 9110 token, or its value holds a control
/// character other than horizontal tab, such as CR, LF or NUL.
///
/// It names the header but never carries its value, which may hold a credential.
struct InvalidHeaderError: Error, CustomStringConvertible {
    /// The offending header's name, escaped when it holds a control character.
    let name: String

    var description: String {
        "The header \(name.debugDescription) has an invalid name or a control character in its value and was not sent"
    }
}

extension HTTPHeader {
    private static let tokenSymbols = Set("!#$%&'*+-.^_`|~".utf8)

    /// Whether the header can be written to the wire as one well-formed field line.
    ///
    /// The name must be a non-empty RFC 9110 token: ASCII letters, digits and ``!#$%&'*+-.^_`|~``,
    /// so no space, colon or control character. The value must hold no control character other
    /// than horizontal tab: CR, LF or NUL would split it into extra header lines. Bytes from 0x80
    /// up (obs-text, UTF-8) are allowed.
    static func isSafe(name: String, value: String) -> Bool {
        isToken(name) && isFieldValue(value)
    }

    private static func isToken(_ name: String) -> Bool {
        name.isEmpty == false && name.utf8.allSatisfy { byte in
            switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
                    true
                default:
                    tokenSymbols.contains(byte)
            }
        }
    }

    private static func isFieldValue(_ value: String) -> Bool {
        value.utf8.contains { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7F } == false
    }
}

extension HTTPHeaders {
    /// Throws when a header name is not a token or a value holds a control character, naming the
    /// header without its value.
    func validate() throws(HTTPRequestError) {
        if let header = headers.first(where: { HTTPHeader.isSafe(name: $0.name, value: $0.value) == false }) {
            throw .encodingFailed(InvalidHeaderError(name: header.name))
        }
    }
}

extension URLRequest {
    /// Throws when a header name is not a token or a value holds a control character, naming the
    /// header without its value.
    ///
    /// `URLRequest` silently drops a value with CR or LF, but keeps a name with them and a value
    /// with NUL, and the transport would write both to the wire.
    func validateHeaders() throws(HTTPRequestError) {
        if let header = allHTTPHeaderFields?.first(where: { HTTPHeader.isSafe(name: $0.key, value: $0.value) == false }) {
            throw .encodingFailed(InvalidHeaderError(name: header.key))
        }
    }
}

// MARK: - Content Type

extension HTTPHeaders {
    /// The `Content-Type` value, matched case-insensitively. Setting `nil` removes the header.
    public var contentType: String? {
        get { value(for: "Content-Type") }
        set {
            guard let newValue else {
                remove(name: "Content-Type")
                return
            }
            update(name: "Content-Type", value: newValue)
        }
    }
}

// MARK: - Defaults

extension HTTPHeaders {
    /// The default set of `HTTPHeaders` used by Netti. Includes `Accept-Encoding`, `Accept-Language`, and
    /// `User-Agent`.
    public static let `default`: HTTPHeaders = [.defaultAcceptEncoding,
                                                .defaultAcceptLanguage,
                                                .defaultUserAgent]
}

extension HTTPHeader {
    /// Returns Netti's default `Accept-Encoding` header, appropriate for the encodings supported by particular OS
    /// versions.
    ///
    /// See the [Accept-Encoding HTTP header documentation](https://tools.ietf.org/html/rfc7230#section-4.2.3) .
    public static let defaultAcceptEncoding: HTTPHeader = {
        let encodings: [String] = if #available(iOS 11.0, macOS 10.13, tvOS 11.0, watchOS 4.0, *) {
            ["br", "gzip", "deflate"]
        } else {
            ["gzip", "deflate"]
        }

        return .acceptEncoding(encodings.qualityEncoded())
    }()

    /// Returns Netti's default `Accept-Language` header, generated by querying `Locale` for the user's
    /// `preferredLanguages`.
    ///
    /// See the [Accept-Language HTTP header documentation](https://tools.ietf.org/html/rfc7231#section-5.3.5).
    public static let defaultAcceptLanguage: HTTPHeader = .acceptLanguage(Locale.preferredLanguages.prefix(6).qualityEncoded())

    /// Returns Netti's default `User-Agent` header.
    ///
    /// See the [User-Agent header documentation](https://tools.ietf.org/html/rfc7231#section-5.5.3).
    ///
    /// Example: `iOS Example/1.0 (com.example.app; build:1; iOS 17.0.0)`
    public static let defaultUserAgent: HTTPHeader = {
        let info = Bundle.main.infoDictionary
        let executable = (info?["CFBundleExecutable"] as? String) ??
            (ProcessInfo.processInfo.arguments.first?.split(separator: "/").last.map(String.init)) ??
            "Unknown"
        let bundle = info?["CFBundleIdentifier"] as? String ?? "Unknown"
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let appBuild = info?["CFBundleVersion"] as? String ?? "Unknown"

        let osNameVersion: String = {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            let osName: String = {
                #if os(iOS)
                #if targetEnvironment(macCatalyst)
                return "macOS(Catalyst)"
                #else
                return "iOS"
                #endif
                #elseif os(watchOS)
                return "watchOS"
                #elseif os(tvOS)
                return "tvOS"
                #elseif os(macOS)
                #if targetEnvironment(macCatalyst)
                return "macOS(Catalyst)"
                #else
                return "macOS"
                #endif
                #elseif swift(>=5.9.2) && os(visionOS)
                return "visionOS"
                #elseif os(Linux)
                return "Linux"
                #elseif os(Windows)
                return "Windows"
                #elseif os(Android)
                return "Android"
                #else
                return "Unknown"
                #endif
            }()

            return "\(osName) \(versionString)"
        }()

        let userAgent = "\(executable)/\(appVersion) (\(bundle); build:\(appBuild); \(osNameVersion))"

        return .userAgent(userAgent)
    }()
}

extension Collection<String> {
    func qualityEncoded() -> String {
        enumerated().map { index, encoding in
            let quality = 1.0 - (Double(index) * 0.1)
            return "\(encoding);q=\(quality)"
        }.joined(separator: ", ")
    }
}

// MARK: - System Type Extensions

/// Typed access to the request's headers.
extension URLRequest {
    /// Returns `allHTTPHeaderFields` as `HTTPHeaders`.
    public var headers: HTTPHeaders {
        get { allHTTPHeaderFields.map(HTTPHeaders.init) ?? HTTPHeaders() }
        set { allHTTPHeaderFields = newValue.dictionary }
    }
}

/// Typed access to the response's headers.
extension HTTPURLResponse {
    /// Returns `allHeaderFields` as `HTTPHeaders`.
    public var headers: HTTPHeaders {
        (allHeaderFields as? [String: String]).map(HTTPHeaders.init) ?? HTTPHeaders()
    }
}

/// Typed access to the configuration's additional headers.
extension URLSessionConfiguration {
    /// Returns `httpAdditionalHeaders` as `HTTPHeaders`.
    public var headers: HTTPHeaders {
        get { (httpAdditionalHeaders as? [String: String]).map(HTTPHeaders.init) ?? HTTPHeaders() }
        set { httpAdditionalHeaders = newValue.dictionary }
    }
}
