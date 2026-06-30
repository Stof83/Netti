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
    private let cacheStore: HTTPCacheStore
    private let networkMonitor = NetworkMonitor.shared
    
    private let logger = Logger(subsystem: "Netti", category: "network")
    
    /// Initializes a new `Netti` instance.
    ///
    /// - Parameters:
    ///   - service: A `NetworkService` instance responsible for executing low-level HTTP requests.
    ///   - jsonManager: An optional `JSONManager` used for encoding parameters and decoding responses.
    ///
    public init(
        service: NetworkService = AFNetworkService(),
        jsonManager: JSONManager = .init()
    ) {
        self.service = service
        self.jsonManager = jsonManager
        self.cacheStore = .init(diskCache: DiskCache())
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
            let urlRequest = try? request.asURLRequest(for: method)
            
            if let sampleData = request.sampleData {
                return try await decode(sampleData, request: urlRequest)
            }
           
            let cacheKey = request.cacheKey(for: method)
           
            if networkMonitor.isDisconnected {
                if request.cachePolicy == .cache, let cachedData = try await cacheStore.read(key: cacheKey) {
                    return try await decode(cachedData, request: urlRequest)
                }
            }
           
            let encodedParameters = jsonManager.encoder.toDictionary(parameters)
            let response: HTTPResponse<Data> = try await service.send(request, parameters: encodedParameters, method: method)
           
            NetworkLogger.shared.log(response)
           
            guard let data = response.data else {
                return HTTPResponse<Response>(
                    request: response.request,
                    response: response.response,
                    data: nil,
                    rawData: nil,
                    error: response.error
                )
            }
           
            if request.cachePolicy == .cache {
                Task.detached(priority: .background) {
                    try? await self.cacheStore.write(data, key: cacheKey)
                }
            }
           
            do {
                let decodedData = try jsonManager.decode(Response.self, from: data)
              
                return HTTPResponse<Response>(
                    request: response.request,
                    response: response.response,
                    data: decodedData,
                    rawData: response.rawData,
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
    
    /// Sends a raw URLRequest and returns a decoded response.
    /// Note: This bypasses Netti's internal Caching and SampleData logic typically tied to HTTPRequest objects.
    ///
    /// - Parameters:
    ///   - urlRequest: The native `URLRequest` to execute.
    /// - Returns: A `HTTPResponse<Response>` object containing the decoded response.
    open func send<Response: Decodable>(
        _ urlRequest: URLRequest
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        do {
            
            let response: HTTPResponse<Data> = try await service.send(urlRequest)
            
            NetworkLogger.shared.log(response)
            
            guard let data = response.data else {
                return HTTPResponse<Response>(
                    request: response.request,
                    response: response.response,
                    data: nil,
                    rawData: nil,
                    error: response.error
                )
            }
            
            do {
                let decodedData = try jsonManager.decode(Response.self, from: data)
                
                return HTTPResponse<Response>(
                    request: response.request,
                    response: response.response,
                    data: decodedData,
                    rawData: response.rawData,
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
    
    /// Constructs a URLRequest without sending it.
    open func buildRequest<Parameters: Encodable & Sendable>(
        _ request: HTTPRequest,
        parameters: Parameters? = Empty?.none,
        method: HTTPMethod
    ) throws -> URLRequest {
        let encodedParameters = jsonManager.encoder.toDictionary(parameters)
        return try service.createURLRequest(request, parameters: encodedParameters, method: method)
    }

    /// Decodes raw `Data` into a strongly typed `HTTPResponse`.
    ///
    /// This method is intended for decoding non-network payloads such as
    /// sample JSON, fixtures, or cached responses where no real HTTP exchange
    /// occurred. Because no network request is performed, the returned
    /// `HTTPResponse` contains the provided `URLRequest` (if any) and a
    /// synthesized `HTTPURLResponse` with a `200` status code to represent
    /// a successful decoding outcome.
    ///
    /// - Parameters:
    ///   - data: The raw JSON data to decode.
    ///   - request: The originating `URLRequest`, if available.
    ///
    /// - Returns: An `HTTPResponse<Response>` containing the decoded model,
    ///   the original raw data, the provided request, and a synthesized
    ///   successful HTTP response.
    ///
    /// - Throws: `HTTPRequestError.decodingFailed` if the data cannot be decoded
    ///   into the expected response type.
    public func decode<Response: Decodable>(
        _ data: Data,
        request: URLRequest?
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        do {
            let decoded = try jsonManager.decode(Response.self, from: data)

            let response = HTTPURLResponse(
                url: request?.url ?? URL(string: "about:blank")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )

            return HTTPResponse<Response>(
                request: request,
                response: response,
                data: decoded,
                rawData: data,
                error: nil
            )
        } catch {
            throw .decodingFailed(error)
        }
    }

    /// Removes all cached HTTP responses from both memory and disk.
    ///
    /// Call this when stale cached data must be discarded unconditionally — for
    /// example, on logout or after a server-side schema change that invalidates
    /// all previously cached responses.
    ///
    /// - Throws: An error if the underlying disk cache cannot be cleared.
    public func clearCache() async throws {
        try await cacheStore.clearAll()
    }

    /// Removes the cached HTTP response for a specific request.
    ///
    /// Use this to invalidate a single endpoint's cached response — for example,
    /// after a mutation that makes a previously cached GET response stale.
    ///
    /// If no cached entry exists for the request, this method returns without error.
    ///
    /// - Parameters:
    ///   - request: The `HTTPRequest` whose cached entry should be removed.
    ///   - method: The HTTP method used when the response was originally cached.
    ///             Must match the method used during the original `send` call.
    ///
    /// - Throws: An error if the underlying disk cache removal fails.
    public func clearCache(for request: HTTPRequest, method: HTTPMethod) async throws {
        let key = request.cacheKey(for: method)
        try await cacheStore.remove(key: key)
    }

    /// Returns the cached, decoded response for a request without performing any
    /// network call.
    ///
    /// Use this to render a previously cached response immediately — for example,
    /// before a silent network refresh in a cache-first flow. Unlike the offline
    /// fallback inside ``send(_:parameters:method:)``, this reads the cache
    /// regardless of connectivity.
    ///
    /// Returns `nil` when the request did not opt into caching
    /// (`cachePolicy == .none`), when no cached entry exists, or when the cached
    /// data cannot be decoded into `Response` (for example, after a schema change
    /// since it was written). In every "miss" case the caller should fall through
    /// to ``send(_:parameters:method:)``.
    ///
    /// - Parameters:
    ///   - request: The `HTTPRequest` whose cached response should be read.
    ///   - method: The HTTP method used to compute the cache key. Must match the
    ///     method originally used when the response was cached.
    ///
    /// - Returns: A decoded `HTTPResponse<Response>` carrying a synthesized `200`
    ///   response, or `nil` on any cache miss.
    open func cachedResponse<Response: Decodable>(
        for request: HTTPRequest,
        method: HTTPMethod
    ) async -> HTTPResponse<Response>? {
        guard request.cachePolicy == .cache else { return nil }

        let cacheKey = request.cacheKey(for: method)

        guard let cachedData = try? await cacheStore.read(key: cacheKey) else {
            return nil
        }

        let urlRequest = try? request.asURLRequest(for: method)

        return try? await decode(cachedData, request: urlRequest)
    }
}
