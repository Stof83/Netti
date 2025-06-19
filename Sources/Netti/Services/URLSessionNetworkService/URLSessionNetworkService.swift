//
//  URLSessionNetworkService.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 05/05/25.
//

import Foundation

public final class URLSessionNetworkService: NetworkService, @unchecked Sendable {
    // MARK: - Properties

    /// The underlying URLSession used to perform network requests.
    private let session: URLSession

    /// The configuration object wrapper.
    private let configuration: URLSessionConfigurationWrapper

    // MARK: - Initialization

    /// Initializes a new instance of `URLSessionNetworkService`.
    ///
    /// - Parameter configuration: A wrapper containing encoding strategies and caching policy.
    public init(configuration: URLSessionConfigurationWrapper = .init()) {
        self.session = URLSession(configuration: .default)
        self.configuration = configuration
    }

    // MARK: - Asynchronous Request

    /// Sends an HTTP request using `URLSession` and returns a wrapped `HTTPResponse`.
    ///
    /// - Parameters:
    ///   - request: The HTTP request definition (URL, headers, etc.).
    ///   - parameters: A dictionary of parameters to include in the request body or query string.
    ///   - method: The HTTP method (e.g., `.get`, `.post`, `.put`).
    ///
    /// - Returns: An `HTTPResponse<Data>` with the raw response data.
    ///
    /// - Throws: An error for encoding, network, or response validation issues.
    public func send(
        _ request: HTTPRequest,
        parameters: [String: any Any & Sendable]?,
        method: HTTPMethod
    ) async throws -> HTTPResponse<Data> {
        var urlRequest = try request.asURLRequest(for: method)

        try configuration.urlEncoding.encode(&urlRequest, with: parameters)

        NetworkLogger.shared.log(urlRequest)
        
        let (data, response) = try await session.data(for: urlRequest)

        return HTTPResponse(
            request: urlRequest,
            response: response as? HTTPURLResponse,
            data: data,
            rawData: data,
            error: nil
        )
    }
}
