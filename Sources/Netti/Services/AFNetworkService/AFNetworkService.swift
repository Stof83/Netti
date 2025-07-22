//
//  AFNetworkService.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Alamofire
import Foundation

/// A concrete implementation of `NetworkService` that utilizes Alamofire for performing HTTP operations.
///
/// `AFNetworkService` enables asynchronous network communication by sending HTTP requests,
/// supporting parameter encoding, response validation, and caching mechanisms.
///
/// It is configurable via an `AFConfiguration` instance, allowing developers to define:
/// - Server trust policies (e.g., SSL pinning)
/// - Parameter encoding strategies (URL and JSON)
/// - Response caching behavior
///
/// Example usage:
/// ```swift
/// let configuration = AFConfiguration()
/// let networkService = AFNetworkService(configuration: configuration)
///
/// let response = try await networkService.send(
///     request,
///     parameters: ["key": "value"],
///     method: .get
/// )
/// ```
///
/// This class is thread-safe and designed for modern Swift concurrency with `async/await`.
public final class AFNetworkService: NetworkService, @unchecked Sendable {
    // MARK: - Properties

    /// The Alamofire session used to execute HTTP requests.
    private let session: Session

    /// The configuration object specifying trust, caching, and encoding behavior.
    private let configuration: AFConfiguration

    // MARK: - Initialization

    /// Initializes a new instance of `AFNetworkService` using the provided configuration.
    ///
    /// - Parameter configuration: The configuration that defines trust evaluation, caching policy,
    ///   and encoding strategies for URL and JSON parameters.
    ///
    /// If a `serverTrustManager` is provided in the configuration, it will be used to manage
    /// SSL pinning and trust evaluations for secure communication.
    public init(configuration: AFConfiguration = .init()) {
        self.configuration = configuration

        if let trustManager = configuration.serverTrustManager {
            let sessionConfiguration = URLSessionConfiguration.af.default
            self.session = Session(configuration: sessionConfiguration, serverTrustManager: trustManager)
        } else {
            self.session = Session(configuration: URLSessionConfiguration.af.default)
        }
    }

    // MARK: - Asynchronous Request using async/await

    /// Sends an HTTP request using the configured Alamofire session and returns a wrapped HTTP response.
    ///
    /// This method supports both URL-encoded and JSON-encoded parameters, based on the request method.
    /// It validates the response, applies the configured caching policy, and returns an `HTTPResponse`
    /// object containing the request, response, raw data, and any error encountered.
    ///
    /// - Parameters:
    ///   - request: The HTTP request configuration (URL, headers, etc.) to be sent.
    ///   - parameters: A dictionary of parameters to include in the request body or query string.
    ///     Values must conform to both `Any` and `Sendable`.
    ///   - method: The HTTP method to use, such as `.get`, `.post`, `.put`, etc.
    ///
    /// - Returns: An `HTTPResponse<Data?>` object that contains the original request, HTTPURLResponse,
    ///   optional data, and any error encountered during the request.
    ///
    /// - Throws: An error if request encoding fails.
    public func send(
        _ request: HTTPRequest,
        parameters: [String: any Any & Sendable]?,
        method: HTTPMethod
    ) async throws -> HTTPResponse<Data> {
        let urlRequest = try request.asURLRequest(for: method)
        
        let encoding: ParameterEncoding = switch method {
            case .get, .delete, .head: configuration.urlEncoding /// query string
            case .post, .put, .patch: configuration.jsonEncoding /// HTTP body
            default: configuration.urlEncoding /// safe fallback
        }
        
        let encodedRequest = try encoding.encode(urlRequest, with: parameters)

        NetworkLogger.shared.log(encodedRequest)
        
        let response = await session.request(encodedRequest)
            .cacheResponse(using: configuration.cacheResponse)
            .validate()
            .serializingData()
            .response

        return HTTPResponse(
            request: response.request,
            response: response.response,
            data: response.data,
            rawData: response.data,
            error: response.error
        )
    }
}
