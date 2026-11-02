import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

@Suite("AuthenticationInterceptor", .timeLimit(.minutes(1)))
struct AuthenticationInterceptorTests {
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

    /// Holds each refresh, keyed by the rejected credential, until the test releases it.
    ///
    /// Waits poll with `Task.sleep`, so a test that never reaches a gate fails at its time limit
    /// instead of hanging the run.
    private actor RefreshGate {
        private var entered: Set<String> = []
        private var released: Set<String> = []

        func enter(_ key: String) async {
            entered.insert(key)
            while released.contains(key) == false, Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        func waitUntilEntered(_ key: String) async {
            while entered.contains(key) == false, Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        func release(_ key: String) {
            released.insert(key)
        }
    }

    private let refreshEndpoint = TestEndpoint(path: "refresh")

    private func makeInterceptor(
        token: String = "old",
        refreshes: Counter = Counter(),
        refreshDelay: Duration = .milliseconds(50),
        fails: Bool = false
    ) -> AuthenticationInterceptor<String> {
        AuthenticationInterceptor(bearerToken: token) { _ in
            let generation = refreshes.increment()
            try await Task.sleep(for: refreshDelay)
            if fails { throw RefreshFailure() }
            return "new-\(generation)"
        }
    }

    private func bearer(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")
    }

    @Test("given a credential, when a request is adapted, then it carries the bearer token")
    func adapt_attachesCredential() async throws {
        let adapted = try await makeInterceptor().adapt(makeURLRequest())

        #expect(bearer(adapted) == "Bearer old")
    }

    @Test("given a 401, when the request used the current credential, then it refreshes and retries")
    func retry_401_refreshesAndRetries() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes)
        let sent = try await interceptor.adapt(makeURLRequest())

        let decision = await interceptor.retry(makeContext(status: 401, request: sent))
        let resent = try await interceptor.adapt(makeURLRequest())

        #expect(decision == .retry)
        #expect(refreshes.value == 1)
        #expect(bearer(resent) == "Bearer new-1")
    }

    @Test("given 5 concurrent 401s, when they are decided, then the credential refreshes exactly once and all retry")
    func retry_concurrent401s_refreshOnce() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes, refreshDelay: .milliseconds(200))
        let sent = try await interceptor.adapt(makeURLRequest())

        let decisions = await withTaskGroup(of: RetryDecision.self) { group in
            for _ in 0..<5 {
                group.addTask { await interceptor.retry(makeContext(status: 401, request: sent)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let resent = try await interceptor.adapt(makeURLRequest())

        #expect(refreshes.value == 1)
        #expect(decisions == Array(repeating: .retry, count: 5))
        #expect(bearer(resent) == "Bearer new-1")
    }

    @Test("given a 401 for a request signed before a refresh, when decided, then it retries without refreshing again")
    func retry_staleCredential_retriesWithoutRefresh() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes)
        let sentBeforeRefresh = try await interceptor.adapt(makeURLRequest())
        _ = await interceptor.retry(makeContext(status: 401, request: sentBeforeRefresh))

        let decision = await interceptor.retry(makeContext(status: 401, request: sentBeforeRefresh))

        #expect(decision == .retry)
        #expect(refreshes.value == 1)
    }

    @Test("given a failing refresh, when concurrent 401s are decided, then none retries and one refresh was attempted")
    func retry_refreshFails_noneRetries() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes, refreshDelay: .milliseconds(200), fails: true)
        let sent = try await interceptor.adapt(makeURLRequest())

        let decisions = await withTaskGroup(of: RetryDecision.self) { group in
            for _ in 0..<5 {
                group.addTask { await interceptor.retry(makeContext(status: 401, request: sent)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(refreshes.value == 1)
        #expect(decisions == Array(repeating: .doNotRetry, count: 5))
    }

    @Test("given a failed refresh, when a later request gets a 401, then a new refresh may run")
    func retry_afterFailedRefresh_canRefreshAgain() async throws {
        let refreshes = Counter()
        let interceptor = AuthenticationInterceptor(bearerToken: "old") { _ in
            if refreshes.increment() == 1 { throw RefreshFailure() }
            return "recovered"
        }
        let sent = try await interceptor.adapt(makeURLRequest())

        let first = await interceptor.retry(makeContext(status: 401, request: sent))
        let second = await interceptor.retry(makeContext(status: 401, request: sent))

        #expect(first == .doNotRetry)
        #expect(second == .retry)
        #expect(refreshes.value == 2)
    }

    @Test("given a request already retried, when it gets a 401 again, then it is not retried")
    func retry_alreadyRetried_doesNotRetry() async throws {
        let interceptor = makeInterceptor()
        let sent = try await interceptor.adapt(makeURLRequest())

        let decision = await interceptor.retry(makeContext(status: 401, retryCount: 1, request: sent))

        #expect(decision == .doNotRetry)
    }

    @Test(
        "given a failure other than 401, when decided, then it is not retried and nothing refreshes",
        arguments: [200, 403, 404, 500]
    )
    func retry_otherStatus_doesNothing(status: Int) async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes)

        let decision = await interceptor.retry(makeContext(status: status))

        #expect(decision == .doNotRetry)
        #expect(refreshes.value == 0)
    }

    @Test("given a 401 carried by a thrown error, when decided, then it is treated like a returned 401")
    func retry_401InError_refreshes() async throws {
        let interceptor = makeInterceptor()
        let sent = try await interceptor.adapt(makeURLRequest())
        let error = HTTPRequestError.unacceptableStatusCode(401, response: makeResponse(status: 401))

        let decision = await interceptor.retry(makeContext(error: error, request: sent))

        #expect(decision == .retry)
    }

    @Test("given a replaced credential, when a request is adapted, then it uses the new one")
    func setCredential_replacesCredential() async throws {
        let interceptor = makeInterceptor()

        await interceptor.setCredential("login")
        let adapted = try await interceptor.adapt(makeURLRequest())

        #expect(bearer(adapted) == "Bearer login")
    }

    // MARK: - Credential Replaced During A Refresh (TM-36)

    @Test("given a slow refresh of A, when the credential is set to B meanwhile, then later requests carry B and the waiters do not retry")
    func setCredential_duringRefresh_keepsNewCredential() async throws {
        let gate = RefreshGate()
        let interceptor = AuthenticationInterceptor(bearerToken: "A") { rejected in
            await gate.enter(rejected)
            return "\(rejected)-renewed"
        }
        let sent = try await interceptor.adapt(makeURLRequest())

        let waiters = (0..<2).map { _ in Task { await interceptor.retry(makeContext(status: 401, request: sent)) } }
        await gate.waitUntilEntered("A")
        await interceptor.setCredential("B")
        await gate.release("A")
        var decisions: [RetryDecision] = []
        for waiter in waiters {
            decisions.append(await waiter.value)
        }
        let later = try await interceptor.adapt(makeURLRequest())

        #expect(decisions == [.doNotRetry, .doNotRetry])
        #expect(bearer(later) == "Bearer B")
    }

    @Test("given a refresh of A superseded by B, when B is rejected, then B refreshes on its own and A's result never applies")
    func setCredential_duringRefresh_laterRefreshUsesNewCredential() async throws {
        let gate = RefreshGate()
        let interceptor = AuthenticationInterceptor(bearerToken: "A") { rejected in
            await gate.enter(rejected)
            return "\(rejected)-renewed"
        }
        let sentA = try await interceptor.adapt(makeURLRequest())
        let waiterA = Task { await interceptor.retry(makeContext(status: 401, request: sentA)) }
        await gate.waitUntilEntered("A")
        await interceptor.setCredential("B")

        let sentB = try await interceptor.adapt(makeURLRequest())
        let waiterB = Task { await interceptor.retry(makeContext(status: 401, request: sentB)) }
        await gate.waitUntilEntered("B")
        await gate.release("A")
        let decisionA = await waiterA.value
        let duringB = try await interceptor.adapt(makeURLRequest())
        await gate.release("B")
        let decisionB = await waiterB.value
        let afterB = try await interceptor.adapt(makeURLRequest())

        #expect(bearer(sentB) == "Bearer B")
        #expect(decisionA == .doNotRetry)
        #expect(bearer(duringB) == "Bearer B")
        #expect(decisionB == .retry)
        #expect(bearer(afterB) == "Bearer B-renewed")
    }

    // MARK: - Refresh through the same client

    @Test("given a refresh sent through the same client, when the refresh answers 401, then the original call returns its 401 instead of hanging")
    func refreshThroughSameClient_refresh401_returnsOriginal401() async throws {
        let service = StubNetworkService { .stub(for: $0, status: 401) }
        let netti = makeSelfRefreshingNetti(service: service)

        let status = await value(within: .seconds(2)) {
            try await netti.get(TestEndpoint()).statusCode
        }

        #expect(status == 401)
        #expect(refreshRequests(in: service) == 1)
    }

    @Test("given a refresh sent through the same client, when the refresh succeeds, then the original request is retried once with the new token")
    func refreshThroughSameClient_refreshSucceeds_retriesWithNewToken() async throws {
        let service = makeTokenService()
        let netti = makeSelfRefreshingNetti(service: service)

        let status = await value(within: .seconds(2)) {
            try await netti.get(TestEndpoint()).statusCode
        }

        #expect(status == 200)
        #expect(refreshRequests(in: service) == 1)
        #expect(itemRequests(in: service).map(bearer) == ["Bearer old", "Bearer fresh"])
    }

    @Test("given 5 concurrent 401s and a refresh through the same client, when they are sent, then one refresh is sent and all succeed")
    func refreshThroughSameClient_concurrent401s_refreshOnce() async throws {
        let service = makeTokenService(refreshDelay: .milliseconds(100))
        let netti = makeSelfRefreshingNetti(service: service, deduplicatesRequests: false)

        let statuses = await value(within: .seconds(2)) {
            try await withThrowingTaskGroup(of: Int?.self) { group in
                for _ in 0..<5 {
                    group.addTask { try await netti.get(TestEndpoint()).statusCode }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
        }

        #expect(statuses == Array(repeating: 200 as Int?, count: 5))
        #expect(refreshRequests(in: service) == 1)
    }

    // MARK: - Helpers

    /// A client whose interceptor refreshes by sending ``refreshEndpoint`` through that same client.
    private func makeSelfRefreshingNetti(service: StubNetworkService, deduplicatesRequests: Bool = true) -> Netti {
        let box = ClientBox()
        let refreshEndpoint = refreshEndpoint
        let auth = AuthenticationInterceptor(bearerToken: "old") { _ in
            guard let netti = box.netti else { throw RefreshFailure() }
            let response: HTTPResponse<Token> = try await netti.get(refreshEndpoint)
            guard response.statusCode == 200, let token = response.data?.value else { throw RefreshFailure() }
            return token
        }
        let netti = makeNetti(service: service, interceptors: [auth], deduplicatesRequests: deduplicatesRequests)
        box.netti = netti
        return netti
    }

    /// A server that issues `fresh` on the refresh path and accepts only `Bearer fresh` elsewhere.
    private func makeTokenService(refreshDelay: Duration = .zero) -> StubNetworkService {
        StubNetworkService { request in
            if request.url?.lastPathComponent == "refresh" {
                try await Task.sleep(for: refreshDelay)
                return try .json(for: request, Token(value: "fresh"))
            }
            let isFresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
            return .stub(for: request, status: isFresh ? 200 : 401)
        }
    }

    private func refreshRequests(in service: StubNetworkService) -> Int {
        service.requests.filter { $0.url?.lastPathComponent == "refresh" }.count
    }

    private func itemRequests(in service: StubNetworkService) -> [URLRequest] {
        service.requests.filter { $0.url?.lastPathComponent == "items" }
    }

    /// Runs `operation`, giving up after `limit` so a deadlock fails the test instead of hanging it.
    ///
    /// - Returns: The operation's value; `nil` when it throws or does not finish within `limit`.
    private func value<T: Sendable>(
        within limit: Duration,
        of operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let (results, continuation) = AsyncStream.makeStream(of: T?.self)
        Task { continuation.yield(try? await operation()) }
        let timer = Task {
            try? await Task.sleep(for: limit)
            continuation.yield(nil)
        }
        var iterator = results.makeAsyncIterator()
        let first = await iterator.next() ?? nil
        timer.cancel()
        continuation.finish()
        return first
    }

    // MARK: - Host Scope (TM-12)

    @Test("given hosts, when requests are adapted, then only listed hosts get the token, case-insensitively")
    func hosts_attachOnlyToListedHosts() async throws {
        let interceptor = AuthenticationInterceptor(bearerToken: "old", hosts: ["API.example.com"]) { _ in "new" }
        let listed = URLRequest(url: try #require(URL(string: "https://api.example.com/me")))
        let presigned = URLRequest(url: try #require(URL(string: "https://bucket.s3.amazonaws.com/upload?X-Amz-Signature=abc")))
        let lookalike = URLRequest(url: try #require(URL(string: "https://api.example.com.evil.test/me")))

        #expect(bearer(try await interceptor.adapt(listed)) == "Bearer old")
        #expect(bearer(try await interceptor.adapt(presigned)) == nil)
        #expect(bearer(try await interceptor.adapt(lookalike)) == nil)
    }

    @Test("given no hosts, when a request to any host is adapted, then it carries the token")
    func hostsNil_attachesEverywhere() async throws {
        let interceptor = makeInterceptor()
        let other = URLRequest(url: try #require(URL(string: "https://cdn.other.test/file")))

        #expect(bearer(try await interceptor.adapt(other)) == "Bearer old")
    }

    @Test("given hosts, when an unlisted host answers 401, then nothing is refreshed or retried")
    func hosts_unlisted401_doesNotRefresh() async throws {
        let refreshes = Counter()
        let interceptor = AuthenticationInterceptor(bearerToken: "old", hosts: ["api.example.com"]) { _ in
            refreshes.increment()
            return "new"
        }
        let presigned = URLRequest(url: try #require(URL(string: "https://bucket.s3.amazonaws.com/upload")))

        let decision = await interceptor.retry(makeContext(status: 401, request: try await interceptor.adapt(presigned)))

        #expect(decision == .doNotRetry)
        #expect(refreshes.value == 0)
    }

    @Test("given hosts, when a listed host answers 401, then the credential is refreshed and the request retried")
    func hosts_listed401_refreshes() async throws {
        let refreshes = Counter()
        let interceptor = AuthenticationInterceptor(
            credential: "old",
            hosts: ["api.test"],
            apply: { key, request in request.setValue(key, forHTTPHeaderField: "X-Api-Key") },
            refresh: { _ in
                refreshes.increment()
                return "new"
            }
        )

        let decision = await interceptor.retry(makeContext(status: 401, request: try await interceptor.adapt(makeURLRequest())))

        #expect(decision == .retry)
        #expect(refreshes.value == 1)
    }

    @Test("given hosts and a client, when a request goes to a third-party host, then no credential reaches the transport")
    func hosts_throughClient_thirdPartyGetsNoToken() async throws {
        let service = StubNetworkService()
        let interceptor = AuthenticationInterceptor(bearerToken: "secret", hosts: ["api.test"]) { _ in "new" }
        let netti = makeNetti(service: service, interceptors: [interceptor])

        try await netti.get(TestEndpoint())
        try await netti.send(URLRequest(url: try #require(URL(string: "https://storage.other.test/object"))))

        #expect(service.requests.map(bearer) == ["Bearer secret", nil])
    }
}
