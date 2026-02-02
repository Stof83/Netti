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
    // MARK: - Private Properties

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
        
        let sessionConfiguration = URLSessionConfiguration.af.default
        
        if let trustManager = configuration.serverTrustManager {
            self.session = Session(
                configuration: sessionConfiguration,
                serverTrustManager: trustManager
            )
        } else {
            self.session = Session(configuration: sessionConfiguration)
        }
        
    }
    
    // MARK: - Asynchronous Request using async/await

    /// Sends an HTTP request and returns a wrapped HTTP response.
    ///
    /// When offline, cached data is returned if available and the request
    /// is stored for automatic retry once connectivity is restored.
    ///
    /// - Parameters:
    ///   - request: The HTTP request definition.
    ///   - parameters: Optional request parameters.
    ///   - method: The HTTP method to use.
    ///
    /// - Returns: An `HTTPResponse<Data>` representing the result.
    public func send(
        _ request: HTTPRequest,
        parameters: [String: any Any & Sendable]?,
        method: HTTPMethod
    ) async throws -> HTTPResponse<Data> {
        
        let response = try await performNetworkRequest(
            request,
            parameters: parameters,
            method: method
        )
        
        return response
    }
    
    /// Sends a raw URLRequest directly.
    ///
    /// - Parameter request: The native `URLRequest` to execute.
    /// - Returns: An `HTTPResponse` object containing the raw `Data`.
    public func send(_ request: URLRequest) async throws -> HTTPResponse<Data> {
        
        NetworkLogger.shared.log(request)
        
        let response = await session.request(request)
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
    
    // MARK: - Helper Methods
    
    /// Creates a `URLRequest` from the given parameters without sending it.
    public func createURLRequest(
        _ request: HTTPRequest,
        parameters: [String: any Any & Sendable]?,
        method: HTTPMethod
    ) throws -> URLRequest {
        
        let urlRequest = try request.asURLRequest(for: method)
        
        let encoding: ParameterEncoding = switch method {
            case .get, .delete, .head:
                configuration.urlEncoding
            case .post, .put, .patch:
                configuration.jsonEncoding
            default:
                configuration.urlEncoding
        }
        
        return try encoding.encode(urlRequest, with: parameters)
    }
    
    // MARK: - Private Helpers

    /// Executes the actual Alamofire request.
    private func performNetworkRequest(
        _ request: HTTPRequest,
        parameters: [String: any Any & Sendable]?,
        method: HTTPMethod
    ) async throws -> HTTPResponse<Data> {
        
        let urlRequest = try request.asURLRequest(for: method)
        
        let encoding: ParameterEncoding = switch method {
            case .get, .delete, .head:
                configuration.urlEncoding
            case .post, .put, .patch:
                configuration.jsonEncoding
            default:
                configuration.urlEncoding
        }
        
        let encodedRequest = try encoding.encode(urlRequest, with: parameters)
        
        NetworkLogger.shared.log(encodedRequest)
        
        let response = await session.request(encodedRequest)
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
