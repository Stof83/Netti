//
//  LoggerFactory.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 06/05/25.
//

import Foundation
import os

/// The default ``EventMonitor``: logs requests as cURL commands and responses with their status.
///
/// Logging goes to the unified system log with every payload marked private. The value of every
/// header and query item whose name marks a credential is replaced by ``redactionMarker``, and so
/// is the whole body of a request carrying such a header. In any other logged body, request or
/// response, the values of credential names are redacted at any depth when it is JSON and per pair
/// when it is form-urlencoded. A request body in another format is logged as it is; a response
/// body that is not JSON is not logged. A body over 64 KB is never parsed or logged, only its byte
/// count.
///
/// A name marks a credential when, compared case-insensitively, it contains `auth`, `token`, `key`,
/// `secret`, `session`, `cookie`, `password`, `passwd`, `pwd`, `signature`, `credential` or `otp`;
/// when one of its words is `sig` or `pin` (`X-Sig`, `userPin`, but not `design` or `spinner`); or
/// when it is `code` or `X-Code`, the OAuth authorization code.
///
/// ```swift
/// let logger = NetworkLogger()                    // on
/// let silent = NetworkLogger(isEnabled: false)    // emits nothing
/// ```
///
/// ``Netti`` installs one in DEBUG builds unless ``Netti/isLoggingEnabled`` is `false`; you rarely
/// create one yourself.
public struct NetworkLogger: EventMonitor {

    /// Replaces the value of every sensitive header in a log.
    public static let redactionMarker = Redaction.marker

    private let isEnabled: Bool
    private let output: @Sendable (OSLogType, String) -> Void

    /// Creates a logger.
    ///
    /// - Parameter isEnabled: When `false` the logger emits nothing.
    public init(isEnabled: Bool = true) {
        self.init(isEnabled: isEnabled, output: Self.systemLog)
    }

    /// Creates a logger that sends its messages to `output`; tests use it to capture them.
    init(isEnabled: Bool = true, output: @escaping @Sendable (OSLogType, String) -> Void) {
        self.isEnabled = isEnabled
        self.output = output
    }

    // MARK: - EventMonitor

    /// Logs the request as a cURL command, with sensitive headers redacted.
    ///
    /// - Parameter request: The request as sent, after adaptation.
    public func requestDidSend(_ request: URLRequest) {
        log(request)
    }

    /// Logs the method, URL, status code and pretty-printed JSON body of the response, with
    /// credential values redacted.
    ///
    /// - Parameter response: The raw response, before decoding.
    public func requestDidReceiveResponse(_ response: HTTPResponse<Data>) {
        log(response)
    }

    /// Logs the failure as an error.
    ///
    /// - Parameters:
    ///   - request: The request that failed.
    ///   - error: The error the call throws.
    public func requestDidFail(_ request: URLRequest, error: HTTPRequestError) {
        emit(.error, "Request failed: \(request.url.map(Redaction.string(for:)) ?? "Unknown URL") - \(error)")
    }

    // MARK: - Logging

    /// Logs an outgoing `URLRequest` as a cURL command with sensitive headers redacted.
    ///
    /// - Parameter request: The `URLRequest` to log.
    func log(_ request: URLRequest) {
        emit(.debug, request.asCurl())
    }

    /// Logs an `HTTPResponse<Data>`: method, URL, status code, and a pretty-printed body or the error.
    ///
    /// - Parameter httpResponse: The `HTTPResponse<Data>` object to log.
    func log(_ httpResponse: HTTPResponse<Data>) {
        guard isEnabled else { return }
        guard let request = httpResponse.request else {
            emit(.error, "Missing request in HTTPResponse")
            return
        }

        guard let response = httpResponse.response else {
            emit(.error, "Missing response for request: \(request.url.map(Redaction.string(for:)) ?? "Unknown URL")")
            return
        }

        let prettyResponse = httpResponse.data?.prettyPrinted() ?? httpResponse.error?.localizedDescription ?? ""
        emit(.debug, """
        \(request.httpMethod ?? "Unknown method") - \(request.url.map(Redaction.string(for:)) ?? "Unknown URL") - \(response.statusCode)\n
        \(prettyResponse)\n
        """)
    }

    /// Logs a decoding failure. The body is logged, redacted, only when it is JSON of at most
    /// 64 KB; otherwise only the coding path and the byte count are (TM-37, TM-40).
    func log<T: Decodable>(_ error: DecodingError, type: T.Type, data: Data) {
        guard isEnabled else { return }
        guard data.count <= Redaction.maximumLoggedBodySize else {
            emit(.debug, error.summary(as: type, body: Redaction.oversizedBody(byteCount: data.count)))
            return
        }
        guard let json = Redaction.redactedJSON(data) else {
            emit(.debug, error.summary(as: type, body: "<body of \(data.count) bytes not logged: not JSON>"))
            return
        }
        emit(.debug, error.stringDescription(as: type, data: Data(json.utf8)))
    }

    private func emit(_ level: OSLogType, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        output(level, message())
    }

    private static let systemLog: @Sendable (OSLogType, String) -> Void = {
        let logger = Logger(subsystem: "Netti", category: "networking")
        return { level, message in
            logger.log(level: level, "\(message, privacy: .private)")
        }
    }()
}


extension URLRequest {
    /// The request as a `curl` command you can paste into a terminal.
    ///
    /// The command reproduces the method, URL, headers and UTF-8 text body, and carries no flag that
    /// changes what is sent, such as `-v`. A body that is not valid UTF-8 is left out. The result is
    /// empty when the request has no URL.
    ///
    /// By default credentials are replaced by `<redacted>`: the value of every header and query item
    /// whose name marks a credential, the whole body of a request that carries a credential header,
    /// and credential values in any other JSON or form-urlencoded body, by the same rules as
    /// ``NetworkLogger``. A body over 64 KB is replaced by its byte count. Pass `false` to get every
    /// value exactly as sent, and take care where you paste the result.
    ///
    /// Every header, body and URL is quoted, so a shell passes each value to `curl` unchanged and runs
    /// nothing else. A control character such as ESC or a carriage return is written as an escape
    /// (`$'\x1B'`), never raw, so pasting the command cannot drive the terminal.
    ///
    /// ```swift
    /// print(request.cURLDescription())                                    // safe to share
    /// print(request.cURLDescription(maskingSensitiveValues: false))       // as sent
    /// ```
    ///
    /// - Parameter maskingSensitiveValues: Whether to redact credentials. Defaults to `true`.
    /// - Returns: The command, or an empty string when the request has no URL.
    public func cURLDescription(maskingSensitiveValues: Bool = true) -> String {
        guard let url else { return "" }

        let method = httpMethod ?? "GET"
        var components = ["curl", "-X \(method.isShellWord ? method : method.shellQuoted)"]

        let headers = (allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key })
        for (header, value) in headers {
            let shown = maskingSensitiveValues ? Redaction.value(value, named: header) : value
            components.append("-H \("\(header): \(shown)".shellQuoted)")
        }

        if let body = httpBody {
            if maskingSensitiveValues, headers.contains(where: { Redaction.isSensitive($0.key) }) {
                components.append("--data-raw \(Redaction.marker.shellQuoted)")
            } else if maskingSensitiveValues, body.count > Redaction.maximumLoggedBodySize {
                components.append("--data-raw \(Redaction.oversizedBody(byteCount: body.count).shellQuoted)")
            } else if let bodyString = String(data: body, encoding: .utf8) {
                components.append("--data-raw \((maskingSensitiveValues ? Redaction.body(bodyString) : bodyString).shellQuoted)")
            }
        }

        let shownURL = maskingSensitiveValues ? Redaction.string(for: url) : url.absoluteString
        components.append(shownURL.shellQuoted)
        return components.joined(separator: " \\\n\t")
    }

    /// The request as a cURL command with credentials always redacted; what ``NetworkLogger`` logs.
    func asCurl() -> String {
        cURLDescription(maskingSensitiveValues: true)
    }
}

private extension Unicode.Scalar {
    /// A control character a terminal acts on, other than a line feed or a tab.
    var isUnsafeControl: Bool {
        (value < 0x20 && self != "\n" && self != "\t") || value == 0x7F
    }
}

private extension String {
    /// The text as one shell word.
    ///
    /// Plain text is single-quoted, each embedded single quote written as `'\''`. Text with a
    /// control character other than a line feed or a tab uses the `$'...'` form instead, with each
    /// one written as `\xHH`, so pasting the command never sends an escape sequence to the terminal.
    /// A NUL cannot be part of a command-line argument: a shell ends the word at it.
    var shellQuoted: String {
        guard unicodeScalars.contains(where: \.isUnsafeControl) else {
            return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var quoted = "$'"
        for scalar in unicodeScalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "'": quoted += "\\'"
            case "\n": quoted += "\\n"
            case "\t": quoted += "\\t"
            case _ where scalar.isUnsafeControl:
                quoted += "\\x" + (scalar.value < 0x10 ? "0" : "") + String(scalar.value, radix: 16, uppercase: true)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "'"
    }

    /// Whether the text is only ASCII letters, so a shell reads it as one plain word.
    var isShellWord: Bool {
        isEmpty == false && utf8.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) }
    }
}

extension Data {
    /// The JSON as pretty-printed text with credential values redacted, empty when it is not JSON,
    /// or only the byte count when it is over 64 KB, which is then never parsed.
    func prettyPrinted() -> String {
        guard count <= Redaction.maximumLoggedBodySize else {
            return Redaction.oversizedBody(byteCount: count)
        }
        do {
            var didRedact = false
            let jsonObject = Redaction.redactingJSON(try JSONSerialization.jsonObject(with: self, options: []), didRedact: &didRedact)
            let prettyData = try JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted)
            return String(data: prettyData, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

/// Readable descriptions of decoding failures.
extension DecodingError {
    /// Returns a detailed, multi-line description of the decoding error.
    ///
    /// - Parameters:
    ///   - type: The type that was attempted to decode.
    ///   - data: The raw `Data` that failed to decode.
    /// - Returns: A formatted string describing the error and its context.
    public func stringDescription<T: Decodable>(as type: T.Type, data: Data) -> String {
        var lines: [String] = []
        lines.append("Decoding failed for type: \(T.self)")

        switch self {
        case .typeMismatch(let expected, let context):
            lines.append("Type mismatch: expected \(expected)")
            lines.append("Coding path: \(context.codingPath.pathString())")
            lines.append("Debug description: \(context.debugDescription)")

        case .valueNotFound(let expected, let context):
            lines.append("Value not found: \(expected)")
            lines.append("Coding path: \(context.codingPath.pathString())")
            lines.append("Debug description: \(context.debugDescription)")

        case .keyNotFound(let key, let context):
            lines.append("Key not found: '\(key.stringValue)'")
            lines.append("Coding path: \(context.codingPath.pathString())")
            lines.append("Debug description: \(context.debugDescription)")

        case .dataCorrupted(let context):
            lines.append("Data corrupted")
            lines.append("Coding path: \(context.codingPath.pathString())")
            lines.append("Debug description: \(context.debugDescription)")

        @unknown default:
            lines.append("Unknown decoding error")
        }

        if let rawJSON = String(data: data, encoding: .utf8) {
            lines.append("Raw JSON:")
            lines.append(rawJSON)
        }

        return lines.joined(separator: "\n")
    }
}

extension DecodingError {
    /// The failure's case and coding path followed by `body`, never the debug description or the
    /// raw data, for a body that must not be logged.
    func summary<T: Decodable>(as type: T.Type, body: String) -> String {
        let (headline, context): (String, Context?) = switch self {
            case .typeMismatch(let expected, let context): ("Type mismatch: expected \(expected)", context)
            case .valueNotFound(let expected, let context): ("Value not found: \(expected)", context)
            case .keyNotFound(let key, let context): ("Key not found: '\(key.stringValue)'", context)
            case .dataCorrupted(let context): ("Data corrupted", context)
            @unknown default: ("Unknown decoding error", nil)
        }
        return [
            "Decoding failed for type: \(T.self)",
            headline,
            "Coding path: \(context?.codingPath.pathString() ?? "")",
            body,
        ].joined(separator: "\n")
    }
}

private extension Array where Element == CodingKey {
    func pathString() -> String {
        map(\.stringValue).joined(separator: ".")
    }
}
