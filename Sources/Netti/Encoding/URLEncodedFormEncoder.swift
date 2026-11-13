//
//  URLEncodedFormEncoder.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation

/// Encodes an `Encodable` value into an `application/x-www-form-urlencoded` string.
///
/// Values are percent-escaped per RFC 3986 (`+`, `&` and `=` included), nested values use
/// bracket keys (`user[name]=Ada`), and output order is deterministic.
///
/// ```swift
/// let query = try URLEncodedFormEncoder().encode(Filter(ids: [1, 2], active: true))
/// // "active=true&ids=1&ids=2"
/// ```
public struct URLEncodedFormEncoder: Sendable {

    // MARK: - Strategies

    /// How array elements are keyed.
    public enum ArrayEncoding: Sendable {
        /// `ids=1&ids=2`
        case noBrackets
        /// `ids[]=1&ids[]=2`
        case brackets
        /// `ids[0]=1&ids[1]=2`
        case indexInBrackets

        func key(_ key: String, index: Int) -> String {
            switch self {
                case .noBrackets:
                    key
                case .brackets:
                    "\(key)[]"
                case .indexInBrackets:
                    "\(key)[\(index)]"
            }
        }
    }

    /// How `Bool` values are written.
    public enum BoolEncoding: Sendable {
        /// `true` / `false`
        case literal
        /// `1` / `0`
        case numeric

        func encode(_ value: Bool) -> String {
            switch self {
                case .literal:
                    value ? "true" : "false"
                case .numeric:
                    value ? "1" : "0"
            }
        }
    }

    /// How `Date` values are written.
    public enum DateEncoding: Sendable {
        /// ISO 8601 in UTC, for example `2026-10-27T10:00:00Z`.
        case iso8601
        /// Seconds since 1 January 1970.
        case secondsSince1970
        /// Milliseconds since 1 January 1970.
        case millisecondsSince1970
        /// The string produced by the formatter.
        case formatted(DateFormatter)
        /// The string produced by the closure.
        case custom(@Sendable (Date) throws -> String)

        func encode(_ date: Date) throws -> String {
            switch self {
                case .iso8601:
                    date.formatted(.iso8601)
                case .secondsSince1970:
                    Self.epochString(date.timeIntervalSince1970)
                case .millisecondsSince1970:
                    Self.epochString(date.timeIntervalSince1970 * Self.millisecondsPerSecond)
                case .formatted(let formatter):
                    formatter.string(from: date)
                case .custom(let encode):
                    try encode(date)
            }
        }

        /// `yyyy-MM-dd'T'HH:mm:ss.SSSZ` in the current time zone, for example `2026-10-27T11:00:00.000+0100`.
        ///
        /// Matches ``JSONManager``'s default date format, so query and body dates match.
        @usableFromInline
        static let `default`: DateEncoding = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            return .formatted(formatter)
        }()

        private static let millisecondsPerSecond: TimeInterval = 1000

        private static func epochString(_ interval: TimeInterval) -> String {
            interval.rounded() == interval ? String(Int64(interval)) : String(interval)
        }
    }

    /// How keys of keyed containers are transformed.
    public enum KeyEncoding: Sendable {
        /// Keys are used as declared.
        case useDefaultKeys
        /// `pageNumber` becomes `page_number` and `userID` becomes `user_id`.
        ///
        /// Acronyms stay together: `URLValue` becomes `url_value`, `ID` becomes `id` and `my_Value` becomes
        /// `my_value`. ``JSONManager``'s snake_case uses the same conversion, so query and body keys match.
        /// `JSONEncoder`'s own `.convertToSnakeCase` differs for those keys (`u_rl_value`, `i_d`, `my__value`).
        case convertToSnakeCase
        /// Keys are transformed by the closure.
        case custom(@Sendable (String) -> String)

        /// Mirrors a `JSONEncoder` key strategy, so query keys match body keys.
        ///
        /// A `.custom` closure receives the key alone as its coding path. Unknown strategies keep keys as declared.
        init(_ strategy: JSONEncoder.KeyEncodingStrategy) {
            switch strategy {
                case .useDefaultKeys:
                    self = .useDefaultKeys
                case .convertToSnakeCase:
                    self = .convertToSnakeCase
                case .custom(let encode):
                    self = .custom { encode([FormCodingKey(stringValue: $0)]).stringValue }
                @unknown default:
                    self = .useDefaultKeys
            }
        }

        func encode(_ key: String) -> String {
            switch self {
                case .useDefaultKeys:
                    key
                case .convertToSnakeCase:
                    key.snakeCased
                case .custom(let encode):
                    encode(key)
            }
        }
    }

    /// How spaces are escaped.
    public enum SpaceEncoding: Sendable {
        /// `%20`
        case percentEscaped
        /// `+`
        case plusReplaced
    }

    // MARK: - Properties

    /// Sorts keys alphabetically at every nesting level so output never depends on dictionary order. Default `true`.
    public var alphabetizeKeyValuePairs: Bool
    /// How array elements are keyed. Default `.noBrackets`.
    public var arrayEncoding: ArrayEncoding
    /// How `Bool` values are written. Default `.literal`.
    public var boolEncoding: BoolEncoding
    /// How `Date` values are written. Default `yyyy-MM-dd'T'HH:mm:ss.SSSZ` in the current time zone, matching
    /// ``JSONManager``.
    public var dateEncoding: DateEncoding
    /// How keys are transformed. Default `.useDefaultKeys`.
    public var keyEncoding: KeyEncoding
    /// How spaces are escaped. Default `.percentEscaped`.
    public var spaceEncoding: SpaceEncoding

    // MARK: - Initialization

    /// Creates an encoder. Every strategy has a default, so `URLEncodedFormEncoder()` covers the common case.
    ///
    /// - Parameters:
    ///   - alphabetizeKeyValuePairs: Sorts keys at every nesting level. `true` by default.
    ///   - arrayEncoding: How array elements are keyed. `.noBrackets` by default.
    ///   - boolEncoding: How `Bool` values are written. `.literal` by default.
    ///   - dateEncoding: How `Date` values are written. `yyyy-MM-dd'T'HH:mm:ss.SSSZ` in the current time zone by
    ///     default, matching ``JSONManager``.
    ///   - keyEncoding: How keys are transformed. `.useDefaultKeys` by default.
    ///   - spaceEncoding: How spaces are escaped. `.percentEscaped` by default.
    public init(
        alphabetizeKeyValuePairs: Bool = true,
        arrayEncoding: ArrayEncoding = .noBrackets,
        boolEncoding: BoolEncoding = .literal,
        dateEncoding: DateEncoding = .default,
        keyEncoding: KeyEncoding = .useDefaultKeys,
        spaceEncoding: SpaceEncoding = .percentEscaped
    ) {
        self.alphabetizeKeyValuePairs = alphabetizeKeyValuePairs
        self.arrayEncoding = arrayEncoding
        self.boolEncoding = boolEncoding
        self.dateEncoding = dateEncoding
        self.keyEncoding = keyEncoding
        self.spaceEncoding = spaceEncoding
    }

    // MARK: - Encoding

    /// Encodes `value` into a percent-escaped query string (without a leading `?`).
    ///
    /// - Parameter value: A value that encodes into a keyed container, such as a struct or `[String: T]`.
    /// - Throws: `EncodingError.invalidValue` when the top-level value is not keyed, or a value cannot be represented.
    /// - Returns: The encoded string; empty when `value` has no non-nil members.
    public func encode(_ value: some Encodable) throws -> String {
        try encodedPairs(value)
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    /// The unescaped key/value pairs, in output order.
    func encodedPairs(_ value: some Encodable) throws -> [(key: String, value: String)] {
        let context = URLEncodedFormContext()
        try URLEncodedFormComponentEncoder(context: context, options: self, formPath: []).encode(value)

        guard case .object(let members) = context.component else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: [], debugDescription: "URL-encoded forms require a keyed top-level value.")
            )
        }
        return sorted(members).flatMap { pairs(from: $0.value, key: $0.key) }
    }

    // MARK: - Private Helpers

    private func pairs(from component: URLEncodedFormComponent, key: String) -> [(key: String, value: String)] {
        switch component {
            case .string(let value):
                [(key, value)]
            case .array(let elements):
                elements.enumerated().flatMap { index, element in
                    pairs(from: element, key: arrayEncoding.key(key, index: index))
                }
            case .object(let members):
                sorted(members).flatMap { pairs(from: $0.value, key: "\(key)[\($0.key)]") }
        }
    }

    private func sorted(_ members: [URLEncodedFormComponent.Member]) -> [URLEncodedFormComponent.Member] {
        alphabetizeKeyValuePairs ? members.sorted { $0.key < $1.key } : members
    }

    private func escape(_ string: String) -> String {
        let escaped = string.addingPercentEncoding(withAllowedCharacters: Self.allowedCharacters) ?? string
        switch spaceEncoding {
            case .percentEscaped:
                return escaped
            case .plusReplaced:
                return escaped.replacingOccurrences(of: "%20", with: "+")
        }
    }

    /// RFC 3986 query characters minus the general (`:#[]@`) and sub-delimiters (`!$&'()*+,;=`), as Alamofire does.
    private static let allowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return allowed
    }()
}

// MARK: - Snake Case

extension String {
    /// Inserts `_` before each word start and lowercases, keeping acronyms together (`myURLValue` → `my_url_value`).
    var snakeCased: String {
        let characters = Array(self)
        var result = ""

        for (index, character) in characters.enumerated() {
            guard character.isUppercase else {
                result.append(character)
                continue
            }
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let followsLowercase = previous.map { $0.isUppercase == false && $0 != "_" } ?? false
            let endsAcronym = (previous?.isUppercase ?? false) && (next?.isLowercase ?? false)

            if followsLowercase || endsAcronym {
                result.append("_")
            }
            result.append(contentsOf: character.lowercased())
        }
        return result
    }
}
