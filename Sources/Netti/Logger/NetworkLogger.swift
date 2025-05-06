//
//  LoggerFactory.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 06/05/25.
//

import Foundation
import os

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
        logger.debug("\(request.asCurl(), privacy: .private)")
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
            logger.error("Missing request in HTTPResponse")
            return
        }
        guard let response = httpResponse.response else {
            logger.error("Missing response for request: \(request.url?.absoluteString ?? "Unknown URL")")
            return
        }

        let prettyResponse = httpResponse.data?.prettyPrinted() ?? httpResponse.error?.localizedDescription ?? ""

        let logMessage = """
        \(request.httpMethod ?? "Unknown method") - \(request.url?.absoluteString ?? "Unknown URL") - \(response.statusCode)\n
        \(prettyResponse)\n
        """

        logger.debug("\(logMessage, privacy: .private)")
    }
    
    func log<T: Decodable>(_ error: DecodingError, type: T.Type, data: Data) {
        logger.debug("\(error.stringDescription(as: type, data: data), privacy: .private)")
    }
}

