//
//  HTTPStreamResponse.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation

/// A response whose body is consumed as it arrives.
///
/// Returned by ``Netti/stream(_:query:)`` and ``NetworkService/bytes(for:)``. Read the body once,
/// through one of ``body``, ``lines`` or ``serverSentEvents``.
///
/// ```swift
/// let stream = try await netti.stream(LogAPI.tail)
/// for try await chunk in stream.body { … }
/// ```
///
/// The body ends when the response ends and throws ``HTTPRequestError`` on a transport failure.
/// Cancelling the consuming task cancels the transfer, and so does releasing the response after
/// breaking out of the loop early.
public struct HTTPStreamResponse: Sendable {

    // MARK: - Properties

    /// The request that was sent.
    public let request: URLRequest

    /// The response headers and status.
    public let response: HTTPURLResponse?

    /// The body, as chunks of data in arrival order.
    public let body: AsyncThrowingStream<Data, any Error>

    /// The HTTP status code, or `nil` when no HTTP response was received.
    public var statusCode: Int? {
        response?.statusCode
    }

    // MARK: - Initialization

    /// Creates a stream response.
    ///
    /// - Parameters:
    ///   - request: The request that was sent.
    ///   - response: The response headers and status.
    ///   - body: The body chunks.
    public init(request: URLRequest, response: HTTPURLResponse?, body: AsyncThrowingStream<Data, any Error>) {
        self.request = request
        self.response = response
        self.body = body
    }
}
