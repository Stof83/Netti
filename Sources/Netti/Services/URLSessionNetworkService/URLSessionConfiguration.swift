//
//  URLSessionConfiguration.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 05/05/25.
//

import Foundation

/// A protocol that defines a method for encoding parameters into a `URLRequest`.
public protocol ParameterEncoder {
    /// Encodes the given parameters into the provided `URLRequest`.
    ///
    /// - Parameters:
    ///   - request: The `URLRequest` to modify with encoded parameters.
    ///   - parameters: A dictionary of parameters where the values must conform to `Any` and `Sendable`.
    /// - Throws: An error if encoding fails.
    func encode(_ request: inout URLRequest, with parameters: [String: any Any & Sendable]?) throws
}

/// A configuration struct for selecting parameter encoding strategies for `URLSession` requests.
public struct URLSessionConfigurationWrapper {
    /// The encoder used for encoding URL query parameters (typically for GET requests).
    public let urlEncoding: ParameterEncoder

    /// The encoder used for encoding JSON body parameters (typically for POST, PUT, etc.).
    public let jsonEncoding: ParameterEncoder

    /// Initializes a new `URLSessionConfiguration` with optional custom encoders.
    ///
    /// - Parameters:
    ///   - urlEncoding: The encoder to use for URL query parameters. Defaults to `URLQueryParameterEncoder`.
    ///   - jsonEncoding: The encoder to use for JSON body parameters. Defaults to `JSONBodyParameterEncoder`.
    public init(
        urlEncoding: ParameterEncoder = URLQueryParameterEncoder(),
        jsonEncoding: ParameterEncoder = JSONBodyParameterEncoder()
    ) {
        self.urlEncoding = urlEncoding
        self.jsonEncoding = jsonEncoding
    }
}

/// An encoder that serializes parameters into the HTTP body as JSON.
public struct JSONBodyParameterEncoder: ParameterEncoder {
    /// Creates a new instance of `JSONBodyParameterEncoder`.
    public init() {}

    /// Encodes parameters into the HTTP body of the given `URLRequest` as JSON.
    ///
    /// - Parameters:
    ///   - request: The request to modify. The method adds a JSON-encoded body and sets the
    ///     `Content-Type` header to `application/json`.
    ///   - parameters: The parameters to encode. Keys are strings, and values must conform to `Any` and `Sendable`.
    /// - Throws: An error if the parameters cannot be converted to JSON.
    public func encode(_ request: inout URLRequest, with parameters: [String: any Any & Sendable]?) throws {
        guard let parameters else { return }
        
        let jsonObject = Dictionary(uniqueKeysWithValues: parameters.map { ($0.key, $0.value) })
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
}

/// An encoder that serializes parameters into the URL query string.
public struct URLQueryParameterEncoder: ParameterEncoder {
    /// Creates a new instance of `URLQueryParameterEncoder`.
    public init() {}

    /// Encodes parameters into the URL of the given `URLRequest` as query items.
    ///
    /// - Parameters:
    ///   - request: The request to modify. The method updates the URL by appending query parameters.
    ///   - parameters: The parameters to encode. Keys are strings, and values must conform to `Any` and `Sendable`.
    /// - Throws: A `URLError` if the URL is invalid or cannot be modified.
    public func encode(_ request: inout URLRequest, with parameters: [String: any Any & Sendable]?) throws {
        guard let parameters else { return }
        
        guard var urlComponents = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }

        urlComponents.queryItems = parameters.map {
            URLQueryItem(name: $0.key, value: String(describing: $0.value))
        }

        request.url = urlComponents.url
    }
}

