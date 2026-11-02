import Foundation
import Testing

@testable import Netti
import NettiTesting

/// An endpoint that sets its own `Authorization` (for example HTTP Basic on a login call) must
/// keep it: the bearer interceptor neither overwrites it nor refreshes the token when it is rejected.
@Suite("AuthenticationInterceptor own Authorization", .timeLimit(.minutes(1)))
struct AuthenticationOwnAuthorizationTests {
    private let basic = "Basic dXNlcjpwYXNz"

    private func makeInterceptor(refreshes: Counter = Counter()) -> AuthenticationInterceptor<String> {
        AuthenticationInterceptor(bearerToken: "old") { _ in
            "new-\(refreshes.increment())"
        }
    }

    private func authorization(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")
    }

    @Test("given a request with its own Authorization, when adapted, then it is left unchanged")
    func adapt_keepsOwnAuthorization() async throws {
        let request = makeURLRequest(headers: ["Authorization": basic])

        let adapted = try await makeInterceptor().adapt(request)

        #expect(adapted == request)
        #expect(authorization(adapted) == basic)
    }

    @Test("given a request with its own Authorization, when it gets a 401, then no refresh runs and it is not retried")
    func retry_ownAuthorization_doesNotRefresh() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes)
        let sent = try await interceptor.adapt(makeURLRequest(headers: ["Authorization": basic]))

        let decision = await interceptor.retry(makeContext(status: 401, request: sent))

        #expect(decision == .doNotRetry)
        #expect(refreshes.value == 0)
    }

    @Test("given a request without Authorization, when adapted, then it still carries the bearer token")
    func adapt_withoutAuthorization_stillSigns() async throws {
        let adapted = try await makeInterceptor().adapt(makeURLRequest())

        #expect(authorization(adapted) == "Bearer old")
    }

    @Test("given a request whose Authorization was ours, when it gets a 401, then it still refreshes")
    func retry_ownBearer_stillRefreshes() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes)
        let sent = try await interceptor.adapt(makeURLRequest())

        let decision = await interceptor.retry(makeContext(status: 401, request: sent))

        #expect(decision == .retry)
        #expect(refreshes.value == 1)
    }

    @Test("given a login with Basic and a normal call, when both get a 401, then only the normal call refreshes the token")
    func endToEnd_basicLoginAndBearerCall() async throws {
        let server = StubServer()
        let refreshes = Counter()
        server.stub(.post, "https://api.test/v1/login", status: 401)
        // The newest matching stub wins, so the one-shot 401 goes last.
        server.stub(.get, "https://api.test/v1/items", status: 200)
        server.stub(.get, "https://api.test/v1/items", status: 401, times: 1)
        let netti = server.netti(interceptors: [makeInterceptor(refreshes: refreshes)])

        let login = URLEndpoint(URL(string: "https://api.test/v1/login")!, headers: ["Authorization": basic])
        let loginResponse: HTTPResponse<Empty> = try await netti.post(login, body: Empty())
        let items: HTTPResponse<Empty> = try await netti.get(TestEndpoint())

        #expect(loginResponse.statusCode == 401)
        #expect(items.statusCode == 200)
        #expect(refreshes.value == 1)
        let loginRequests = server.requests.filter { $0.url?.path == "/v1/login" }
        #expect(loginRequests.count == 1)
        #expect(loginRequests.first?.headers["Authorization"] == basic)
    }

    @Test("given a refresh in flight, when a request with its own Authorization gets a 401, then it joins nothing and is not retried")
    func retry_ownAuthorization_duringRefresh_isNotRetried() async throws {
        let refreshes = Counter()
        let interceptor = AuthenticationInterceptor(bearerToken: "old") { _ in
            let generation = refreshes.increment()
            try await Task.sleep(for: .milliseconds(300))
            return "new-\(generation)"
        }
        let signed = try await interceptor.adapt(makeURLRequest())
        let own = try await interceptor.adapt(makeURLRequest(headers: ["Authorization": basic]))

        async let started = interceptor.retry(makeContext(status: 401, request: signed))
        try await Task.sleep(for: .milliseconds(50))
        let decision = await interceptor.retry(makeContext(status: 401, request: own))

        #expect(decision == .doNotRetry)
        #expect(await started == .retry)
        #expect(refreshes.value == 1)
    }

    @Test("given a credential that writes another header, when the request has an Authorization, then it is still signed")
    func adapt_nonAuthorizationCredential_stillSigns() async throws {
        let interceptor = AuthenticationInterceptor(
            credential: "key-1",
            apply: { key, request in request.setValue(key, forHTTPHeaderField: "X-API-Key") },
            refresh: { _ in "key-2" }
        )
        let request = makeURLRequest(headers: ["Authorization": basic])

        let adapted = try await interceptor.adapt(request)

        #expect(adapted.value(forHTTPHeaderField: "X-API-Key") == "key-1")
        #expect(authorization(adapted) == basic)
    }
}
