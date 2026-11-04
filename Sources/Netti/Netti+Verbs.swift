//
//  Netti+Verbs.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation

/// One method per HTTP verb.
///
/// `GET`, `HEAD` and `DELETE` encode their `query` into the URL; `POST`, `PUT` and `PATCH` encode
/// their `body` as JSON. Each method has an overload returning `HTTPResponse<Empty>` for requests
/// whose body does not matter:
///
/// ```swift
/// let user: User? = try await netti.get(UserAPI.user(id)).data
/// let page: [User]? = try await netti.get(UserAPI.users, query: Page(number: 2)).data
/// try await netti.post(UserAPI.users, body: NewUser(name: "Ada"))
/// ```
///
/// Non-2xx responses are returned with their status code unless validation is on; see
/// ``ResponseValidation``.
///
/// The generic variants are disfavored so that a call without a response type resolves to the
/// `Empty` overload instead of being ambiguous.
extension Netti {

    // MARK: - GET

    /// Sends a `GET` request.
    ///
    /// ```swift
    /// let user: User? = try await netti.get(UserAPI.user(id)).data
    /// let page: [User]? = try await netti.get(UserAPI.users, query: Page(number: 2)).data
    /// ```
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - query: Encoded into the URL query, after any query items the URL already has, with keys
    ///     following the client's ``JSONManager`` key strategy. Optional.
    ///   - progress: Called as the response body arrives, on a background queue, in order, with
    ///     increasing values and a fraction of `1.0` when the request succeeds. A request with a
    ///     handler does not share its transfer with identical in-flight requests. Optional.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError``.
    @_disfavoredOverload
    public func get<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        query: (some Encodable & Sendable)? = Empty?.none,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        try await send(endpoint, method: .get, parameters: query, progress: progress)
    }

    /// Sends a `GET` request and ignores the response body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - query: Encoded into the URL query, with keys following the client's ``JSONManager`` key strategy. Optional.
    ///   - progress: Called as the response body arrives, on a background queue, in order, with
    ///     increasing values and a fraction of `1.0` when the request succeeds. A request with a
    ///     handler does not share its transfer with identical in-flight requests. Optional.
    /// - Returns: The response, with an ``Empty`` body; read its status and headers.
    /// - Throws: ``HTTPRequestError``.
    @discardableResult
    public func get(
        _ endpoint: some HTTPRequest,
        query: (some Encodable & Sendable)? = Empty?.none,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        try await send(endpoint, method: .get, parameters: query, progress: progress)
    }

    // MARK: - HEAD

    /// Sends a `HEAD` request.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - query: Encoded into the URL query, with keys following the client's ``JSONManager`` key strategy. Optional.
    /// - Returns: The response; read its status and headers.
    /// - Throws: ``HTTPRequestError``.
    @discardableResult
    public func head(
        _ endpoint: some HTTPRequest,
        query: (some Encodable & Sendable)? = Empty?.none
    ) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        try await send(endpoint, method: .head, parameters: query)
    }

    // MARK: - DELETE

    /// Sends a `DELETE` request.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - query: Encoded into the URL query, with keys following the client's ``JSONManager`` key strategy. Optional.
    ///   - progress: Called as the response body arrives, on a background queue, in order, with
    ///     increasing values and a fraction of `1.0` when the request succeeds. A request with a
    ///     handler does not share its transfer with identical in-flight requests. Optional.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError``.
    @_disfavoredOverload
    public func delete<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        query: (some Encodable & Sendable)? = Empty?.none,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        try await send(endpoint, method: .delete, parameters: query, progress: progress)
    }

    /// Sends a `DELETE` request and ignores the response body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - query: Encoded into the URL query, with keys following the client's ``JSONManager`` key strategy. Optional.
    ///   - progress: Called as the response body arrives, on a background queue, in order, with
    ///     increasing values and a fraction of `1.0` when the request succeeds. A request with a
    ///     handler does not share its transfer with identical in-flight requests. Optional.
    /// - Returns: The response, with an ``Empty`` body; read its status and headers.
    /// - Throws: ``HTTPRequestError``.
    @discardableResult
    public func delete(
        _ endpoint: some HTTPRequest,
        query: (some Encodable & Sendable)? = Empty?.none,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        try await send(endpoint, method: .delete, parameters: query, progress: progress)
    }

    // MARK: - OPTIONS

    /// Sends an `OPTIONS` request.
    ///
    /// - Parameter endpoint: The endpoint.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError``.
    @_disfavoredOverload
    public func options<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        try await send(endpoint, method: .options, parameters: Empty?.none)
    }

    /// Sends an `OPTIONS` request and ignores the response body.
    ///
    /// - Parameter endpoint: The endpoint.
    /// - Returns: The response, with an ``Empty`` body; read its status and headers, such as `Allow`.
    /// - Throws: ``HTTPRequestError``.
    @discardableResult
    public func options(_ endpoint: some HTTPRequest) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        try await send(endpoint, method: .options, parameters: Empty?.none)
    }

    // MARK: - POST

    /// Sends a `POST` request.
    ///
    /// ```swift
    /// let created: User? = try await netti.post(UserAPI.users, body: NewUser(name: "Ada")).data
    /// ```
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - body: Encoded as the JSON body; top-level arrays work. Optional.
    ///   - progress: Called as the response body arrives, on a background queue, in order, with
    ///     increasing values and a fraction of `1.0` when the request succeeds. A request with a
    ///     handler does not share its transfer with identical in-flight requests. Optional.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError``.
    @_disfavoredOverload
    public func post<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        body: (some Encodable & Sendable)? = Empty?.none,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        try await send(endpoint, method: .post, parameters: body, progress: progress)
    }

    /// Sends a `POST` request and ignores the response body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - body: Encoded as the JSON body. Optional.
    ///   - progress: Called as the response body arrives, on a background queue, in order, with
    ///     increasing values and a fraction of `1.0` when the request succeeds. A request with a
    ///     handler does not share its transfer with identical in-flight requests. Optional.
    /// - Returns: The response, with an ``Empty`` body; read its status and headers.
    /// - Throws: ``HTTPRequestError``.
    @discardableResult
    public func post(
        _ endpoint: some HTTPRequest,
        body: (some Encodable & Sendable)? = Empty?.none,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        try await send(endpoint, method: .post, parameters: body, progress: progress)
    }

    // MARK: - PUT

    /// Sends a `PUT` request.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - body: Encoded as the JSON body. Optional.
    ///   - progress: Called as the response body arrives, on a background queue, in order, with
    ///     increasing values and a fraction of `1.0` when the request succeeds. A request with a
    ///     handler does not share its transfer with identical in-flight requests. Optional.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError``.
    @_disfavoredOverload
    public func put<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        body: (some Encodable & Sendable)? = Empty?.none,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        try await send(endpoint, method: .put, parameters: body, progress: progress)
    }

    /// Sends a `PUT` request and ignores the response body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - body: Encoded as the JSON body. Optional.
    ///   - progress: Called as the response body arrives, on a background queue, in order, with
    ///     increasing values and a fraction of `1.0` when the request succeeds. A request with a
    ///     handler does not share its transfer with identical in-flight requests. Optional.
    /// - Returns: The response, with an ``Empty`` body; read its status and headers.
    /// - Throws: ``HTTPRequestError``.
    @discardableResult
    public func put(
        _ endpoint: some HTTPRequest,
        body: (some Encodable & Sendable)? = Empty?.none,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        try await send(endpoint, method: .put, parameters: body, progress: progress)
    }

    // MARK: - PATCH

    /// Sends a `PATCH` request.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - body: Encoded as the JSON body. Optional.
    ///   - progress: Called as the response body arrives, on a background queue, in order, with
    ///     increasing values and a fraction of `1.0` when the request succeeds. A request with a
    ///     handler does not share its transfer with identical in-flight requests. Optional.
    /// - Returns: The decoded response.
    /// - Throws: ``HTTPRequestError``.
    @_disfavoredOverload
    public func patch<Response: Decodable & Sendable>(
        _ endpoint: some HTTPRequest,
        body: (some Encodable & Sendable)? = Empty?.none,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Response> {
        try await send(endpoint, method: .patch, parameters: body, progress: progress)
    }

    /// Sends a `PATCH` request and ignores the response body.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint.
    ///   - body: Encoded as the JSON body. Optional.
    ///   - progress: Called as the response body arrives, on a background queue, in order, with
    ///     increasing values and a fraction of `1.0` when the request succeeds. A request with a
    ///     handler does not share its transfer with identical in-flight requests. Optional.
    /// - Returns: The response, with an ``Empty`` body; read its status and headers.
    /// - Throws: ``HTTPRequestError``.
    @discardableResult
    public func patch(
        _ endpoint: some HTTPRequest,
        body: (some Encodable & Sendable)? = Empty?.none,
        progress: ProgressHandler? = nil
    ) async throws(HTTPRequestError) -> HTTPResponse<Empty> {
        try await send(endpoint, method: .patch, parameters: body, progress: progress)
    }
}
