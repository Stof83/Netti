//
//  Redaction.swift
//  Netti
//

import Foundation

/// Hides credentials from logs and descriptions: header values, query values and body values whose
/// names mark a credential, and URL passwords.
///
/// A name, compared case-insensitively, marks a credential when:
/// - it contains `auth`, `token`, `key`, `secret`, `session`, `cookie`, `password`, `passwd`, `pwd`,
///   `signature`, `credential` or `otp` anywhere (`X-Amz-Signature`, `totp`);
/// - one of its words is `sig` or `pin`, where words split at every character that is not a letter
///   or digit and at every lowercase-to-uppercase change (`x-sig`, `userPin`, but not `design` or
///   `spinner`);
/// - it is exactly `code`, the OAuth authorization code, optionally after an `X-` prefix (not
///   `countryCode`).
///
/// The fragments over-redact some harmless names, such as `Idempotency-Key`, by design.
enum Redaction {

    // MARK: - Constants

    static let marker = "<redacted>"

    private static let sensitiveFragments = [
        "auth", "token", "key", "secret", "session", "cookie", "password", "passwd", "pwd", "signature", "credential", "otp",
    ]
    private static let sensitiveWords: Set<String> = ["sig", "pin"]
    private static let sensitiveExactNames: Set<String> = ["code"]

    // MARK: - Names

    /// Whether `name` marks a credential.
    static func isSensitive(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        if sensitiveFragments.contains(where: { lowercased.contains($0) }) {
            return true
        }
        let unprefixed = lowercased.hasPrefix("x-") ? String(lowercased.dropFirst(2)) : lowercased
        if sensitiveExactNames.contains(unprefixed) {
            return true
        }
        return words(of: name).contains(where: sensitiveWords.contains)
    }

    /// `value`, or the marker when `name` marks a credential.
    static func value(_ value: String, named name: String) -> String {
        isSensitive(name) ? marker : value
    }

    // MARK: - URLs

    /// `url` with credential query values and any password replaced by the marker.
    static func string(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return marker
        }
        if components.password != nil {
            components.password = marker
        }
        components.queryItems = components.queryItems?.map { item in
            guard item.value != nil, isSensitive(item.name) else {
                return item
            }
            return URLQueryItem(name: item.name, value: marker)
        }
        // `URLComponents` percent-encodes the marker; show it as written.
        let encodedMarker = marker.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? marker
        return components.string?.replacingOccurrences(of: encodedMarker, with: marker) ?? marker
    }

    // MARK: - Bodies

    /// `text`, a request or response body, with the value of every credential name replaced by the
    /// marker: at any depth when it is JSON, per pair when it is form-urlencoded. Any other text,
    /// and a body with no credential name, is returned unchanged.
    static func body(_ text: String) -> String {
        redactedJSON(Data(text.utf8)) ?? redactingForm(text) ?? text
    }

    /// `data` as JSON text with the value of every credential key, at any depth, replaced by the
    /// marker; `nil` when `data` is not JSON. JSON without a credential key is returned as received.
    static func redactedJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return nil
        }
        var didRedact = false
        let redacted = redactingJSON(object, didRedact: &didRedact)
        guard didRedact,
              let redactedData = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: redactedData, as: UTF8.self)
    }

    // MARK: - Body Size

    /// The largest body, in bytes, that is parsed, redacted and logged. A larger body is never
    /// parsed; only its byte count is logged (TM-40).
    static let maximumLoggedBodySize = 64 * 1024

    /// The text logged in place of a body over ``maximumLoggedBodySize``.
    static func oversizedBody(byteCount: Int) -> String {
        "<body of \(byteCount) bytes not logged: over the 64 KB log limit>"
    }

    /// `object`, a parsed JSON value, with the value of every credential key, at any depth, replaced
    /// by the marker.
    static func redactingJSON(_ object: Any, didRedact: inout Bool) -> Any {
        switch object {
            case let dictionary as [String: Any]:
                var result: [String: Any] = [:]
                for (key, value) in dictionary {
                    if isSensitive(key) {
                        result[key] = marker
                        didRedact = true
                    } else {
                        result[key] = redactingJSON(value, didRedact: &didRedact)
                    }
                }
                return result
            case let array as [Any]:
                return array.map { redactingJSON($0, didRedact: &didRedact) }
            default:
                return object
        }
    }

    /// `text` with credential values replaced by the marker when it reads as form-urlencoded pairs
    /// (`name=value&…`, no whitespace) and holds a credential name; otherwise `nil`.
    private static func redactingForm(_ text: String) -> String? {
        guard text.contains("="), text.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) == false else {
            return nil
        }
        var didRedact = false
        let pairs = text.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            guard let equals = pair.firstIndex(of: "=") else {
                return String(pair)
            }
            let rawName = pair[..<equals]
            let name = rawName.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(rawName)
            guard isSensitive(name) else {
                return String(pair)
            }
            didRedact = true
            return "\(rawName)=\(marker)"
        }
        return didRedact ? pairs.joined(separator: "&") : nil
    }

    // MARK: - Requests

    /// The method, host and path of `request`, never its query, headers or body.
    static func summary(of request: URLRequest?, url fallbackURL: URL? = nil) -> String {
        let url = request?.url ?? fallbackURL
        let method = request?.httpMethod ?? HTTPMethod.get.rawValue
        guard let url else {
            return method
        }
        return "\(method) \(url.host(percentEncoded: false) ?? "")\(url.path(percentEncoded: true))"
    }

    // MARK: - Private Helpers

    /// The lowercased words of `name`, split at every character that is not a letter or digit and
    /// at every lowercase-to-uppercase change: `X-Sig` gives `x`, `sig`; `userPin` gives `user`, `pin`.
    private static func words(of name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousIsLowercase = false
        for character in name {
            guard character.isLetter || character.isNumber else {
                if current.isEmpty == false {
                    words.append(current)
                    current = ""
                }
                previousIsLowercase = false
                continue
            }
            if character.isUppercase, previousIsLowercase {
                words.append(current)
                current = ""
            }
            current += character.lowercased()
            previousIsLowercase = character.isLowercase
        }
        if current.isEmpty == false {
            words.append(current)
        }
        return words
    }
}
