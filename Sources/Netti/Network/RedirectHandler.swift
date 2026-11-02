//
//  RedirectHandler.swift
//  Netti
//

import Foundation

/// Decides what happens when the server answers with a redirect.
///
/// Pass one to the engine; ``URLSessionNetworkService`` asks it about every redirect. Without one,
/// the engine uses ``secure``.
///
/// ```swift
/// URLSessionNetworkService(redirectHandler: .doNotFollow)
///
/// URLSessionNetworkService(redirectHandler: RedirectHandler { proposed, _ in
///     var request = proposed
///     request.setValue(nil, forHTTPHeaderField: "X-Internal")
///     return .modify(request)
/// })
/// ```
///
/// A custom handler replaces ``secure`` entirely, so it takes on the protections listed there.
public struct RedirectHandler: Sendable {

    // MARK: - Types

    /// The outcome of a redirect.
    public enum Decision: Sendable {
        /// Send the request URLSession proposes.
        case follow
        /// Stop; the redirect response itself is returned to the caller.
        case doNotFollow
        /// Send this request instead.
        case modify(URLRequest)
    }

    /// What the engine does with a redirect.
    enum Outcome: Sendable, Equatable {
        /// Send this request.
        case send(URLRequest)
        /// Stop; the redirect response is returned to the caller.
        case stop
        /// Stop and fail the call with ``HTTPRequestError/requestFailed(_:)``.
        case fail(URLError)
    }

    /// One redirect, as the engine sees it.
    struct Redirect: Sendable {
        /// The request URLSession proposes.
        let proposed: URLRequest
        /// The redirect response; its URL is the URL being left.
        let response: HTTPURLResponse
        /// The request that received the redirect, when known.
        let current: URLRequest?
        /// Whether the original request carries a body: `httpBody`, `httpBodyStream`, or an upload.
        let hasBody: Bool
    }

    // MARK: - Constants

    /// Headers that carry credentials and never cross to another origin under ``secure``.
    private static let credentialHeaders = ["Authorization", "Proxy-Authorization", "Cookie"]

    /// Redirect statuses that preserve the method and body.
    private static let bodyPreservingStatusCodes: Set<Int> = [307, 308]

    // MARK: - Properties

    private let decide: @Sendable (Redirect) -> Outcome

    // MARK: - Initialization

    /// Creates a handler.
    ///
    /// - Parameter decide: Called with the request URLSession proposes and the redirect response.
    public init(_ decide: @escaping @Sendable (_ proposed: URLRequest, _ response: HTTPURLResponse) -> Decision) {
        self.decide = { redirect in
            switch decide(redirect.proposed, redirect.response) {
                case .follow: .send(redirect.proposed)
                case .doNotFollow: .stop
                case .modify(let request): .send(request)
            }
        }
    }

    /// Creates a handler that can also fail the call.
    init(outcome: @escaping @Sendable (Redirect) -> Outcome) {
        self.decide = outcome
    }

    // MARK: - Handlers

    /// The default: follows redirects, but not in a way that leaks credentials or downgrades the
    /// connection.
    ///
    /// - A redirect from `https` to `http` fails the call with
    ///   ``HTTPRequestError/requestFailed(_:)`` carrying `URLError.appTransportSecurityRequiresSecureConnection`.
    /// - A redirect to another origin (a different scheme, host or port) is followed without its
    ///   `Authorization`, `Proxy-Authorization` and `Cookie` headers. `URLSession` itself forwards them.
    /// - A 307 or 308 to another origin, for a request with a body, is not followed: the redirect
    ///   response is returned, as with ``doNotFollow``, so the body is never sent to that origin.
    ///
    /// Redirects on the same origin are followed with their credentials: `URLSession` drops
    /// `Authorization` and `Proxy-Authorization` from every redirect, so they are copied back from
    /// the request that was redirected.
    public static let secure = RedirectHandler(outcome: secureOutcome)

    /// Follows every redirect unchanged, credentials and body included, even to another origin or
    /// from `https` to `http`. Opts out of ``secure``.
    public static let follow = RedirectHandler { _, _ in .follow }

    /// Follows none, returning the redirect response itself.
    public static let doNotFollow = RedirectHandler { _, _ in .doNotFollow }

    // MARK: - Deciding

    /// What to do with a redirect.
    func outcome(for proposed: URLRequest, response: HTTPURLResponse, current: URLRequest?, hasBody: Bool) -> Outcome {
        decide(Redirect(proposed: proposed, response: response, current: current, hasBody: hasBody))
    }
}

// MARK: - Private Helpers

private extension RedirectHandler {
    @Sendable
    static func secureOutcome(_ redirect: Redirect) -> Outcome {
        let source = redirect.response.url
        let destination = redirect.proposed.url
        if source?.scheme?.lowercased() == "https", destination?.scheme?.lowercased() == "http" {
            return .fail(URLError(.appTransportSecurityRequiresSecureConnection))
        }
        guard Origin(source) != Origin(destination) else {
            return .send(restoringCredentials(of: redirect))
        }
        if redirect.hasBody, bodyPreservingStatusCodes.contains(redirect.response.statusCode) {
            return .stop
        }
        var request = redirect.proposed
        for name in credentialHeaders {
            request.setValue(nil, forHTTPHeaderField: name)
        }
        return .send(request)
    }

    /// The proposed request, with any credential header URLSession dropped copied back from the
    /// request that was redirected.
    static func restoringCredentials(of redirect: Redirect) -> URLRequest {
        var request = redirect.proposed
        for name in credentialHeaders where request.value(forHTTPHeaderField: name) == nil {
            if let value = redirect.current?.value(forHTTPHeaderField: name) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    /// The scheme, host and port of a URL, with the scheme's default port filled in.
    struct Origin: Equatable {
        let scheme: String?
        let host: String?
        let port: Int?

        init(_ url: URL?) {
            let scheme = url?.scheme?.lowercased()
            self.scheme = scheme
            self.host = url?.host?.lowercased()
            self.port = url?.port ?? scheme.flatMap { Self.defaultPorts[$0] }
        }

        private static let defaultPorts = ["http": 80, "https": 443, "ws": 80, "wss": 443]
    }
}
