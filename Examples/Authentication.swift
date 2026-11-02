//
//  Authentication.swift
//  Netti
//

import Foundation
import NettiTesting

// The `refresh` closure of `AuthenticationInterceptor` is the app's single "token expired" hook:
// it runs when the token's date has passed (before sending) and when the server rejects it
// (after sending), and however many requests hit either case at once, it runs once.

/// Runs the four authentication scenarios in order.
///
/// Runs offline: a stub engine answers `200` only for the token the server currently accepts and
/// `401` for every other one.
func authenticationExample() async throws {
    try await refreshBeforeSendingExample()
    try await refreshOnRejectionBodyExample()
    try await parallelRequestsShareOneRefreshExample()
    try await loginAndLogoutExample()
}

// MARK: - a) Expired by date

/// The token's `expiresAt` has passed, so it is refreshed before the request leaves the device
/// and the server never sees the stale token.
func refreshBeforeSendingExample() async throws {
    let refreshes = Counter()
    let service = tokenServer(accepting: ["fresh-token"])
    let stale = AuthToken(accessToken: "stale-token", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(-60))
    let auth = AuthenticationInterceptor(token: stale) { expired in
        refreshes.increment()
        return AuthToken(accessToken: "fresh-token", refreshToken: "refresh-2", expiresIn: .seconds(3600))
    }
    let netti = makeClient(service, interceptors: [auth])

    let response = try await netti.get(UserAPI.user(1))
    let sentTokens = service.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
    report("a) expired by date -> status \(response.statusCode ?? 0), refreshes \(refreshes.value), server saw \(sentTokens)")
    try expect(response.statusCode == 200, "expected 200")
    try expect(refreshes.value == 1, "expected exactly 1 refresh, got \(refreshes.value)")
    try expect(sentTokens == ["Bearer fresh-token"], "the stale token reached the server: \(sentTokens)")
}

// MARK: - b) Expired by body code

/// The backend says "expired" with a body code. Only a `401` carrying `TOKEN_EXPIRED` triggers a
/// refresh; any other `401` is returned untouched.
func refreshOnRejectionBodyExample() async throws {
    // Refreshes and retries once, then succeeds.
    let refreshes = Counter()
    let service = tokenServer(accepting: ["new-token"], rejectionCode: "TOKEN_EXPIRED")
    let auth = AuthenticationInterceptor(
        token: AuthToken(accessToken: "old-token", refreshToken: "refresh-1", expiresIn: .seconds(3600)),
        isRejected: isTokenExpired
    ) { _ in
        refreshes.increment()
        return AuthToken(accessToken: "new-token", refreshToken: "refresh-2", expiresIn: .seconds(3600))
    }
    let netti = makeClient(service, interceptors: [auth])
    let recovered = try await netti.get(UserAPI.user(1))
    report("b) TOKEN_EXPIRED   -> status \(recovered.statusCode ?? 0), refreshes \(refreshes.value), attempts \(service.requests.count)")
    try expect(recovered.statusCode == 200 && refreshes.value == 1, "TOKEN_EXPIRED should refresh once and retry")

    // A 401 for another reason is not an expired token: no refresh, the response comes back as is.
    let otherRefreshes = Counter()
    let other = tokenServer(accepting: [], rejectionCode: "ACCOUNT_SUSPENDED")
    let otherAuth = AuthenticationInterceptor(
        token: AuthToken(accessToken: "old-token", expiresIn: .seconds(3600)),
        isRejected: isTokenExpired
    ) { _ in
        otherRefreshes.increment()
        return AuthToken(accessToken: "new-token", expiresIn: .seconds(3600))
    }
    let untouched = try await makeClient(other, interceptors: [otherAuth]).get(UserAPI.user(1))
    report("b) ACCOUNT_SUSPENDED -> status \(untouched.statusCode ?? 0), refreshes \(otherRefreshes.value)")
    try expect(untouched.statusCode == 401 && otherRefreshes.value == 0, "another 401 must be returned untouched")
}

/// `true` only for a `401` whose body says the token expired.
@Sendable private func isTokenExpired(_ context: RetryContext) -> Bool {
    guard context.statusCode == 401, let body = context.failureResponse?.rawData else {
        return false
    }
    return String(decoding: body, as: UTF8.self).contains("TOKEN_EXPIRED")
}

// MARK: - c) Parallel requests, one refresh

/// Twenty requests start with an expired token. One of them starts the refresh, the other
/// nineteen wait for it, and all twenty go out with the new token.
func parallelRequestsShareOneRefreshExample() async throws {
    let refreshes = Counter()
    let service = tokenServer(accepting: ["fresh-token"])
    let auth = AuthenticationInterceptor(
        token: AuthToken(accessToken: "stale-token", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(-60))
    ) { _ in
        refreshes.increment()
        try await Task.sleep(for: .milliseconds(50)) // a slow refresh makes the overlap real
        return AuthToken(accessToken: "fresh-token", refreshToken: "refresh-2", expiresIn: .seconds(3600))
    }
    let netti = makeClient(service, interceptors: [auth])

    // Different ids give different URLs, so deduplication cannot merge the requests.
    let statuses: [Int?] = try await netti.concurrent(1...20, maxConcurrency: 20) { id in
        try await netti.get(UserAPI.user(id)).statusCode
    }
    let succeeded = statuses.filter { $0 == 200 }.count
    let freshOnly = service.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token" }
    report("c) 20 parallel     -> \(succeeded) succeeded, refreshes: \(refreshes.value), only the new token sent: \(freshOnly)")
    try expect(refreshes.value == 1, "expected exactly 1 refresh, got \(refreshes.value)")
    try expect(succeeded == 20, "expected 20 successes, got \(succeeded)")
    try expect(freshOnly, "a request went out with the stale token")
}

// MARK: - d) Login and logout

/// `setCredential` swaps the token for a login, an account switch or a logout.
func loginAndLogoutExample() async throws {
    let signedOut = "signed-out"
    let service = tokenServer(accepting: ["alice-token", "bob-token"])
    let auth = AuthenticationInterceptor(token: AuthToken(accessToken: "alice-token", expiresIn: .seconds(3600))) { rejected in
        // Nothing to refresh for a signed-out session; failing keeps the 401 as the server sent it.
        if rejected.accessToken == signedOut {
            throw ExampleError(description: "signed out")
        }
        return AuthToken(accessToken: "alice-token", expiresIn: .seconds(3600))
    }
    let netti = makeClient(service, interceptors: [auth])

    let asAlice = try await netti.get(UserAPI.user(1)).statusCode
    await auth.setCredential(AuthToken(accessToken: "bob-token", expiresIn: .seconds(3600))) // account switch
    let asBob = try await netti.get(UserAPI.user(1)).statusCode
    await auth.setCredential(AuthToken(accessToken: signedOut, expiresIn: .seconds(3600))) // logout
    let afterLogout = try await netti.get(UserAPI.user(1)).statusCode
    report("d) login/logout    -> alice \(asAlice ?? 0), bob \(asBob ?? 0), after logout \(afterLogout ?? 0)")
    try expect(asAlice == 200 && asBob == 200 && afterLogout == 401, "unexpected statuses after setCredential")
}

// MARK: - Helpers

/// An engine that answers `200` only for a `Bearer` token in `accepting`, and `401` with
/// `{"code": rejectionCode}` otherwise.
private func tokenServer(accepting tokens: Set<String>, rejectionCode: String = "INVALID_TOKEN") -> StubNetworkService {
    StubNetworkService(data: { request in
        let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
        guard header.hasPrefix("Bearer "), tokens.contains(String(header.dropFirst("Bearer ".count))) else {
            return .stub(for: request, status: 401, body: Data(#"{"code": "\#(rejectionCode)"}"#.utf8))
        }
        return try .json(for: request, User(id: 1, name: "Ada"))
    })
}

private func makeClient(_ service: StubNetworkService, interceptors: [any RequestInterceptor]) -> Netti {
    let netti = Netti(service: service)
    netti.isLoggingEnabled = false
    netti.interceptors = interceptors
    return netti
}
