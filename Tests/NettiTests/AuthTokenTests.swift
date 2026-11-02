import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

@Suite("AuthToken", .timeLimit(.minutes(1)))
struct AuthTokenTests {

    /// A clock the test moves by hand.
    private final class Clock: Sendable {
        private let start = Date()
        private let offset = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

        var now: Date {
            start.addingTimeInterval(offset.withLock { $0 })
        }

        func advance(by seconds: TimeInterval) {
            offset.withLock { $0 += seconds }
        }
    }

    private func bearer(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")
    }

    // MARK: - Token

    @Test("given a duration, when a token is created, then it expires that long from now")
    func init_expiresIn_setsExpiresAt() {
        let before = Date()
        let token = AuthToken(accessToken: "a", expiresIn: .seconds(3600))

        let remaining = token.expiresAt?.timeIntervalSince(before)
        #expect(remaining.map { (3599...3601).contains($0) } == true)
    }

    @Test("given a token, when it is printed, then neither token appears")
    func description_hidesSecrets() {
        let token = AuthToken(accessToken: "secret-access", refreshToken: "secret-refresh", expiresIn: .seconds(60))

        #expect(token.description.contains("secret") == false)
        #expect("\(token)".contains("secret") == false)
    }

    @Test("given two tokens with the same values, when compared, then they are equal whenever they were created")
    func equality_ignoresCreationTime() async throws {
        let expiresAt = Date().addingTimeInterval(60)
        let first = AuthToken(accessToken: "a", refreshToken: "r", expiresAt: expiresAt)
        try await Task.sleep(for: .milliseconds(5))
        let second = AuthToken(accessToken: "a", refreshToken: "r", expiresAt: expiresAt)

        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
    }

    // MARK: - Expiry

    @Test("given no expiration date, when checked, then the token is never expired")
    func isExpired_noDate_neverExpired() {
        let token = AuthToken(accessToken: "a")

        #expect(token.isExpired(at: .distantFuture, leeway: .seconds(30)) == false)
    }

    @Test("given a date in the past, when checked, then the token is expired")
    func isExpired_past_isExpired() {
        let token = AuthToken(accessToken: "a", expiresAt: Date().addingTimeInterval(-1))

        #expect(token.isExpired(at: Date(), leeway: .zero))
    }

    @Test("given a leeway, when the clock reaches the leeway window, then the token counts as expired before its date")
    func isExpired_insideLeeway_isExpired() {
        let clock = Clock()
        let token = AuthToken(accessToken: "a", expiresAt: clock.now.addingTimeInterval(120))

        #expect(token.isExpired(at: clock.now, leeway: .seconds(30)) == false)
        clock.advance(by: 89)
        #expect(token.isExpired(at: clock.now, leeway: .seconds(30)) == false)
        clock.advance(by: 2)
        #expect(token.isExpired(at: clock.now, leeway: .seconds(30)))
    }

    @Test("given a token that lives shorter than the leeway, when it is issued, then it is not expired at once")
    func isExpired_shortLivedToken_clampsLeeway() {
        let token = AuthToken(accessToken: "a", expiresIn: .seconds(20))

        #expect(token.isExpired(at: Date(), leeway: .seconds(30)) == false)
        #expect(token.isExpired(at: Date().addingTimeInterval(11), leeway: .seconds(30)))
    }

    @Test("given a negative leeway, when a token is past its date, then it is still expired")
    func isExpired_negativeLeeway_isClamped() {
        let token = AuthToken(accessToken: "a", expiresAt: Date().addingTimeInterval(-10))

        #expect(token.isExpired(at: Date(), leeway: .seconds(-30)))
    }

    @Test("given a token, when it is dumped, then neither token appears")
    func reflection_hidesSecrets() {
        var output = ""
        dump(AuthToken(accessToken: "secret-access", refreshToken: "secret-refresh", expiresIn: .seconds(60)), to: &output)

        #expect(output.contains("secret") == false)
        #expect(output.contains("expiresAt"))
    }

    // MARK: - Interceptor

    @Test("given a token, when a request is adapted, then it carries the access token as a bearer")
    func adapt_attachesBearer() async throws {
        let interceptor = AuthenticationInterceptor(token: AuthToken(accessToken: "abc")) { $0 }

        let adapted = try await interceptor.adapt(makeURLRequest())

        #expect(bearer(adapted) == "Bearer abc")
    }

    @Test("given a token inside the leeway, when a request is adapted, then it is refreshed first with the expired token")
    func adapt_insideLeeway_refreshesWithExpiredToken() async throws {
        let clock = Clock()
        let received = Recorder<AuthToken>()
        let interceptor = AuthenticationInterceptor(
            token: AuthToken(accessToken: "old", refreshToken: "r1", expiresAt: clock.now.addingTimeInterval(120)),
            hosts: nil,
            refreshLeeway: .seconds(30),
            isRejected: { $0.statusCode == 401 },
            now: { clock.now },
            refresh: { expired in
                received.append(expired)
                return AuthToken(accessToken: "new", refreshToken: "r2", expiresAt: clock.now.addingTimeInterval(3600))
            }
        )

        let fresh = try await interceptor.adapt(makeURLRequest())
        clock.advance(by: 100)
        let refreshed = try await interceptor.adapt(makeURLRequest())
        let again = try await interceptor.adapt(makeURLRequest())

        #expect(bearer(fresh) == "Bearer old")
        #expect(bearer(refreshed) == "Bearer new")
        #expect(bearer(again) == "Bearer new")
        #expect(received.values.map(\.refreshToken) == ["r1"])
    }

    @Test("given an expired token and 20 parallel requests, when they are sent, then one refresh runs and every request carries the new token")
    func send_expiredToken_refreshesOnce() async throws {
        let refreshes = Counter()
        let service = StubNetworkService { request in
            .stub(for: request, status: self.bearer(request) == "Bearer new" ? 200 : 401)
        }
        let interceptor = AuthenticationInterceptor(token: AuthToken(accessToken: "old", expiresAt: Date().addingTimeInterval(-60))) { _ in
            refreshes.increment()
            try await Task.sleep(for: .milliseconds(100))
            return AuthToken(accessToken: "new", expiresIn: .seconds(3600))
        }
        let netti = makeNetti(service: service, interceptors: [interceptor], deduplicatesRequests: false)

        let statuses = try await withThrowingTaskGroup(of: Int?.self) { group in
            for _ in 0..<20 {
                group.addTask { try await netti.get(TestEndpoint()).statusCode }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(statuses == Array(repeating: 200 as Int?, count: 20))
        #expect(refreshes.value == 1)
        #expect(Set(service.requests.map(bearer)) == ["Bearer new"])
    }

    @Test("given a token that is valid by its date, when the server rejects it, then it is refreshed and the request retried")
    func send_rejectedToken_refreshesAndRetries() async throws {
        let refreshes = Counter()
        let service = StubNetworkService { request in
            .stub(for: request, status: self.bearer(request) == "Bearer new" ? 200 : 401)
        }
        let interceptor = AuthenticationInterceptor(token: AuthToken(accessToken: "old", expiresIn: .seconds(3600))) { _ in
            refreshes.increment()
            return AuthToken(accessToken: "new", expiresIn: .seconds(3600))
        }
        let netti = makeNetti(service: service, interceptors: [interceptor])

        let status = try await netti.get(TestEndpoint()).statusCode

        #expect(status == 200)
        #expect(refreshes.value == 1)
        #expect(service.requests.map(bearer) == ["Bearer old", "Bearer new"])
    }

    @Test("given a refresh that returns a token that is already expired, when 5 requests are sent one after another, then one refresh runs")
    func send_refreshReturnsExpiredToken_refreshesOnce() async throws {
        let refreshes = Counter()
        let interceptor = AuthenticationInterceptor(token: AuthToken(accessToken: "old", expiresAt: Date().addingTimeInterval(-60))) { _ in
            AuthToken(accessToken: "renewed-\(refreshes.increment())", expiresAt: Date().addingTimeInterval(-60))
        }

        var sent: [String?] = []
        for _ in 0..<5 {
            sent.append(bearer(try await interceptor.adapt(makeURLRequest())))
        }

        #expect(refreshes.value == 1)
        #expect(sent == Array(repeating: "Bearer renewed-1", count: 5))
    }
}
