//
//  JSONParameterEncoder.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation

/// Writes an `Encodable` body into a request as JSON.
///
/// The value goes straight from `Encodable` to `Data`, so top-level arrays work and `Decimal`
/// values keep their exact digits. `Content-Type: application/json` is set unless the request already has one.
///
/// ```swift
/// let request = try JSONParameterEncoder.default.encode([Item(id: 1), Item(id: 2)], into: urlRequest)
/// ```
public struct JSONParameterEncoder: Sendable {

    /// An encoder using a default `JSONEncoder`.
    public static let `default` = JSONParameterEncoder()

    /// The JSON encoder, carrying the key and date strategies.
    public let encoder: JSONEncoder

    /// Creates a parameter encoder.
    ///
    /// - Parameter encoder: The JSON encoder. Defaults to `JSONEncoder()`.
    public init(encoder: JSONEncoder = JSONEncoder()) {
        self.encoder = encoder
    }

    /// Returns `request` with `parameters` encoded as its JSON body; `nil` parameters leave it unchanged.
    ///
    /// - Parameters:
    ///   - parameters: The body to encode.
    ///   - request: The request to encode into.
    /// - Throws: ``HTTPRequestError/encodingFailed(_:)`` when `parameters` cannot be encoded.
    /// - Returns: The encoded request.
    public func encode<Parameters: Encodable & Sendable>(
        _ parameters: Parameters?,
        into request: URLRequest
    ) throws(HTTPRequestError) -> URLRequest {
        guard let parameters else {
            return request
        }

        var encodedRequest = request
        do {
            encodedRequest.httpBody = try encoder.encode(parameters)
        } catch {
            throw .encodingFailed(error)
        }
        encodedRequest.headers.contentType = request.headers.contentType ?? HTTPHeader.jsonContentType.value
        return encodedRequest
    }
}
