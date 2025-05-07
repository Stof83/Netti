//
//  Netti.swift
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation
import os

/// A high-level wrapper around a `NetworkService` for making API requests and decoding responses.
///
/// `Netti` provides an abstraction over raw network logic, allowing for structured parameter encoding,
/// flexible decoding, sample data mocking, and full testability. It supports injecting custom
/// services and JSON coders, making it ideal for use in modular architecture or large-scale apps.
open class Netti: @unchecked Sendable {
    private let service: NetworkService
    private let jsonManager: JSONManager
    
    private let logger = Logger(subsystem: "Netti", category: "network")
    
    /// Initializes a new `Netti` instance.
    ///
    /// - Parameters:
    ///   - service: A `NetworkService` instance responsible for executing low-level HTTP requests.
    ///   - jsonManager: An optional `JSONManager` used for encoding parameters and decoding responses.
    ///                  Defaults to a standard implementation.
    public init(
        service: NetworkService = AFNetworkService(),
        jsonManager: JSONManager = .init()
    ) {
        self.service = service
        self.jsonManager = jsonManager
    }

    /// Sends a network request with optional parameters and returns a decoded typed response.
    ///
    /// This method is generic over both the request's parameter type and the expected response type.
    /// If the request defines `sampleData`, it will be used instead of making a real network call.
    ///
    /// - Parameters:
    ///   - request: The `HTTPRequest` representing the endpoint and configuration.
    ///   - parameters: Optional request body parameters conforming to `Encodable`.
    ///   - method: The HTTP method to use, such as `.get` or `.post`.
    ///
    /// - Returns: A `HTTPResponse<Response>` object containing the decoded response, metadata,
    ///            and the original request/response.
    ///
    /// - Throws: `NetworkError.decoding` if decoding fails, `NetworkError.transport` for other issues.
    open func send<Parameters: Encodable & Sendable, Response: Decodable>(
        _ request: HTTPRequest,
        parameters: Parameters? = Empty?.none,
        method: HTTPMethod
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        do {
            if let sampleData = request.sampleData {
                return try await decode(sampleData)
            }
            
            let encodedParameters = jsonManager.encoder.toDictionary(parameters)
            let response: HTTPResponse<Data> = try await service.send(request, parameters: encodedParameters, method: method)
            
            NetworkLogger.shared.log(response)
            
            guard let data = response.data else {
                return HTTPResponse<Response>(
                    request: response.request,
                    response: response.response,
                    data: nil,
                    error: response.error
                )
            }
            
            do {
                let decodedData = try jsonManager.decode(Response.self, from: data)
                
                return HTTPResponse<Response>(
                    request: response.request,
                    response: response.response,
                    data: decodedData,
                    error: response.error
                )
            } catch let error as DecodingError {
                NetworkLogger.shared.log(error, type: Response.self, data: data)
                throw HTTPRequestError.decodingFailed(error)
            }
        } catch {
            throw .requestFailed(error)
        }
    }

    /// Decodes raw `Data` into a strongly typed `HTTPResponse`.
    ///
    /// This is useful for decoding sample data or cached responses without hitting the network.
    ///
    /// - Parameter data: The raw JSON data to decode.
    /// - Returns: A `HTTPResponse<Response>` containing the decoded model.
    ///
    /// - Throws: A `DecodingError` if the data does not match the expected response type.
    public func decode<Response: Decodable>(_ data: Data) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        do {
            let decoded = try jsonManager.decode(Response.self, from: data)
            return HTTPResponse<Response>(request: nil, response: nil, data: decoded, error: nil)
        } catch {
            throw .decodingFailed(error)
        }
    }
}
