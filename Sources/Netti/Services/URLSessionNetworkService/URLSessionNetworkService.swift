//
//  URLSessionNetworkService.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 05/05/25.
//

import Foundation
import Alamofire

/// A network service using URLSession with offline-aware caching support.
public final class URLSessionNetworkService: NetworkService, @unchecked Sendable {

    // MARK: - Properties

    /// The underlying URLSession used to perform network requests.
    private let session: URLSession

    /// The configuration wrapper for encoding strategies and caching policy.
    private let configuration: URLSessionConfigurationWrapper

    // MARK: - Initialization

    /// Initializes a new instance of `URLSessionNetworkService`.
    ///
    /// - Parameters:
    ///   - configuration: A wrapper containing encoding strategies and caching policy.
    ///   - networkMonitor: A network monitor used to detect connectivity changes.
    public init(
        configuration: URLSessionConfigurationWrapper = .init()
    ) {
        self.session = URLSession(configuration: .default)
        self.configuration = configuration
    }

    // MARK: - Asynchronous Request

    /// Sends an HTTP request using URLSession and returns a wrapped `HTTPResponse`.
    ///
    /// If offline and caching is enabled, returns cached data if available
    /// and stores the request for automatic retry.
    ///
    /// - Parameters:
    ///   - request: The HTTP request definition.
    ///   - parameters: Optional request parameters.
    ///   - method: The HTTP method (e.g., `.get`, `.post`).
    ///
    /// - Returns: An `HTTPResponse<Data>` representing the result.
    public func send(
        _ request: HTTPRequest,
        parameters: [String: any Any & Sendable]?,
        method: HTTPMethod
    ) async throws -> HTTPResponse<Data> {

        // Perform online request
        var urlRequest = try request.asURLRequest(for: method)
        let encoder: ParameterEncoder = switch method {
            case .get, .delete, .head: configuration.urlEncoding
            case .post, .put, .patch: configuration.jsonEncoding
            default: configuration.urlEncoding
        }
        
        if let parameters {
            try encoder.encode(&urlRequest, with: parameters)
        }

        NetworkLogger.shared.log(urlRequest)

        let (data, response) = try await session.data(for: urlRequest)

        let result = HTTPResponse(
            request: urlRequest,
            response: response as? HTTPURLResponse,
            data: data,
            rawData: data,
            error: nil
        )

        return result
    }
    
    /// Sends a raw URLRequest directly.
    ///
    /// - Parameter request: The native `URLRequest` to execute.
    /// - Returns: An `HTTPResponse` object containing the raw `Data`.
    public func send(_ request: URLRequest) async throws -> HTTPResponse<Data> {
        
        NetworkLogger.shared.log(request)

        let (data, response) = try await session.data(for: request)

        return HTTPResponse(
            request: request,
            response: response as? HTTPURLResponse,
            data: data,
            rawData: data,
            error: nil
        )
    }
    
    // MARK: - Helper Methods
    
    /// Creates a `URLRequest` from the given parameters without sending it.
    public func createURLRequest(
        _ request: HTTPRequest,
        parameters: [String: any Any & Sendable]?,
        method: HTTPMethod
    ) throws -> URLRequest {
        
        var urlRequest = try request.asURLRequest(for: method)
        
        let encoder: ParameterEncoder = switch method {
            case .get, .delete, .head: configuration.urlEncoding
            case .post, .put, .patch: configuration.jsonEncoding
            default: configuration.urlEncoding
        }
        
        if let parameters {
            try encoder.encode(&urlRequest, with: parameters)
        }
        
        return urlRequest
    }

}
