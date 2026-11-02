//
//  RequestAdapter.swift
//  Netti
//

import Foundation

/// Modifies a request just before it is sent.
///
/// Adapters run in registration order, once per attempt, so a retried request is adapted again
/// and picks up a refreshed credential. An adapter that throws stops the request before any
/// network traffic.
///
/// ```swift
/// struct AppVersionAdapter: RequestAdapter {
///     func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
///         var request = urlRequest
///         request.setValue("5.0", forHTTPHeaderField: "X-App-Version")
///         return request
///     }
/// }
/// ```
public protocol RequestAdapter: Sendable {
    /// Returns the request to send in place of `urlRequest`.
    ///
    /// - Parameter urlRequest: The request about to be sent.
    /// - Returns: The adapted request.
    /// - Throws: Any error. The call then fails with it as an ``HTTPRequestError``: one passes
    ///   through, a `URLError` becomes ``HTTPRequestError/requestFailed(_:)``, a cancellation becomes
    ///   ``HTTPRequestError/cancelled``, and any other error is wrapped in `requestFailed`.
    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest
}
