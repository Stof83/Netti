//
//  HTTPResponse.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//


import Combine
import Foundation

/// Type used to store all values associated with a serialized response of a data or upload request.
///
/// Every ``Netti`` verb returns one. A non-2xx response is returned, not thrown, unless validation
/// is on, so read ``statusCode`` before ``data``:
///
/// ```swift
/// let response: HTTPResponse<User> = try await netti.get(UserAPI.me)
/// if response.statusCode == 200, let user = response.data {
///     show(user)
/// }
/// ```
public struct HTTPResponse<T>: Sendable where T: Sendable & Decodable {
    /// The URL request sent to the server.
    public let request: URLRequest?

    /// The server's response to the URL request.
    public let response: HTTPURLResponse?

    /// The decoded body; `nil` when there was none or a non-2xx body did not decode.
    public let data: T?
    
    /// The undecoded body returned by the server.
    public let rawData: Data?
    
    /// An error the engine attached to the response, if any.
    public let error: Error?

    /// The task metrics collected for the request, when the transport provides them.
    public let metrics: URLSessionTaskMetrics?

    /// Creates a response.
    ///
    /// - Parameters:
    ///   - request: The URL request sent to the server.
    ///   - response: The server's HTTP response.
    ///   - data: The decoded body.
    ///   - rawData: The undecoded body.
    ///   - error: The transport error, if any.
    ///   - metrics: The task metrics, if collected.
    public init(
        request: URLRequest?,
        response: HTTPURLResponse?,
        data: T?,
        rawData: Data?,
        error: Error? = nil,
        metrics: URLSessionTaskMetrics? = nil
    ) {
        self.request = request
        self.response = response
        self.data = data
        self.rawData = rawData
        self.error = error
        self.metrics = metrics
    }
}

extension HTTPResponse {
    /// The HTTP status code, or `nil` when no HTTP response was received (for example a cached or sample response).
    public var statusCode: Int? {
        response?.statusCode
    }
}

extension HTTPResponse where T == Data {
    /// Decodes the raw body into `Value`, keeping request, response, error and metrics.
    ///
    /// A body that fails to decode throws `decodingFailed` only for a successful (2xx) or
    /// synthesized response; other statuses are returned with `data == nil` and `rawData` intact,
    /// so callers can still read the status code (for example a 401).
    ///
    /// - Parameter jsonManager: The JSON coder used for decoding.
    /// - Returns: The typed response.
    func decoded<Value: Decodable & Sendable>(using jsonManager: JSONManager) throws(HTTPRequestError) -> HTTPResponse<Value> {
        do {
            let value = try jsonManager.decode(Value.self, from: rawData)
            return mapped(to: value)
        } catch {
            let isFailureStatus = statusCode.map { Self.successStatusCodes.contains($0) == false } ?? false
            guard isFailureStatus else {
                throw .decodingFailed(error, response: self)
            }
            return mapped(to: nil)
        }
    }

    private static let successStatusCodes = 200..<300

    func mapped<Value>(to value: Value?) -> HTTPResponse<Value> {
        HTTPResponse<Value>(
            request: request,
            response: response,
            data: value,
            rawData: rawData,
            error: error,
            metrics: metrics
        )
    }

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
///
/// Returned by ``Netti/download(_:to:options:resumeData:progress:)``; ``fileURL`` is where the body
/// was saved.
public struct HTTPDownloadResponse<T>: Sendable where T: Sendable & Decodable {
    /// The URL request sent to the server.
    public let request: URLRequest?

    /// The server's response to the URL request.
    public let response: HTTPURLResponse?

    /// The final destination URL of the data returned from the server after it is moved.
    public let fileURL: URL?

    /// The resume data generated if the request was cancelled.
    public let resumeData: Data?
    
    /// An error the engine attached to the response, if any.
    public let error: Error?

    /// The task metrics collected for the download, when the transport provides them.
    public let metrics: URLSessionTaskMetrics?

    /// The HTTP status code, or `nil` when no HTTP response was received.
    public var statusCode: Int? {
        response?.statusCode
    }

    /// Creates a download response.
    ///
    /// - Parameters:
    ///   - request: The URL request sent to the server.
    ///   - response: The server's HTTP response.
    ///   - fileURL: The final location of the downloaded file.
    ///   - resumeData: Data that resumes a cancelled or failed download.
    ///   - error: The transport error, if any.
    ///   - metrics: The task metrics, if collected.
    public init(
        request: URLRequest?,
        response: HTTPURLResponse?,
        fileURL: URL?,
        resumeData: Data? = nil,
        error: Error? = nil,
        metrics: URLSessionTaskMetrics? = nil
    ) {
        self.request = request
        self.response = response
        self.fileURL = fileURL
        self.resumeData = resumeData
        self.error = error
        self.metrics = metrics
    }
}

// MARK: - Empty
/// Protocol representing an empty response. Use `T.emptyValue()` to get an instance.
///
/// When a request's response type conforms, the body is ignored and `emptyValue()` is returned,
/// so `204 No Content`, `HEAD` and non-JSON acknowledgement bodies all succeed.
public protocol EmptyResponse: Sendable {
    /// Empty value for the conforming type.
    ///
    /// - Returns: Value of `Self` to use for empty values.
    static func emptyValue() -> Self
}

/// Type representing an empty value. Use `Empty.value` to get the static instance.
///
/// The response type of the verb overloads that ignore the body, and the default type of their
/// optional `query` and `body` parameters.
public struct Empty: Codable, Sendable {
    /// Static `Empty` instance used for all `Empty` responses.
    public static let value = Empty()
}

extension Empty: EmptyResponse {
    /// Returns ``Empty/value``.
    ///
    /// - Returns: The shared instance.
    public static func emptyValue() -> Empty {
        value
    }
}
