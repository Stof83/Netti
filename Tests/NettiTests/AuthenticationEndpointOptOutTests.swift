import Foundation
import Testing

@testable import Netti
import NettiTesting

/// An endpoint whose ``HTTPRequest/requiresAuthentication`` is `false` opts out of
/// ``AuthenticationInterceptor`` from its own module, with no list in the app: it never receives
/// the credential, never waits for a refresh, and its `401` never refreshes.
@Suite("AuthenticationInterceptor endpoint opt-out", .timeLimit(.minutes(1)))
struct AuthenticationEndpointOptOutTests {
    /// Stands in for an endpoint enum internal to a feature module.
    private enum SignInAPI: HTTPRequest {
        case signIn
        case me

        var baseURL: URL? { URL(string: "https://api.example.com") }
        var basePath: String { "v1" }

        var path: String {
            switch self {
                case .signIn: "auth/signin"
                case .me: "me"
            }
        }

        var headers: HTTPHeaders { [:] }

        var requiresAuthentication: Bool { self == .me }
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

    /// An interceptor whose `old` token is refreshed to `new-1`, `new-2`, …
    private func makeInterceptor(refreshes: Counter = Counter()) -> AuthenticationInterceptor<String> {
        AuthenticationInterceptor(bearerToken: "old") { _ in
            "new-\(refreshes.increment())"
        }
    }

    /// A transport that answers `401` to every request carrying `Bearer old` or no credential.
    private func makeService(signInStatus: Int = 401) -> StubNetworkService {
        StubNetworkService(data: { request in
            if request.url?.path == "/v1/auth/signin" {
                return .stub(for: request, status: signInStatus)
            }
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            return .stub(for: request, status: authorization == "Bearer old" || authorization == nil ? 401 : 200)
        })
    }

    private func authorizations(_ requests: [URLRequest]) -> [String?] {
        requests.map { $0.value(forHTTPHeaderField: "Authorization") }
    }

    // MARK: - Opted-out endpoint

    @Test("given an endpoint that does not require authentication, when it answers 401, then the caller gets the 401 unsigned and nothing refreshes")
    func send_optedOut401_reachesCallerWithoutRefresh() async throws {
        let service = makeService()
        let refreshes = Counter()
        let netti = makeNetti(service: service, interceptors: [makeInterceptor(refreshes: refreshes)])

        let response: HTTPResponse<Empty> = try await netti.post(SignInAPI.signIn, body: Empty())

        #expect(response.statusCode == 401)
        #expect(refreshes.value == 0)
        #expect(authorizations(service.requests) == [nil])
    }

    @Test("given an expired credential whose refresh is running, when an opted-out endpoint is sent, then it completes without waiting for the refresh")
    func send_optedOut_doesNotWaitForRefresh() async throws {
        let service = makeService(signInStatus: 200)
        let refreshes = Counter()
        let gate = Gate()
        let interceptor = AuthenticationInterceptor<String>(
            credential: "old",
            isExpired: { $0 == "old" },
            apply: { token, request in request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") },
            refresh: { _ in
                let generation = refreshes.increment()
                await gate.wait()
                return "new-\(generation)"
            }
        )
        let netti = makeNetti(service: service, interceptors: [interceptor])

        let profile = Task { () async throws -> HTTPResponse<Empty> in try await netti.get(SignInAPI.me) }
        #expect(await eventually { refreshes.value >= 1 })
        let returned = Counter()
        let signIn = Task { () async throws -> HTTPResponse<Empty> in
            let response: HTTPResponse<Empty> = try await netti.post(SignInAPI.signIn, body: Empty())
            returned.increment()
            return response
        }
        let returnedWhileRefreshing = await eventually { returned.value == 1 }
        await gate.open()
        let signInResponse = try await signIn.value
        let profileResponse = try await profile.value

        #expect(returnedWhileRefreshing)
        #expect(signInResponse.request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(profileResponse.statusCode == 200)
        #expect(refreshes.value == 1)
    }

    @Test("given an opted-out endpoint, when it is uploaded, downloaded, streamed or opened as a WebSocket, then no request carries Authorization")
    func transfers_optedOut_carryNoAuthorization() async throws {
        let service = makeService(signInStatus: 200)
        let netti = makeNetti(service: service, interceptors: [makeInterceptor()])

        try await netti.upload(SignInAPI.signIn, data: Data("x".utf8))
        // The stub fails downloads and streams by default; only the request it recorded matters here.
        _ = try? await netti.download(SignInAPI.signIn)
        _ = try? await netti.stream(SignInAPI.signIn)
        _ = try await netti.webSocket(SignInAPI.signIn)

        #expect(service.requests.count == 3)
        #expect(authorizations(service.requests) == [nil, nil, nil])
        #expect(authorizations(service.webSocketRequests) == [nil])
    }

    // MARK: - Other endpoints

    @Test("given an endpoint of the same enum that requires authentication, when it answers 401, then it refreshes once and is retried")
    func send_optedIn401_refreshesOnce() async throws {
        let service = makeService()
        let refreshes = Counter()
        let netti = makeNetti(service: service, interceptors: [makeInterceptor(refreshes: refreshes)])

        let response: HTTPResponse<Empty> = try await netti.get(SignInAPI.me)

        #expect(response.statusCode == 200)
        #expect(refreshes.value == 1)
        #expect(authorizations(service.requests) == ["Bearer old", "Bearer new-1"])
    }

    @Test("given a prebuilt URLRequest for an opted-out endpoint's URL, when it is sent, then it is signed, since it has no endpoint")
    func send_rawRequest_isSigned() async throws {
        let service = makeService(signInStatus: 200)
        let netti = makeNetti(service: service, interceptors: [makeInterceptor()])

        try await netti.send(SignInAPI.signIn.asURLRequest(for: .post))

        #expect(authorizations(service.requests) == ["Bearer old"])
    }

    @Test("given a prebuilt URLRequest sent while an opted-out endpoint's scope is active, when it is sent, then it is signed, not opted out by inheritance")
    func send_rawRequestInsideOptedOutScope_isSigned() async throws {
        let service = makeService(signInStatus: 200)
        let netti = makeNetti(service: service, interceptors: [makeInterceptor()])
        let request = try SignInAPI.signIn.asURLRequest(for: .post)

        try await EndpointScope.$requiresAuthentication.withValue(false) {
            try await netti.send(request)
        }

        #expect(authorizations(service.requests) == ["Bearer old"])
    }

    @Test("given the interceptor used outside a client, when a request is adapted, then it is signed")
    func adapt_outsideClient_isSigned() async throws {
        let adapted = try await makeInterceptor().adapt(SignInAPI.signIn.asURLRequest(for: .post))

        #expect(adapted.value(forHTTPHeaderField: "Authorization") == "Bearer old")
    }
}
