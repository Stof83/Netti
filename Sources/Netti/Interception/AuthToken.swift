//
//  AuthToken.swift
//  Netti
//

import Foundation

/// A bearer access token with the optional refresh token and expiration date of its login or
/// refresh response.
///
/// Give it to ``AuthenticationInterceptor/init(token:hosts:refreshLeeway:isRejected:refresh:)``,
/// which refreshes it shortly before ``expiresAt`` and whenever the server rejects it.
///
/// ```swift
/// let token = AuthToken(accessToken: login.accessToken, refreshToken: login.refreshToken, expiresIn: .seconds(login.expiresIn))
/// ```
///
/// Neither the description nor the reflection (`dump`, `Mirror`) contains the tokens, so logging a
/// value is safe.
///
/// A token created with ``init(accessToken:refreshToken:expiresAt:)`` measures its life from the
/// moment it is created, so one restored from storage at launch keeps the refresh leeway no longer
/// than half of its remaining life.
public struct AuthToken: Sendable, Hashable, CustomStringConvertible, CustomReflectable {
    /// The token sent as `Authorization: Bearer <accessToken>`.
    public let accessToken: String

    /// The token that obtains a new access token; `nil` when the app does not need it to refresh.
    public let refreshToken: String?

    /// When the access token expires; `nil` when it is not known, so only a rejection refreshes it.
    public let expiresAt: Date?

    /// When this value was created, used to keep the refresh leeway shorter than the token's life.
    let issuedAt: Date

    /// Creates a token that expires at a date.
    ///
    /// - Parameters:
    ///   - accessToken: The token sent with every request.
    ///   - refreshToken: The token that obtains a new access token. `nil` by default.
    ///   - expiresAt: When the access token expires. `nil`, the default, means unknown.
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.issuedAt = Date()
    }

    /// Creates a token that expires a duration from now, as an `expires_in` response field says.
    ///
    /// - Parameters:
    ///   - accessToken: The token sent with every request.
    ///   - refreshToken: The token that obtains a new access token. `nil` by default.
    ///   - expiresIn: How long the access token lives, counted from now.
    public init(accessToken: String, refreshToken: String? = nil, expiresIn: Duration) {
        let issuedAt = Date()
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = issuedAt.addingTimeInterval(expiresIn.timeInterval)
        self.issuedAt = issuedAt
    }

    /// The token without its secrets.
    public var description: String {
        "AuthToken(expiresAt: \(expiresAt.map { "\($0)" } ?? "unknown"))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["expiresAt": expiresAt as Any], displayStyle: .struct)
    }

    public static func == (lhs: AuthToken, rhs: AuthToken) -> Bool {
        lhs.accessToken == rhs.accessToken && lhs.refreshToken == rhs.refreshToken && lhs.expiresAt == rhs.expiresAt
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(accessToken)
        hasher.combine(refreshToken)
        hasher.combine(expiresAt)
    }

    /// Whether the token expires within `leeway` of `now`.
    ///
    /// The leeway is cut to half the token's life, so a token that lives shorter than the leeway
    /// is not expired from the moment it is issued.
    func isExpired(at now: Date, leeway: Duration) -> Bool {
        guard let expiresAt else {
            return false
        }
        let lifetime = expiresAt.timeIntervalSince(issuedAt)
        let effectiveLeeway = max(0, min(leeway.timeInterval, max(lifetime, 0) / 2))
        return expiresAt.addingTimeInterval(-effectiveLeeway) <= now
    }
}

extension AuthenticationInterceptor where Credential == AuthToken {
    /// Creates an interceptor that sends the token as `Authorization: Bearer <accessToken>` and
    /// refreshes it shortly before it expires and whenever the server rejects it.
    ///
    /// ```swift
    /// netti.interceptors = [
    ///     AuthenticationInterceptor(token: session.token, hosts: ["api.example.com"]) { expired in
    ///         try await authAPI.refresh(using: expired.refreshToken)
    ///     }
    /// ]
    /// ```
    ///
    /// - Parameters:
    ///   - token: The token to start with.
    ///   - hosts: The only hosts that receive the token, matched exactly and case-insensitively.
    ///     `nil`, the default, sends it to every host.
    ///   - refreshLeeway: How long before ``AuthToken/expiresAt`` the token counts as expired, so a
    ///     request is not sent with a token that expires in flight or because of a clock that is a
    ///     little off. Thirty seconds by default.
    ///   - isRejected: Whether a failed attempt means the server refused the token. Any `401` by
    ///     default; use ``RetryContext/failureResponse`` to look at the body, for example for a
    ///     `TOKEN_EXPIRED` code.
    ///   - refresh: Returns a new token, given the expired or rejected one.
    public convenience init(
        token: AuthToken,
        hosts: Set<String>? = nil,
        refreshLeeway: Duration = .seconds(30),
        isRejected: @escaping @Sendable (RetryContext) -> Bool = { $0.statusCode == 401 },
        refresh: @escaping @Sendable (AuthToken) async throws -> AuthToken
    ) {
        self.init(token: token, hosts: hosts, refreshLeeway: refreshLeeway, isRejected: isRejected, now: { Date() }, refresh: refresh)
    }

    /// The designated form of ``init(token:hosts:refreshLeeway:isRejected:refresh:)``, with the
    /// clock injectable for tests.
    convenience init(
        token: AuthToken,
        hosts: Set<String>?,
        refreshLeeway: Duration,
        isRejected: @escaping @Sendable (RetryContext) -> Bool,
        now: @escaping @Sendable () -> Date,
        refresh: @escaping @Sendable (AuthToken) async throws -> AuthToken
    ) {
        self.init(
            credential: token,
            hosts: hosts,
            isExpired: { $0.isExpired(at: now(), leeway: refreshLeeway) },
            isRejected: isRejected,
            apply: { token, request in
                request.setValue(HTTPHeader.authorization(bearerToken: token.accessToken).value, forHTTPHeaderField: "Authorization")
            },
            refresh: refresh
        )
    }
}
