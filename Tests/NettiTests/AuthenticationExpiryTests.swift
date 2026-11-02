import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

/// Token expiry: a credential known to be expired is refreshed before a request is sent, a
/// response the app recognizes as "token expired" is refreshed and retried, and both paths share
/// one refresh however many requests are in flight.
@Suite("AuthenticationInterceptor expiry", .timeLimit(.minutes(1)))
struct AuthenticationExpiryTests {
    private struct RefreshFailure: Error {}

    private struct Token: Codable, Sendable {
        let value: String
    }

    /// Holds the client so the refresh closure can send through the client that owns the interceptor.
    private final class ClientBox: Sendable {
        private let storage = OSAllocatedUnfairLock<Netti?>(initialState: nil)

        var netti: Netti? {
            get { storage.withLock { $0 } }
            set { storage.withLock { $0 = newValue } }
        }
    }

    /// Holds a refresh until the test opens it, so the test decides when the refresh finishes.
    private actor Gate {
        private var isOpen = false

        func wait() async {
            while isOpen == false, Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        func open() {
            isOpen = true
        }
    }

    private static let expired = "old"

    /// An interceptor whose `old` credential is expired and whose refreshes are numbered `new-1`, `new-2`, …
    private func makeInterceptor(
        refreshes: Counter = Counter(),
        refreshDelay: Duration = .milliseconds(50),
        fails: Bool = false,
        gate: Gate? = nil,
        isRejected: @escaping @Sendable (RetryContext) -> Bool = { $0.statusCode == 401 }
    ) -> AuthenticationInterceptor<String> {
        AuthenticationInterceptor(
            credential: Self.expired,
            isExpired: { $0 == Self.expired },
            isRejected: isRejected,
            apply: { token, request in request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") },
            refresh: { _ in
                let generation = refreshes.increment()
                if let gate {
                    await gate.wait()
                } else {
                    try await Task.sleep(for: refreshDelay)
                }
                if fails { throw RefreshFailure() }
                return "new-\(generation)"
            }
        )
    }

    private func bearer(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")
    }

    private func waitForRefreshToStart(_ refreshes: Counter) async {
        _ = await eventually { refreshes.value >= 1 }
    }

    // MARK: - Expired before sending

    @Test("given a credential that is not expired, when a request is adapted, then nothing refreshes")
    func adapt_notExpired_doesNotRefresh() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes)
        await interceptor.setCredential("fresh")

        let adapted = try await interceptor.adapt(makeURLRequest())

        #expect(bearer(adapted) == "Bearer fresh")
        #expect(refreshes.value == 0)
    }

    @Test("given an expired credential, when a request is sent, then it is refreshed first and the server never sees the stale token")
    func send_expired_refreshesBeforeSending() async throws {
        let refreshes = Counter()
        let service = StubNetworkService { request in
            .stub(for: request, status: self.bearer(request) == "Bearer new-1" ? 200 : 401)
        }
        let netti = makeNetti(service: service, interceptors: [makeInterceptor(refreshes: refreshes)])

        let status = try await netti.get(TestEndpoint()).statusCode

        #expect(status == 200)
        #expect(refreshes.value == 1)
        #expect(service.requests.map(bearer) == ["Bearer new-1"])
    }

    @Test("given an expired credential and 100 parallel requests, when they are sent, then one refresh runs and every request carries the new token")
    func send_expiredParallel_refreshesOnce() async throws {
        let refreshes = Counter()
        let service = StubNetworkService { request in
            .stub(for: request, status: self.bearer(request) == "Bearer new-1" ? 200 : 401)
        }
        let netti = makeNetti(
            service: service,
            interceptors: [makeInterceptor(refreshes: refreshes, refreshDelay: .milliseconds(100))],
            deduplicatesRequests: false
        )

        let statuses = try await withThrowingTaskGroup(of: Int?.self) { group in
            for _ in 0..<100 {
                group.addTask { try await netti.get(TestEndpoint()).statusCode }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(statuses == Array(repeating: 200 as Int?, count: 100))
        #expect(refreshes.value == 1)
        #expect(service.requests.count == 100)
        #expect(Set(service.requests.map(bearer)) == ["Bearer new-1"])
    }

    @Test("given a refresh started before sending, when a request signed earlier gets a 401, then it joins that refresh and retries")
    func retry_duringPreSendRefresh_joinsIt() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes, refreshDelay: .milliseconds(200))
        let signedEarlier = makeURLRequest(headers: ["Authorization": "Bearer old"])

        let adapting = Task { try await interceptor.adapt(makeURLRequest()) }
        await waitForRefreshToStart(refreshes)
        let decision = await interceptor.retry(makeContext(status: 401, request: signedEarlier))
        let adapted = try await adapting.value

        #expect(decision == .retry)
        #expect(refreshes.value == 1)
        #expect(bearer(adapted) == "Bearer new-1")
    }

    @Test("given a refresh in flight from a 401, when a request that is not expired is adapted meanwhile, then it goes out at once with the current credential")
    func adapt_duringRefresh_notExpired_doesNotWait() async throws {
        let refreshes = Counter()
        let gate = Gate()
        let interceptor = makeInterceptor(refreshes: refreshes, gate: gate)
        await interceptor.setCredential("current")
        let signed = makeURLRequest(headers: ["Authorization": "Bearer current"])

        let deciding = Task { await interceptor.retry(makeContext(status: 401, request: signed)) }
        await waitForRefreshToStart(refreshes)
        let adapted = try await interceptor.adapt(makeURLRequest())
        await gate.open()
        let decision = await deciding.value

        #expect(bearer(adapted) == "Bearer current")
        #expect(decision == .retry)
        #expect(refreshes.value == 1)
    }

    // MARK: - Failing refresh before sending

    @Test("given an expired credential and a failing refresh, when 20 requests are adapted at once, then all fail and one refresh was attempted")
    func adapt_refreshFails_allFailOneAttempt() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes, refreshDelay: .milliseconds(100), fails: true)

        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        _ = try await interceptor.adapt(makeURLRequest())
                        return false
                    } catch {
                        return error is RefreshFailure
                    }
                }
            }
            return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        }

        #expect(failures == 20)
        #expect(refreshes.value == 1)
    }

    @Test("given a failed refresh, when a later request is adapted and the credential is still expired, then a new refresh runs")
    func adapt_afterFailedRefresh_triesAgain() async throws {
        let refreshes = Counter()
        let interceptor = AuthenticationInterceptor(
            credential: Self.expired,
            isExpired: { $0 == Self.expired },
            apply: { token, request in request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") },
            refresh: { _ in
                if refreshes.increment() == 1 { throw RefreshFailure() }
                return "recovered"
            }
        )

        await #expect(throws: RefreshFailure.self) { try await interceptor.adapt(makeURLRequest()) }
        let adapted = try await interceptor.adapt(makeURLRequest())

        #expect(bearer(adapted) == "Bearer recovered")
        #expect(refreshes.value == 2)
    }

    // MARK: - Which response means "token expired"

    @Test("given a predicate on the body, when a 401 carries the expired code, then it refreshes and retries")
    func retry_predicateMatches_refreshes() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes, isRejected: Self.isTokenExpired)
        await interceptor.setCredential("current")

        let decision = await interceptor.retry(Self.context(status: 401, body: #"{"code":"TOKEN_EXPIRED"}"#))

        #expect(decision == .retry)
        #expect(refreshes.value == 1)
    }

    @Test("given a predicate on the body, when the expired code arrives inside a thrown error, then it refreshes and retries")
    func retry_predicateMatchesErrorBody_refreshes() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes, isRejected: Self.isTokenExpired)
        await interceptor.setCredential("current")
        let response = makeResponse(status: 401, body: Data(#"{"code":"TOKEN_EXPIRED"}"#.utf8))
        let context = RetryContext(
            request: makeURLRequest(headers: ["Authorization": "Bearer current"]),
            response: nil,
            error: .unacceptableStatusCode(401, response: response),
            retryCount: 0
        )

        #expect(await interceptor.retry(context) == .retry)
        #expect(refreshes.value == 1)
    }

    @Test("given a predicate on the body, when a 401 carries another code, then nothing refreshes and the 401 is returned as received")
    func retry_predicateDoesNotMatch_doesNothing() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes, isRejected: Self.isTokenExpired)
        await interceptor.setCredential("current")

        let decision = await interceptor.retry(Self.context(status: 401, body: #"{"code":"WRONG_PASSWORD"}"#))

        #expect(decision == .doNotRetry)
        #expect(refreshes.value == 0)
    }

    @Test("given a predicate for status 419, when a 419 arrives, then it refreshes, and a plain 401 does not")
    func retry_customStatus_refreshes() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes, isRejected: { $0.statusCode == 419 })
        await interceptor.setCredential("current")

        let plain401 = await interceptor.retry(Self.context(status: 401, body: ""))
        let expired419 = await interceptor.retry(Self.context(status: 419, body: ""))

        #expect(plain401 == .doNotRetry)
        #expect(expired419 == .retry)
        #expect(refreshes.value == 1)
    }

    // MARK: - Refresh through the same client

    @Test("given an expired credential and a refresh sent through the same client, when a request is sent, then it does not deadlock and carries the new token")
    func send_expiredRefreshThroughSameClient_doesNotDeadlock() async throws {
        let service = StubNetworkService { request in
            if request.url?.lastPathComponent == "refresh" {
                return try .json(for: request, Token(value: "fresh"))
            }
            return .stub(for: request, status: self.bearer(request) == "Bearer fresh" ? 200 : 401)
        }
        let box = ClientBox()
        let refreshEndpoint = TestEndpoint(path: "refresh")
        let auth = AuthenticationInterceptor(
            credential: Self.expired,
            isExpired: { $0 == Self.expired },
            apply: { token, request in request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") },
            refresh: { _ in
                guard let netti = box.netti else { throw RefreshFailure() }
                let response: HTTPResponse<Token> = try await netti.get(refreshEndpoint)
                guard let token = response.data?.value else { throw RefreshFailure() }
                return token
            }
        )
        let netti = makeNetti(service: service, interceptors: [auth])
        box.netti = netti

        let status = try await netti.get(TestEndpoint()).statusCode

        #expect(status == 200)
        let items = service.requests.filter { $0.url?.lastPathComponent == "items" }
        #expect(items.map(bearer) == ["Bearer fresh"])
        #expect(service.requests.filter { $0.url?.lastPathComponent == "refresh" }.count == 1)
    }

    // MARK: - Credential replaced during a refresh started before sending

    @Test("given a refresh started before sending, when the credential is set meanwhile, then its result is discarded and requests carry the set credential")
    func setCredential_duringPreSendRefresh_keepsNewCredential() async throws {
        let refreshes = Counter()
        let gate = Gate()
        let interceptor = makeInterceptor(refreshes: refreshes, gate: gate)

        let adapting = Task { try await interceptor.adapt(makeURLRequest()) }
        await waitForRefreshToStart(refreshes)
        await interceptor.setCredential("login")
        await gate.open()
        let duringRefresh = try await adapting.value
        let later = try await interceptor.adapt(makeURLRequest())

        #expect(bearer(duringRefresh) == "Bearer login")
        #expect(bearer(later) == "Bearer login")
        #expect(refreshes.value == 1)
    }

    @Test("given a failing refresh started before sending, when the credential is set meanwhile, then the waiter goes out with the set credential instead of failing")
    func setCredential_duringFailingPreSendRefresh_doesNotFailWaiter() async throws {
        let refreshes = Counter()
        let gate = Gate()
        let interceptor = makeInterceptor(refreshes: refreshes, fails: true, gate: gate)

        let adapting = Task { try await interceptor.adapt(makeURLRequest()) }
        await waitForRefreshToStart(refreshes)
        await interceptor.setCredential("login")
        await gate.open()

        #expect(bearer(try await adapting.value) == "Bearer login")
    }

    @Test("given a refresh started before sending, when the credential is set to another expired one, then the waiter refreshes it too instead of sending it")
    func setCredential_toExpiredCredential_isRefreshed() async throws {
        let refreshes = Counter()
        let gate = Gate()
        let interceptor = makeInterceptor(refreshes: refreshes, gate: gate)

        let adapting = Task { try await interceptor.adapt(makeURLRequest()) }
        await waitForRefreshToStart(refreshes)
        await interceptor.setCredential(Self.expired)
        await gate.open()
        let adapted = try await adapting.value

        #expect(bearer(adapted) == "Bearer new-2")
        #expect(refreshes.value == 2)
    }

    // MARK: - A refresh that returns an expired credential

    @Test("given a refresh that returns a credential that is still expired, when 5 requests are adapted one after another, then one refresh runs")
    func adapt_refreshReturnsExpired_refreshesOnce() async throws {
        let refreshes = Counter()
        let interceptor = AuthenticationInterceptor(
            credential: Self.expired,
            isExpired: { $0.hasPrefix("dead") || $0 == Self.expired },
            apply: { token, request in request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") },
            refresh: { _ in "dead-\(refreshes.increment())" }
        )

        var sent: [String?] = []
        for _ in 0..<5 {
            sent.append(bearer(try await interceptor.adapt(makeURLRequest())))
        }

        #expect(refreshes.value == 1)
        #expect(sent == Array(repeating: "Bearer dead-1", count: 5))
    }

    @Test("given a credential that was still expired after its refresh, when the server rejects it, then a 401 refreshes it again")
    func retry_afterRefreshReturnedExpired_stillRefreshes() async throws {
        let refreshes = Counter()
        let interceptor = AuthenticationInterceptor(
            credential: Self.expired,
            isExpired: { $0.hasPrefix("dead") || $0 == Self.expired },
            apply: { token, request in request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") },
            refresh: { _ in "dead-\(refreshes.increment())" }
        )
        let sent = try await interceptor.adapt(makeURLRequest())

        let decision = await interceptor.retry(makeContext(status: 401, request: sent))

        #expect(decision == .retry)
        #expect(refreshes.value == 2)
    }

    // MARK: - Another session (account switch)

    @Test("given a request signed for one account, when the credential is set to another before its 401 arrives, then it is not retried")
    func retry_credentialSetBefore401_doesNotRetry() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes)
        await interceptor.setCredential("account-A")
        let sentForA = try await interceptor.adapt(makeURLRequest())
        await interceptor.setCredential("account-B")

        let decision = await interceptor.retry(makeContext(status: 401, request: sentForA))

        #expect(bearer(sentForA) == "Bearer account-A")
        #expect(decision == .doNotRetry)
        #expect(refreshes.value == 0)
    }

    @Test("given a request signed before two refreshes of the same session, when its 401 arrives, then it is retried without refreshing again")
    func retry_signedBeforeEarlierRenewals_stillRetries() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes)
        await interceptor.setCredential("first")
        let signedWithFirst = try await interceptor.adapt(makeURLRequest())
        let signedForSecond = makeURLRequest(headers: ["Authorization": "Bearer new-1"])
        _ = await interceptor.retry(makeContext(status: 401, request: signedWithFirst))
        _ = await interceptor.retry(makeContext(status: 401, request: signedForSecond))

        let decision = await interceptor.retry(makeContext(status: 401, request: signedWithFirst))

        #expect(decision == .retry)
        #expect(refreshes.value == 2)
    }

    // MARK: - Cancellation

    @Test("given a request waiting for a refresh, when it is cancelled, then it fails with CancellationError and the refresh still completes")
    func adapt_cancelledWhileWaiting_throwsCancellation() async throws {
        let refreshes = Counter()
        let gate = Gate()
        let interceptor = makeInterceptor(refreshes: refreshes, gate: gate)

        let adapting = Task { try await interceptor.adapt(makeURLRequest()) }
        await waitForRefreshToStart(refreshes)
        adapting.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) { try await adapting.value }
        let later = try await interceptor.adapt(makeURLRequest())
        #expect(bearer(later) == "Bearer new-1")
        #expect(refreshes.value == 1)
    }

    // MARK: - Helpers

    /// The app's rule: a 401 whose JSON body says `TOKEN_EXPIRED`.
    private static let isTokenExpired: @Sendable (RetryContext) -> Bool = { context in
        guard context.statusCode == 401, let body = context.failureResponse?.rawData else {
            return false
        }
        return String(decoding: body, as: UTF8.self).contains("TOKEN_EXPIRED")
    }

    /// A failed attempt of a request signed with `current`, answered with `status` and `body`.
    private static func context(status: Int, body: String) -> RetryContext {
        let request = makeURLRequest(headers: ["Authorization": "Bearer current"])
        return RetryContext(
            request: request,
            response: makeResponse(status: status, body: Data(body.utf8), request: request),
            error: nil,
            retryCount: 0
        )
    }
}
