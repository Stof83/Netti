//
//  LoggerFactory.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 06/05/25.
//

import Foundation
import os

/// A utility for logging network requests and responses in a cURL-compatible format.
///
/// `NetworkLogger` provides simple debugging tools for inspecting outgoing requests
/// and incoming responses, including support for pretty-printing JSON response bodies.
struct NetworkLogger {

    /// Shared singleton instance of `NetworkLogger`.
    ///
    /// Use this shared instance to log network activity across your app.
    static let shared = NetworkLogger()
    
    private let logger: Logger
    private let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

    /// Initializes a new instance of `NetworkLogger` with default subsystem and category.
    ///
    /// - Parameters:
    ///   - logger: An optional `Logger` instance to use. Defaults to a logger with subsystem `"Netti"` and category `"networking"`.
    init(logger: Logger = Logger(subsystem: "Netti", category: "networking")) {
        self.logger = logger
    }

    /// Logs an outgoing `URLRequest` as a cURL command.
    ///
    /// This is useful for replicating requests in terminal or sharing them during debugging.
    ///
    /// - Parameter request: The `URLRequest` to log.
    func log(_ request: URLRequest) {
        let curl = request.asCurl()
        if isPreview {
            print("🔍 [Preview] \(curl)")
        } else {
            logger.debug("\(curl, privacy: .private)")
        }
    }

    /// Logs an `HTTPResponse<Data>` including request metadata, status code, and optionally a pretty-printed body or error.
    ///
    /// This method logs the following:
    /// - The HTTP method and URL.
    /// - The status code from the `HTTPURLResponse`.
    /// - A pretty-printed JSON body if the response was successful.
    /// - A localized error description if the response failed.
    /// - The request as a cURL command for reproduction/debugging.
    ///
    /// - Parameter httpResponse: The `HTTPResponse<Data>` object to log.
    func log(_ httpResponse: HTTPResponse<Data>) {
        guard let request = httpResponse.request else {
            if isPreview {
                print("[Preview] Missing request in HTTPResponse")
            } else {
                logger.error("Missing request in HTTPResponse")
            }
            return
        }
        guard let response = httpResponse.response else {
            let message = "Missing response for request: \(request.url?.absoluteString ?? "Unknown URL")"
            
            if isPreview {
                print("[Preview] \(message)")
            } else {
                logger.error("\(message, privacy: .private)")
            }
            return
        }

        let prettyResponse = httpResponse.data?.prettyPrinted() ?? httpResponse.error?.localizedDescription ?? ""
        let logMessage = """
        \(request.httpMethod ?? "Unknown method") - \(request.url?.absoluteString ?? "Unknown URL") - \(response.statusCode)\n
        \(prettyResponse)\n
        """
        
        if isPreview {
            print("[Preview]\n\(logMessage)")
        } else {
            logger.debug("\(logMessage, privacy: .private)")
        }
    }
    
    func log<T: Decodable>(_ error: DecodingError, type: T.Type, data: Data) {
        logger.debug("\(error.stringDescription(as: type, data: data), privacy: .private)")
    }
}


extension URLRequest {
    func asCurl() -> String {
        guard let url else { return "" }
        
        var components = ["curl -v"]
        components.append("-X \(httpMethod ?? "GET")")

        for (header, value) in allHTTPHeaderFields ?? [:] {
            components.append("-H \"\(header): \(value)\"")
        }

        if let body = httpBody, let bodyString = String(data: body, encoding: .utf8) {
            components.append("-d '\(bodyString)'")
        }

        components.append("\"\(url.absoluteString)\"")
        return components.joined(separator: " \\\n\t")
    }
}

extension Data {
    func prettyPrinted() -> String {
        do {
            let jsonObject = try JSONSerialization.jsonObject(with: self, options: [])
            let prettyData = try JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted)
            return String(data: prettyData, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

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

private extension Array where Element == CodingKey {
    func pathString() -> String {
        map(\.stringValue).joined(separator: ".")
    }
}
