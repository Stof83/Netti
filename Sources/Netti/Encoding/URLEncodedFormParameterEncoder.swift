//
//  URLEncodedFormParameterEncoder.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation

/// Writes `Encodable` parameters into a request as a URL-encoded form, in the query or in the body.
///
/// Query items already present in the URL are kept; the new ones are appended after them.
///
/// ```swift
/// let request = try URLEncodedFormParameterEncoder.default.encode(Page(number: 2), into: urlRequest)
/// ```
public struct URLEncodedFormParameterEncoder: Sendable {

    /// Where the encoded form is written.
    public enum Destination: Sendable {
        /// The method's ``HTTPMethod/defaultParameterDestination``: query for `GET`, `HEAD` and `DELETE`, body otherwise.
        case methodDependent
        /// Always the URL query.
        case queryString
        /// Always the HTTP body, with `Content-Type: application/x-www-form-urlencoded; charset=utf-8` unless one is set.
        case httpBody
    }

    /// An encoder with default strategies and a method-dependent destination.
    public static let `default` = URLEncodedFormParameterEncoder()

    /// Where the encoded form is written.
    public let destination: Destination

    /// The form encoder.
    public let encoder: URLEncodedFormEncoder

    /// Creates a parameter encoder.
    ///
    /// - Parameters:
    ///   - encoder: The form encoder. Defaults to `URLEncodedFormEncoder()`.
    ///   - destination: Where the form is written. Defaults to `.methodDependent`.
    public init(
        encoder: URLEncodedFormEncoder = URLEncodedFormEncoder(),
        destination: Destination = .methodDependent
    ) {
        self.encoder = encoder
        self.destination = destination
    }

    /// Returns `request` with `parameters` encoded into it; `nil` parameters leave it unchanged.
    ///
    /// - Parameters:
    ///   - parameters: The parameters to encode.
    ///   - request: The request to encode into.
    /// - Throws: ``HTTPRequestError/invalidURL`` when the request has no valid URL,
    ///   ``HTTPRequestError/encodingFailed(_:)`` when `parameters` cannot be encoded.
    /// - Returns: The encoded request.
    public func encode<Parameters: Encodable & Sendable>(
        _ parameters: Parameters?,
        into request: URLRequest
    ) throws(HTTPRequestError) -> URLRequest {
        guard let parameters else {
            return request
        }
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw .invalidURL
        }

        let query: String
        do {
            query = try encoder.encode(parameters)
        } catch {
            throw .encodingFailed(error)
        }

        var encodedRequest = request
        switch resolvedDestination(for: request) {
            case .queryString:
                guard query.isNotEmpty else {
                    return request
                }
                components.percentEncodedQuery = [components.percentEncodedQuery, query]
                    .compactMap { $0 }
                    .filter(\.isNotEmpty)
                    .joined(separator: "&")
                guard let encodedURL = components.url else {
                    throw .invalidURL
                }
                encodedRequest.url = encodedURL
            case .httpBody:
                encodedRequest.headers.contentType = request.headers.contentType ?? HTTPHeader.formURLEncodedContentType.value
                encodedRequest.httpBody = Data(query.utf8)
        }
        return encodedRequest
    }

    private func resolvedDestination(for request: URLRequest) -> ParameterDestination {
        switch destination {
            case .methodDependent:
                let method = request.httpMethod.flatMap(HTTPMethod.init(rawValue:)) ?? .get
                return method.defaultParameterDestination
            case .queryString:
                return .queryString
            case .httpBody:
                return .httpBody
        }
    }
}
