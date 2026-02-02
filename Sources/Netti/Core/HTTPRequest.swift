//
//  defining.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//


import Foundation

/// A protocol defining the contract for a network request.
public protocol HTTPRequest {
    /// The base URL for the API.
    var baseURL: URL? { get }

    /// The base path version used in the request.
    var basePath: String { get }

    /// The path for the request, relative to the base URL and base path.
    var path: String { get }

    /// The complete URL for the request, constructed from the base URL, API version, and path.
    var requestURL: URL { get }

    /// The HTTP headers for the request.
    var headers: HTTPHeaders { get }

    /// The sample data for the mock response (if applicable).
    var sampleData: Data? { get }

    /// The timeout interval for the network request, in seconds.
    var timeoutInterval: TimeInterval { get }

    /// The cache policy associated with the request.
    ///
    /// This value is evaluated by the networking layer to determine
    /// whether and how the response should be cached and reused
    /// when the device is offline.
    var cachePolicy: HTTPCachePolicy { get }

    /// Converts the instance into a `URLRequest` with the specified HTTP method.
    ///
    /// - Parameter method: The HTTP method to use for the request.
    /// - Throws: An error if the `URLRequest` cannot be constructed.
    /// - Returns: A configured `URLRequest` instance.
    func asURLRequest(for method: HTTPMethod) throws -> URLRequest
}

// MARK: - URLRequestConvertible
extension HTTPRequest {
    /// The complete URL for the request, constructed from the base URL, API version, and path.
    public var requestURL: URL {
        guard let baseURL else {
            fatalError("Base URL is nil. Ensure a valid base URL is provided.")
        }
        return baseURL.appendingPathComponent(basePath).appendingPathComponent(path)
    }

    /// A default implementation returning `nil` for mock sample data.
    public var sampleData: Data? { nil }

    /// A default implementation providing a timeout interval of 60 seconds.
    public var timeoutInterval: TimeInterval { 60 }

    /// A default cache policy disabling caching.
    public var cachePolicy: HTTPCachePolicy { .none }

    /// Converts the instance into a `URLRequest` with the specified HTTP method.
    ///
    /// - Parameter method: The HTTP method to use for the request.
    /// - Throws: An error if the `URLRequest` cannot be constructed.
    /// - Returns: A configured `URLRequest` instance.
    public func asURLRequest(for method: HTTPMethod) throws -> URLRequest {
        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = method.rawValue
        urlRequest.allHTTPHeaderFields = headers.dictionary
        urlRequest.timeoutInterval = timeoutInterval

        return urlRequest
    }
}

extension HTTPRequest {
    /// Generates a deterministic cache key uniquely identifying the semantic request.
    ///
    /// This function is used internally by the networking and caching layers and
    /// is not intended to be accessed outside of the Core networking module.
    ///
    /// The generated key is derived from:
    /// - The resolved request path
    /// - The provided HTTP method
    /// - Sorted query parameters
    ///
    /// - Parameter method: The HTTP method associated with the request.
    /// - Returns: A stable, hashed cache key string.
    func cacheKey(for method: HTTPMethod) -> String {
        let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)

        let query = components?.queryItems?
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&") ?? ""

        let rawKey = [
            requestURL.path,
            method.rawValue,
            query
        ].joined(separator: "|")

        return rawKey.sha256
    }
}

