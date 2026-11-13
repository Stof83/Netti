import Foundation
import Testing

@testable import Netti
import NettiTesting

/// Endpoints passed to `excluding` (sign-in, sign-up, refresh) never receive the credential, never
/// wait for a refresh, and their `401` never refreshes: it means bad credentials, not an expired session.
@Suite("AuthenticationInterceptor excluding", .timeLimit(.minutes(1)))
struct AuthenticationExclusionTests {
    private enum AuthAPI: HTTPRequest {
        case signIn
        case signUp
        case refresh
        case profile
        case nilBase

        var baseURL: URL? {
            switch self {
            case .nilBase: nil
            default: URL(string: "https://api.example.com")
            }
        }

        var basePath: String { "v1" }

        var path: String {
            switch self {
            case .signIn: "auth/signin"
            case .signUp: "auth/signup"
            case .refresh: "auth/refresh"
            case .profile: "me/profile"
            case .nilBase: "auth/nil"
            }
        }

        var headers: HTTPHeaders { [:] }
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

    private static let signIn = "https://api.example.com/v1/auth/signin"

    /// An interceptor whose `old` credential is refreshed to `new-1`, `new-2`, …
    private func makeInterceptor(
        excluding: [any HTTPRequest] = [AuthAPI.signIn, AuthAPI.signUp, AuthAPI.refresh],
        refreshes: Counter = Counter()
    ) -> AuthenticationInterceptor<String> {
        AuthenticationInterceptor(bearerToken: "old", excluding: excluding) { _ in
            "new-\(refreshes.increment())"
        }
    }

    private func request(for endpoint: AuthAPI) throws -> URLRequest {
        try endpoint.asURLRequest(for: .get)
    }

    private func request(_ url: String, method: String = "GET") throws -> URLRequest {
        var request = URLRequest(url: try #require(URL(string: url)))
        request.httpMethod = method
        return request
    }

    private func authorization(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")
    }

    // MARK: - Excluded endpoint

    @Test("given an excluded endpoint, when it gets a 401, then it is not retried and nothing refreshes")
    func retry_excluded_doesNotRefresh() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes)
        let sent = try await interceptor.adapt(request(for: .signIn))

        let decision = await interceptor.retry(makeContext(status: 401, request: sent))

        #expect(decision == .doNotRetry)
        #expect(refreshes.value == 0)
    }

    @Test("given an excluded endpoint, when its request is adapted, then it carries no Authorization")
    func adapt_excluded_addsNoAuthorization() async throws {
        let original = try request(for: .signUp)

        let adapted = try await makeInterceptor().adapt(original)

        #expect(adapted == original)
        #expect(authorization(adapted) == nil)
    }

    @Test("given an expired credential whose refresh is running, when an excluded request is adapted, then it returns at once without waiting for the refresh")
    func adapt_excluded_doesNotWaitForRefresh() async throws {
        let refreshes = Counter()
        let gate = Gate()
        let interceptor = AuthenticationInterceptor<String>(
            credential: "old",
            excluding: [AuthAPI.refresh],
            isExpired: { $0 == "old" },
            apply: { token, request in request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") },
            refresh: { _ in
                let generation = refreshes.increment()
                await gate.wait()
                return "new-\(generation)"
            }
        )
        let profile = try request(for: .profile)
        let excluded = try request(for: .refresh)

        let signing = Task { try await interceptor.adapt(profile) }
        #expect(await eventually { refreshes.value >= 1 })
        let returned = Counter()
        let adaptingExcluded = Task {
            let adapted = try await interceptor.adapt(excluded)
            returned.increment()
            return adapted
        }
        let returnedWhileRefreshing = await eventually { returned.value == 1 }
        await gate.open()
        let adaptedExcluded = try await adaptingExcluded.value
        let adaptedProfile = try await signing.value

        #expect(returnedWhileRefreshing)
        #expect(authorization(adaptedExcluded) == nil)
        #expect(authorization(adaptedProfile) == "Bearer new-1")
        #expect(refreshes.value == 1)
    }

    // MARK: - Other endpoints

    @Test("given other endpoints on the same host, when a request is adapted, then it still carries the token")
    func adapt_notExcluded_stillSigns() async throws {
        let adapted = try await makeInterceptor().adapt(request(for: .profile))

        #expect(authorization(adapted) == "Bearer old")
    }

    @Test("given other endpoints on the same host, when a request gets a 401, then it refreshes once and is retried")
    func retry_notExcluded_refreshesOnce() async throws {
        let refreshes = Counter()
        let interceptor = makeInterceptor(refreshes: refreshes)
        let sent = try await interceptor.adapt(request(for: .profile))

        let decision = await interceptor.retry(makeContext(status: 401, request: sent))

        #expect(decision == .retry)
        #expect(refreshes.value == 1)
    }

    // MARK: - Matching

    @Test("given an excluded endpoint, when the request URL differs only by trailing slash, query, scheme or method, then it is still excluded", arguments: [
        "https://api.example.com/v1/auth/signin/",
        "https://api.example.com/v1/auth/signin?x=1",
        "https://api.example.com/v1/auth/signin/?x=1",
        "http://api.example.com/v1/auth/signin"
    ])
    func adapt_sameHostPortPath_isExcluded(url: String) async throws {
        let original = try request(url, method: "POST")

        let adapted = try await makeInterceptor().adapt(original)

        #expect(authorization(adapted) == nil)
    }

    @Test("given an excluded endpoint, when the request differs in port or path, then it is not excluded", arguments: [
        "https://api.example.com:8443/v1/auth/signin",
        "https://api.example.com/v1/auth/signin/extra",
        "https://api.example.com/v1/auth/sign",
        "https://api.example.com/auth/signin",
        "https://other.example.com/v1/auth/signin"
    ])
    func adapt_differentPortOrPath_isNotExcluded(url: String) async throws {
        let adapted = try await makeInterceptor().adapt(request(url))

        #expect(authorization(adapted) == "Bearer old")
    }

    @Test("given an excluded endpoint, when the request host has a different case, then it is still excluded", arguments: [
        "https://API.EXAMPLE.COM/v1/auth/signin",
        "https://Api.Example.Com/v1/auth/signin"
    ])
    func adapt_hostCase_isIgnored(url: String) async throws {
        let adapted = try await makeInterceptor().adapt(request(url))

        #expect(authorization(adapted) == nil)
    }

    // MARK: - Endpoint whose URL cannot be built

    @Test("given an excluded endpoint whose URL cannot be built, when another request is adapted, then it is signed and nothing crashes")
    func adapt_unbuildableEndpoint_excludesNothing() async throws {
        let adapted = try await makeInterceptor(excluding: [AuthAPI.nilBase]).adapt(request(for: .profile))

        #expect(authorization(adapted) == "Bearer old")
    }

    @Test("given an unbuildable endpoint listed before a valid one, when the valid one is requested, then it is still excluded")
    func adapt_unbuildableEndpointFirst_stillExcludesOthers() async throws {
        let adapted = try await makeInterceptor(excluding: [AuthAPI.nilBase, AuthAPI.signIn]).adapt(request(for: .signIn))

        #expect(authorization(adapted) == nil)
    }

    // MARK: - Bearer token convenience

    @Test("given the bearerToken initializer, when an excluded request is adapted, then it carries no Authorization")
    func bearerInit_forwardsExcluding() async throws {
        let interceptor = AuthenticationInterceptor(bearerToken: "old", excluding: [AuthAPI.signIn]) { _ in "new" }

        let adapted = try await interceptor.adapt(request(for: .signIn))

        #expect(authorization(adapted) == nil)
    }

    @Test("given the bearerToken initializer, when an excluded request gets a 401, then nothing refreshes")
    func bearerInit_excludedRetry_doesNotRefresh() async throws {
        let refreshes = Counter()
        let interceptor = AuthenticationInterceptor(bearerToken: "old", excluding: [AuthAPI.signIn]) { _ in
            "new-\(refreshes.increment())"
        }

        let signInRequest = try request(for: .signIn)

        let decision = await interceptor.retry(makeContext(status: 401, request: signInRequest))

        #expect(decision == .doNotRetry)
        #expect(refreshes.value == 0)
    }

    // MARK: - AuthToken initializer

    @Test("given the token initializer, when an excluded request is adapted, then it carries no Authorization")
    func tokenInit_excludedRequest_addsNoAuthorization() async throws {
        let interceptor = AuthenticationInterceptor(
            token: AuthToken(accessToken: "old", expiresAt: Date().addingTimeInterval(3600)),
            excluding: [AuthAPI.signIn]
        ) { $0 }
        let original = try request(for: .signIn)

        let adapted = try await interceptor.adapt(original)

        #expect(adapted == original)
        #expect(authorization(adapted) == nil)
    }

    @Test("given the token initializer and an expired token, when an excluded request is adapted, then no refresh runs, while another request still refreshes it")
    func tokenInit_expiredToken_excludedRequestDoesNotRefresh() async throws {
        let refreshes = Counter()
        let interceptor = AuthenticationInterceptor(
            token: AuthToken(accessToken: "old", expiresAt: Date().addingTimeInterval(-60)),
            excluding: [AuthAPI.signIn]
        ) { _ in
            AuthToken(accessToken: "new-\(refreshes.increment())", expiresAt: Date().addingTimeInterval(3600))
        }

        let excluded = try await interceptor.adapt(request(for: .signIn))
        let refreshesAfterExcluded = refreshes.value
        let profile = try await interceptor.adapt(request(for: .profile))

        #expect(authorization(excluded) == nil)
        #expect(refreshesAfterExcluded == 0)
        #expect(authorization(profile) == "Bearer new-1")
        #expect(refreshes.value == 1)
    }

    // MARK: - End to end

    @Test("given a sign-in endpoint that answers 401, when it is sent through the client, then the caller gets the 401 and no refresh runs")
    func send_excludedSignIn401_reachesCallerWithoutRefresh() async throws {
        let server = StubServer()
        let refreshes = Counter()
        server.stub(.post, Self.signIn, status: 401)
        let netti = server.netti(interceptors: [makeInterceptor(refreshes: refreshes)])

        let response: HTTPResponse<Empty> = try await netti.post(AuthAPI.signIn, body: Empty())

        #expect(response.statusCode == 401)
        #expect(refreshes.value == 0)
        let sent = server.requests.filter { $0.url?.path == "/v1/auth/signin" }
        #expect(sent.count == 1)
        #expect(sent.first?.headers["Authorization"] == nil)
    }

    @Test("given a sign-in that answers 401 and a profile call that answers 401 once, when both are sent, then only the profile call refreshes and retries")
    func send_signInAndProfile_onlyProfileRefreshes() async throws {
        let server = StubServer()
        let refreshes = Counter()
        server.stub(.post, Self.signIn, status: 401)
        // The newest matching stub wins, so the one-shot 401 goes last.
        server.stub(.get, "https://api.example.com/v1/me/profile", status: 200)
        server.stub(.get, "https://api.example.com/v1/me/profile", status: 401, times: 1)
        let netti = server.netti(interceptors: [makeInterceptor(refreshes: refreshes)])

        let signIn: HTTPResponse<Empty> = try await netti.post(AuthAPI.signIn, body: Empty())
        let profile: HTTPResponse<Empty> = try await netti.get(AuthAPI.profile)

        #expect(signIn.statusCode == 401)
        #expect(profile.statusCode == 200)
        #expect(refreshes.value == 1)
        let profileRequests = server.requests.filter { $0.url?.path == "/v1/me/profile" }
        #expect(profileRequests.map { $0.headers["Authorization"] } == ["Bearer old", "Bearer new-1"])
    }
}
