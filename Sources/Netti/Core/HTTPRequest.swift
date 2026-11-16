//
//  defining.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//


import Foundation

/// A protocol defining the contract for a network request.
///
/// Conform an enum, one case per endpoint, and pass its values to the ``Netti`` verbs. Only
/// ``baseURL``, ``basePath``, ``path`` and ``headers`` are required; every other requirement has
/// a default.
///
/// ```swift
/// enum UserAPI: HTTPRequest {
///     case users
///     case user(Int)
///
///     var baseURL: URL? { URL(string: "https://api.example.com") }
///     var basePath: String { "v1" }
///     var path: String {
///         switch self {
///             case .users: "users"
///             case .user(let id): "users/\(id)"
///         }
///     }
///     var headers: HTTPHeaders { [.accept("application/json")] }
/// }
///
/// let user: User? = try await netti.get(UserAPI.user(42)).data
/// ```
public protocol HTTPRequest: Sendable {
    /// The base URL for the API.
    var baseURL: URL? { get }

    /// The base path version used in the request, such as `v1`; empty for none.
    var basePath: String { get }

    /// The path for the request, relative to the base URL and base path.
    var path: String { get }

    /// The complete URL for the request, constructed from the base URL, API version, and path.
    ///
    /// - Throws: ``HTTPRequestError/invalidURL`` when the URL cannot be built.
    var requestURL: URL { get throws(HTTPRequestError) }

    /// The HTTP headers for the request.
    var headers: HTTPHeaders { get }

    /// The sample data for the mock response (if applicable).
    ///
    /// In a DEBUG build, when the client's ``Netti/usesSampleData`` is `true` and this is set, the
    /// verbs answer with it in place of sending the request. The sample runs through the same
    /// pipeline as a real response, with ``sampleStatusCode`` as its status. Release builds never
    /// serve it, and `nil` always sends the request.
    var sampleData: Data? { get }

    /// The status code of the sample response, `200` by default.
    ///
    /// Switch on the endpoint's case to preview an error state:
    ///
    /// ```swift
    /// var sampleStatusCode: Int { self == .profile ? 404 : 200 }
    /// ```
    ///
    /// Validation, retry and interceptors see it like a real status.
    var sampleStatusCode: Int { get }

    /// The timeout interval for the network request, in seconds.
    var timeoutInterval: TimeInterval { get }

    /// The cache policy associated with the request.
    ///
    /// This value is evaluated by the networking layer to determine
    /// whether and how the response should be cached and reused
    /// when the device is offline.
    var cachePolicy: HTTPCachePolicy { get }

    /// Validation rules for this endpoint's responses.
    ///
    /// `nil` inherits the client's validation. Use ``ResponseValidation/disabled`` to accept every
    /// response even when the client validates.
    var validation: ResponseValidation? { get }

    /// The retry policy for this endpoint.
    ///
    /// `nil` inherits the client's policy. Use ``RetryPolicy/disabled`` to never retry this endpoint.
    var retryPolicy: RetryPolicy? { get }

    /// Whether ``AuthenticationInterceptor`` signs this endpoint and refreshes its credential on a
    /// `401`. `true` by default.
    ///
    /// Return `false` for endpoints that sign in or sign up, and for a refresh endpoint that takes
    /// its refresh token in the body: a `401` from them means bad credentials, not an expired
    /// session. Keep `true` for a refresh endpoint that expects the expired credential in
    /// `Authorization`; a request sent from the interceptor's `refresh` never triggers a refresh. Such a request carries no credential, never waits for
    /// a refresh, and its `401` never refreshes. The endpoint declares it in its own module, so an
    /// app that builds the interceptor needs no list of them, even when the enum is internal to a
    /// feature module.
    ///
    /// ```swift
    /// enum AuthAPI: HTTPRequest {
    ///     case signIn, signUp, profile
    ///     // ...
    ///     var requiresAuthentication: Bool { self == .profile }
    /// }
    /// ```
    ///
    /// A prebuilt `URLRequest` sent with `send(_:)` or `stream(_:)` has no endpoint, so only the
    /// interceptor's `excluding` or `hosts` can keep it unsigned.
    var requiresAuthentication: Bool { get }

    /// Converts the instance into a `URLRequest` with the specified HTTP method.
    ///
    /// - Parameter method: The HTTP method to use for the request.
    /// - Throws: ``HTTPRequestError/invalidURL`` if the URL cannot be built.
    /// - Returns: A configured `URLRequest` instance.
    func asURLRequest(for method: HTTPMethod) throws(HTTPRequestError) -> URLRequest
}

// MARK: - URLRequestConvertible
extension HTTPRequest {
    /// The complete URL for the request, constructed from the base URL, API version, and path.
    ///
    /// - Throws: ``HTTPRequestError/invalidURL`` when `baseURL` is `nil`.
    public var requestURL: URL {
        get throws(HTTPRequestError) {
            guard let baseURL else {
                throw .invalidURL
            }
            return baseURL.appendingPathComponent(basePath).appendingPathComponent(path)
        }
    }

    /// A default implementation returning `nil` for mock sample data.
    public var sampleData: Data? { nil }

    /// A default implementation answering samples with `200`.
    public var sampleStatusCode: Int { 200 }

    /// A default implementation providing a timeout interval of 60 seconds.
    public var timeoutInterval: TimeInterval { 60 }

    /// A default cache policy disabling caching.
    public var cachePolicy: HTTPCachePolicy { .none }

    /// By default the endpoint inherits the client's validation.
    public var validation: ResponseValidation? { nil }

    /// By default the endpoint inherits the client's retry policy.
    public var retryPolicy: RetryPolicy? { nil }

    /// By default the endpoint is signed by ``AuthenticationInterceptor``.
    public var requiresAuthentication: Bool { true }

    /// Converts the instance into a `URLRequest` with the specified HTTP method.
    ///
    /// The request carries ``headers`` and ``timeoutInterval``; no body.
    ///
    /// - Parameter method: The HTTP method to use for the request.
    /// - Throws: ``HTTPRequestError/invalidURL`` if the URL cannot be built;
    ///   ``HTTPRequestError/encodingFailed(_:)`` if a header name is not an RFC 9110 token or a value
    ///   holds a control character other than tab, such as CR, LF or NUL.
    /// - Returns: A configured `URLRequest` instance.
    public func asURLRequest(for method: HTTPMethod) throws(HTTPRequestError) -> URLRequest {
        try headers.validate()
        var urlRequest = URLRequest(url: try requestURL)
        urlRequest.httpMethod = method.rawValue
        urlRequest.allHTTPHeaderFields = headers.dictionary
        urlRequest.timeoutInterval = timeoutInterval

        return urlRequest
    }
}

extension HTTPRequest {
    /// The cache key of this endpoint sent with `method` and no parameters.
    ///
    /// - Parameter method: The HTTP method associated with the request.
    /// - Returns: The same key as ``Foundation/URLRequest/cacheKey`` of the built request.
    func cacheKey(for method: HTTPMethod) throws(HTTPRequestError) -> String {
        try asURLRequest(for: method).cacheKey
    }
}

extension URLRequest {
    /// A deterministic key identifying the semantic request: `SHA-256(method | URL with sorted query | SHA-256(body))`.
    ///
    /// Query items are sorted by name, then value, and the fragment is dropped, so the order in which
    /// parameters were encoded never changes the key, while different parameters always do.
    var cacheKey: String {
        let method = httpMethod ?? HTTPMethod.get.rawValue
        let bodyHash = (httpBody ?? Data()).sha256

        return [method, normalizedURLString, bodyHash].joined(separator: "|").sha256
    }

    private var normalizedURLString: String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url?.absoluteString ?? ""
        }
        components.fragment = nil
        components.percentEncodedQueryItems = components.percentEncodedQueryItems?.sorted {
            ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "")
        }
        return components.string ?? url.absoluteString
    }
}
