//
//  HTTPResponse.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//


import Combine
import Foundation

/// Type used to store all values associated with a serialized response of a `DataRequest` or `UploadRequest`.
public struct HTTPResponse<T>: Sendable where T: Sendable & Decodable {
    /// The URL request sent to the server.
    public let request: URLRequest?

    /// The server's response to the URL request.
    public let response: HTTPURLResponse?

    /// The data returned by the server.
    public let data: T?
    
    /// The data returned by the server.
    public let rawData: Data?
    
    /// The error returned by the server.
    public let error: Error?

}

extension HTTPResponse where T == Data {
    /// Creates a cached response wrapping raw data.
    ///
    /// - Parameter data: The cached data.
    /// - Returns: An `HTTPResponse<Data>` representing the cached result.
    public static func cached(data: Data) -> HTTPResponse<Data> {
        HTTPResponse(
            request: nil,
            response: nil,
            data: data,
            rawData: data,
            error: nil
        )
    }
}


// MARK: - DownloadResponse
/// Used to store all data associated with a serialized response of a download request.
public struct HTTPDownloadResponse<T>: Sendable where T: Sendable & Decodable {
    /// The URL request sent to the server.
    public let request: URLRequest?

    /// The server's response to the URL request.
    public let response: HTTPURLResponse?

    /// The final destination URL of the data returned from the server after it is moved.
    public let fileURL: URL?

    /// The resume data generated if the request was cancelled.
    public let resumeData: Data?
    
    /// The data returned by the server.
    public let error: Error?

}

// MARK: - Empty
/// Protocol representing an empty response. Use `T.emptyValue()` to get an instance.
public protocol EmptyResponse: Sendable {
    /// Empty value for the conforming type.
    ///
    /// - Returns: Value of `Self` to use for empty values.
    static func emptyValue() -> Self
}

/// Type representing an empty value. Use `Empty.value` to get the static instance.
public struct Empty: Codable, Sendable {
    /// Static `Empty` instance used for all `Empty` responses.
    public static let value = Empty()
}

extension Empty: EmptyResponse {
    public static func emptyValue() -> Empty {
        value
    }
}
