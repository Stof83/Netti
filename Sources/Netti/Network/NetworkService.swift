//
//  NetworkService.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation

/// A protocol that defines the required operations for performing network requests.
///
/// This protocol provides the foundation for interacting with an underlying network service,
/// such as Alamofire, to send, upload, and download data. Each method can be customized for specific
/// use cases, like sending a standard GET request, uploading data, or downloading raw files.
///
/// Implementers of this protocol should provide network functionality using appropriate HTTP methods
/// and encoding strategies.
public protocol NetworkService: AnyObject {
    /// Sends a network request with optional parameters and returns the raw response data.
    ///
    /// This method is used to perform standard HTTP requests with optional parameters (e.g., query parameters,
    /// body data), and returns the raw response data as a `Data` type.
    ///
    /// - Parameters:
    ///   - request: The HTTP request configuration containing details like the URL and headers.
    ///   - parameters: An instance of a struct that conforms to `Encodable` and `Sendable`, to include in the request body or query.
    ///   - method: The HTTP method to use (e.g., GET, POST, PUT, etc.).
    /// - Returns: A `Data` object containing the raw response data.
    /// - Throws: An `HTTPError` if the request fails, or if encoding or decoding fails.
    ///
    /// Example:
    /// ```swift
    /// struct MyRequestParams: Encodable {
    ///     let key: String
    /// }
    /// let response = try await networkService.send(request, parameters: MyRequestParams(key: "value"), method: .get)
    /// ```
    func send(
        _ request: HTTPRequest,
        parameters: [String: any Any & Sendable]?,
        method: HTTPMethod,
    ) async throws -> HTTPResponse<Data>

}
