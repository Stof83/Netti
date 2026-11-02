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
    /// The request as a cURL command, with credential headers, query values and the body of a
    /// request carrying a credential redacted, and credential values redacted in any other JSON or
    /// form-urlencoded body.
    func asCurl() -> String {
        guard let url else { return "" }

        var components = ["curl -v"]
        components.append("-X \(httpMethod ?? "GET")")

        let headers = (allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key })
        for (header, value) in headers {
            components.append("-H \"\(header): \(Redaction.value(value, named: header))\"")
        }

        if let body = httpBody {
            if headers.contains(where: { Redaction.isSensitive($0.key) }) {
                components.append("-d '\(Redaction.marker)'")
            } else if body.count > Redaction.maximumLoggedBodySize {
                components.append("-d '\(Redaction.oversizedBody(byteCount: body.count))'")
            } else if let bodyString = String(data: body, encoding: .utf8) {
                components.append("-d '\(Redaction.body(bodyString))'")
            }
        }

        components.append("\"\(Redaction.string(for: url))\"")
        return components.joined(separator: " \\\n\t")
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
