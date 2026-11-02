//
//  AuthenticationInterceptor.swift
//  Netti
//

import Foundation

/// Attaches a credential to every request and refreshes it when it expires.
///
/// The credential is refreshed in two cases, and `refresh` is the one place the app handles both:
///
/// - **Before sending**, when `isExpired` says the credential is expired, for example because its
///   expiration date has passed.
/// - **After a response**, when `isRejected` says the server refused it. By default that is any `401`.
///
/// However many requests hit either case at once, the credential is refreshed exactly once: the
/// first one starts the refresh, the others wait for it, and every request is then sent, or sent
/// again, with the new credential. A request is retried at most once. When a refresh started by an
/// expired credential fails, the requests waiting for it fail with the refresh's error instead of
/// going out with a credential known to be dead. When a refresh started by a rejected response
/// fails, the waiting requests are not retried, so their response is returned as received.
///
/// ```swift
/// let auth = AuthenticationInterceptor(bearerToken: session.token) { _ in
///     try await api.refreshToken()
/// }
/// let netti = Netti()
/// netti.interceptors = [auth]
/// ```
///
/// For a credential other than a bearer token, say how it is set on a request:
///
/// ```swift
/// let auth = AuthenticationInterceptor(
///     credential: apiKey,
///     apply: { key, request in request.setValue(key, forHTTPHeaderField: "X-API-Key") },
///     refresh: { _ in try await keychain.rotateAPIKey() }
/// )
/// ```
///
/// `apply` must be idempotent: it must *set* the credential on the request, never append to it.
/// That is how the interceptor tells a request signed with the current credential from one signed
/// with a credential that was refreshed since.
///
/// Pass `hosts` to send the credential only to your own API. Without it the credential goes to
/// every host the client talks to, including a presigned storage URL or a CDN:
///
/// ```swift
/// AuthenticationInterceptor(bearerToken: token, hosts: ["api.example.com"]) { _ in try await api.refreshToken() }
/// ```
///
/// `refresh` may send its request through the client this interceptor belongs to: a request sent
/// while refreshing carries the rejected credential and is never retried, so a `401` on it is
/// returned to `refresh` as received instead of waiting for the refresh it belongs to. That holds
/// for requests sent from `refresh` itself or from a `Task` it creates, but not from
/// `Task.detached`, which does not inherit the refresh context.
public final class AuthenticationInterceptor<Credential: Sendable>: RequestInterceptor {
    private let state: CredentialState<Credential>
    private let apply: @Sendable (Credential, inout URLRequest) -> Void
    private let isExpired: @Sendable (Credential) -> Bool
    private let isRejected: @Sendable (RetryContext) -> Bool
    /// The lowercased hosts that receive the credential; `nil` for every host.
    private let hosts: Set<String>?

    /// Creates an interceptor.
    ///
    /// - Parameters:
    ///   - credential: The credential to start with.
    ///   - hosts: The only hosts that receive the credential, matched exactly and case-insensitively.
    ///     A `401` from any other host is not treated as an expired credential. `nil`, the
    ///     default, sends the credential to every host.
    ///   - isExpired: Whether a credential is known to be expired. It is checked before every request
    ///     and must be cheap and free of side effects. Never expired by default.
    ///   - isRejected: Whether a failed attempt means the server refused the credential. Any `401`
    ///     by default; use ``RetryContext/failureResponse`` to look at the body.
    ///   - apply: Sets the credential on a request.
    ///   - refresh: Returns a new credential, given the one that was rejected.
    public init(
        credential: Credential,
        hosts: Set<String>? = nil,
        isExpired: @escaping @Sendable (Credential) -> Bool = { _ in false },
        isRejected: @escaping @Sendable (RetryContext) -> Bool = { $0.statusCode == 401 },
        apply: @escaping @Sendable (Credential, inout URLRequest) -> Void,
        refresh: @escaping @Sendable (Credential) async throws -> Credential
    ) {
        self.state = CredentialState(credential: credential, refresh: refresh)
        self.apply = apply
        self.isExpired = isExpired
        self.isRejected = isRejected
        self.hosts = hosts.map { Set($0.map { $0.lowercased() }) }
    }

    /// Asynchronously replaces the current credential, for example after a login or a logout.
    ///
    /// A refresh in flight is superseded: its result is discarded, so it never overwrites this
    /// credential, and the requests waiting for it are not retried; their `401` is returned as
    /// received. A request that has not been sent yet, and was waiting for an expired credential's
    /// refresh, is sent with this credential, refreshed first if it is expired too. A request
    /// already sent with an earlier credential is never retried with this one.
    ///
    /// - Parameter credential: The credential every later request carries.
    public func setCredential(_ credential: Credential) async {
        await state.set(credential)
    }

    /// Asynchronously sets the current credential on a request, refreshing it first when it is
    /// expired.
    ///
    /// - Parameter urlRequest: The request about to be sent.
    /// - Returns: The request carrying the current credential; unchanged when its host is not
    ///   one of the interceptor's hosts, or when it already has an `Authorization` header of its
    ///   own, such as HTTP Basic on a login call, that the credential would replace. A `401` for
    ///   such a request is returned as received and never refreshes the credential, even while a
    ///   refresh is running. A credential that writes another header, such as an API key, is
    ///   still applied.
    /// - Throws: The error of a refresh that was needed because the credential is expired.
    public func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        guard isInScope(urlRequest) else {
            return urlRequest
        }
        if await replacesOwnAuthorization(of: urlRequest) {
            return urlRequest
        }
        // A request sent by this interceptor's own refresh must not wait for that refresh.
        let credential = RefreshScope.active.contains(state.id)
            ? await state.credential
            : try await state.credentialForSending(isExpired: isExpired)
        var request = urlRequest
        apply(credential, &request)
        return request
    }

    /// Asynchronously asks for one retry of a rejected response, refreshing the credential first
    /// unless it changed since the request was signed.
    ///
    /// - Parameter context: The failed attempt.
    /// - Returns: ``RetryDecision/retry`` once the credential is fresh; ``RetryDecision/doNotRetry``
    ///   for a response ``init(credential:hosts:isExpired:isRejected:apply:refresh:)``'s `isRejected`
    ///   does not accept, for a request already retried or sent to a host outside the
    ///   interceptor's hosts, when the refresh fails, or when ``setCredential(_:)`` replaced the
    ///   credential while the refresh ran.
    public func retry(_ context: RetryContext) async -> RetryDecision {
        // A request sent by this interceptor's own refresh must not wait for that refresh.
        guard RefreshScope.active.contains(state.id) == false else {
            return .doNotRetry
        }
        guard context.retryCount == 0, isInScope(context.request), isRejected(context) else {
            return .doNotRetry
        }

        do {
            return try await state.refresh(rejected: context.request, apply: apply) ? .retry : .doNotRetry
        } catch {
            return .doNotRetry
        }
    }
}

// MARK: - Private Helpers

private extension AuthenticationInterceptor {
    /// Whether the endpoint set its own `Authorization`, such as HTTP Basic on a login call, and
    /// this interceptor's credential would replace it.
    ///
    /// Every attempt adapts the original request, so a header found here was never ours. It is
    /// kept, and a `401` for it is returned as received: no credential of this interceptor was
    /// sent, so refreshing it cannot help. A credential that writes another header, such as an
    /// API key, never replaces it, so it is still applied. The check uses the current credential
    /// without waiting for a refresh, so a login never waits for one.
    ///
    /// An empty value counts as no header. A header that already equals what the credential would
    /// write, such as `Bearer <current token>` set by hand, is indistinguishable from a signed
    /// request, so a `401` for it does refresh.
    func replacesOwnAuthorization(of request: URLRequest) async -> Bool {
        guard let own = request.value(forHTTPHeaderField: "Authorization"), own.isEmpty == false else {
            return false
        }
        var probe = request
        apply(await state.credential, &probe)
        return probe.value(forHTTPHeaderField: "Authorization") != own
    }

    func isInScope(_ request: URLRequest) -> Bool {
        guard let hosts else {
            return true
        }
        guard let host = request.url?.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        return hosts.contains(host)
    }
}

extension AuthenticationInterceptor where Credential == String {
    /// Creates an interceptor that sends the token as `Authorization: Bearer <token>`.
    ///
    /// - Parameters:
    ///   - bearerToken: The token to start with.
    ///   - hosts: The only hosts that receive the token, matched exactly and case-insensitively.
    ///     `nil`, the default, sends it to every host.
    ///   - refresh: Returns a new token, given the one that was rejected.
    public convenience init(
        bearerToken: String,
        hosts: Set<String>? = nil,
        refresh: @escaping @Sendable (String) async throws -> String
    ) {
        self.init(
            credential: bearerToken,
            hosts: hosts,
            apply: { token, request in
                request.setValue(HTTPHeader.authorization(bearerToken: token).value, forHTTPHeaderField: "Authorization")
            },
            refresh: refresh
        )
    }
}

/// The refreshes the current task runs inside, one ``CredentialState`` each.
private enum RefreshScope {
    @TaskLocal static var active: Set<ObjectIdentifier> = []
}

/// Owns the credential and the single refresh that may be in flight.
///
/// Every ``set(_:)`` starts a new generation. A refresh records the generation it started in and
/// applies its result only if no ``set(_:)`` happened since, so a logout or an account switch
/// during a refresh is never overwritten by the previous credential's renewal (TM-36).
private actor CredentialState<Credential: Sendable> {
    /// A refresh in flight and the generation it started in.
    private struct InFlightRefresh {
        let task: Task<Credential, any Error>
        let generation: UInt64
    }

    /// How many credentials renewed away from are remembered, see ``renewedAway``.
    private static var renewedAwayLimit: Int { 4 }

    private(set) var credential: Credential
    private var generation: UInt64 = 0
    /// Changes whenever the credential does: on ``set(_:)`` and when a refresh is applied.
    private var credentialVersion: UInt64 = 0
    /// The version of a credential a refresh returned that `isExpired` still flags, so it is sent
    /// as it is instead of being refreshed again for every request.
    private var expiredAfterRefresh: UInt64?
    /// The credentials this session was renewed away from, newest last, cleared by ``set(_:)``.
    ///
    /// A request signed with one of them was signed in this session, so it may be retried with the
    /// renewal. A request signed with any other credential that is no longer current belongs to a
    /// session ``set(_:)`` replaced, and is not retried.
    private var renewedAway: [Credential] = []
    private var inFlight: InFlightRefresh?
    private let refreshCredential: @Sendable (Credential) async throws -> Credential

    /// Identifies this state's refresh in ``RefreshScope``.
    nonisolated var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    init(credential: Credential, refresh: @escaping @Sendable (Credential) async throws -> Credential) {
        self.credential = credential
        self.refreshCredential = refresh
    }

    /// Replaces the credential and supersedes any refresh in flight.
    ///
    /// The superseded refresh keeps running, since cancelling it could cancel a request the app's
    /// `refresh` closure has already sent, but its result is discarded.
    func set(_ credential: Credential) {
        self.credential = credential
        generation &+= 1
        credentialVersion &+= 1
        renewedAway.removeAll()
        inFlight = nil
    }

    /// Returns the credential a new request is signed with, refreshing it first when `isExpired`
    /// says it is expired.
    ///
    /// A credential that is not expired is returned at once, even while a refresh is running: the
    /// refresh a `401` started does not hold up requests that do not need it. An expired
    /// credential joins the refresh in flight or starts one. The expiry check and the start of the
    /// refresh run with no suspension between them, so concurrent callers share one refresh.
    ///
    /// A refresh that returns a credential `isExpired` still flags, for example because the
    /// device clock is ahead of the server's, is not repeated: that credential is sent as it is
    /// and a `401` is the only thing that refreshes it again.
    ///
    /// - Throws: The refresh's error, unless ``set(_:)`` replaced the credential meanwhile, or
    ///   `CancellationError` when the caller was cancelled while waiting.
    func credentialForSending(isExpired: @Sendable (Credential) -> Bool) async throws -> Credential {
        guard isExpired(credential), expiredAfterRefresh != credentialVersion else {
            return credential
        }
        let refresh = inFlight ?? beginRefresh()
        do {
            _ = try await refresh.task.value
        } catch {
            if refresh.generation == generation {
                throw error
            }
        }
        try Task.checkCancellation()
        guard refresh.generation == generation else {
            // ``set(_:)`` replaced the credential meanwhile; the one it set may itself be expired.
            return try await credentialForSending(isExpired: isExpired)
        }
        if isExpired(credential) {
            expiredAfterRefresh = credentialVersion
        }
        return credential
    }

    /// Refreshes the credential `request` was signed with, or joins the refresh already in flight.
    ///
    /// Returns without refreshing when the credential was renewed after `request` was signed. The
    /// check and the start of the refresh run with no suspension between them, so a `401` that
    /// arrives just after a refresh finished never starts a second one.
    ///
    /// - Returns: `true` when `request` may be retried with the current credential; `false` when
    ///   ``set(_:)`` replaced the credential, whether before the `401` arrived or while the
    ///   refresh ran. A request signed before an account switch or a logout is then not retried
    ///   at all: neither with the previous credential's renewal nor with a credential that belongs
    ///   to another session.
    func refresh(rejected request: URLRequest, apply: @Sendable (Credential, inout URLRequest) -> Void) async throws -> Bool {
        var probe = request
        apply(credential, &probe)
        let signedWithCurrent = probe == request
        // A request that carries none of this interceptor's credentials, such as one with its own
        // `Authorization`, is not ours to refresh for, even while a refresh is running.
        guard signedWithCurrent || signedWithRenewedAway(request, apply: apply) else {
            return false
        }
        if let inFlight {
            _ = try await inFlight.task.value
            return inFlight.generation == generation
        }
        guard signedWithCurrent else {
            return true
        }
        let refresh = beginRefresh()
        _ = try await refresh.task.value
        return refresh.generation == generation
    }

    /// Whether `request` was signed with a credential that has since been renewed.
    private func signedWithRenewedAway(_ request: URLRequest, apply: @Sendable (Credential, inout URLRequest) -> Void) -> Bool {
        renewedAway.contains { candidate in
            var signedWithCandidate = request
            apply(candidate, &signedWithCandidate)
            return signedWithCandidate == request
        }
    }

    /// Starts a refresh of the current credential and records it as the one in flight.
    private func beginRefresh() -> InFlightRefresh {
        let rejected = credential
        let started = generation
        let refreshCredential = refreshCredential
        let scopes = RefreshScope.active.union([id])
        let task = Task {
            do {
                let renewed = try await RefreshScope.$active.withValue(scopes) {
                    try await refreshCredential(rejected)
                }
                self.finishRefresh(with: renewed, startedIn: started)
                return renewed
            } catch {
                self.finishRefresh(with: nil, startedIn: started)
                throw error
            }
        }
        let refresh = InFlightRefresh(task: task, generation: started)
        inFlight = refresh
        return refresh
    }

    /// Applies a refresh's result unless ``set(_:)`` superseded it; a superseded refresh leaves the
    /// credential and any newer refresh untouched.
    private func finishRefresh(with renewed: Credential?, startedIn started: UInt64) {
        guard started == generation else {
            return
        }
        if let renewed {
            renewedAway.append(credential)
            if renewedAway.count > Self.renewedAwayLimit {
                renewedAway.removeFirst()
            }
            credential = renewed
            credentialVersion &+= 1
        }
        inFlight = nil
    }
}
