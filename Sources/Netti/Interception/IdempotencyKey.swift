//
//  IdempotencyKey.swift
//  Netti
//

import Foundation

/// Sets an `Idempotency-Key` header with a fresh UUID on every `POST` and `PATCH` that has none.
///
/// The server uses the key to recognise a repeated request and apply it once. Every retry of one
/// call carries the same key, so ``RetryPolicy`` retries a keyed `POST` or `PATCH` like an
/// idempotent request. A key the caller set is kept.
///
/// ```swift
/// netti.interceptors.append(.idempotencyKey)
/// ```
public struct IdempotencyKeyAdapter: RequestInterceptor {
    /// The header the key is sent in.
    public static let headerName = "Idempotency-Key"

    private static let keyedMethods: Set<String> = [HTTPMethod.post.rawValue, HTTPMethod.patch.rawValue]

    /// Creates the adapter.
    public init() {}

    /// Asynchronously adds a new key to a `POST` or `PATCH` without one.
    ///
    /// - Parameter urlRequest: The request about to be sent.
    /// - Returns: The request carrying an `Idempotency-Key`, or unchanged for other methods.
    /// - Throws: Never; the signature matches ``RequestAdapter/adapt(_:)``.
    public func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        guard Self.keyedMethods.contains(urlRequest.httpMethod ?? HTTPMethod.get.rawValue),
              urlRequest.value(forHTTPHeaderField: Self.headerName) == nil
        else {
            return urlRequest
        }
        var request = urlRequest
        request.setValue(UUID().uuidString, forHTTPHeaderField: Self.headerName)
        return request
    }
}

extension RequestInterceptor where Self == IdempotencyKeyAdapter {
    /// An adapter that sets an `Idempotency-Key` UUID on every `POST` and `PATCH` without one.
    public static var idempotencyKey: IdempotencyKeyAdapter {
        IdempotencyKeyAdapter()
    }
}
