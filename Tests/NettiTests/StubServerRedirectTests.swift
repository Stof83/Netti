import Foundation
import Testing

import Netti
import NettiTesting

@Suite("StubServer redirects", .timeLimit(.minutes(1)))
struct StubServerRedirectTests {

    private struct Profile: Codable, Equatable, Sendable {
        let fullName: String
    }

    private let old = "https://api.test/v1/old"
    private let new = "https://api.test/v1/new"
    private let otherOrigin = "https://other.test/v1/new"

    private func endpoint(_ url: String, headers: HTTPHeaders = [:]) -> URLEndpoint {
        URLEndpoint(URL(string: url)!, headers: headers)
    }

    private func client(_ server: StubServer, redirectHandler: RedirectHandler?) -> Netti {
        let service = redirectHandler.map {
            URLSessionNetworkService(configuration: server.configuration, redirectHandler: $0)
        } ?? server.service()
        return Netti(service: service)
    }

    // MARK: - Following

    @Test("given a redirect stub, when followed, then the target answers and both requests are recorded")
    func redirect_isFollowedToTheTarget() async throws {
        let server = StubServer()
        server.redirect(.get, from: old, to: new)
        server.stub(.get, new, json: Profile(fullName: "Ada"))

        let response: HTTPResponse<Profile> = try await server.netti().get(endpoint(old))

        #expect(response.data == Profile(fullName: "Ada"))
        #expect(server.requests.map { $0.url?.absoluteString } == [old, new])
    }

    @Test("given a 301, 302, 303, 307 or 308, when followed, then each status is delivered as given")
    func redirect_carriesItsStatus() async throws {
        for status in [301, 302, 303, 307, 308] {
            let server = StubServer()
            server.redirect(.get, from: old, to: new, status: status)

            let response: HTTPResponse<Empty> = try await client(server, redirectHandler: .doNotFollow).get(endpoint(old))

            #expect(response.statusCode == status)
            #expect(response.response?.value(forHTTPHeaderField: "Location") == new)
        }
    }

    // MARK: - Handler decisions

    @Test("given .doNotFollow, when redirected, then the 302 is returned and the target is never requested")
    func doNotFollow_returnsTheRedirectResponse() async throws {
        let server = StubServer()
        server.redirect(.get, from: old, to: new)
        server.stub(.get, new, json: Profile(fullName: "Ada"))

        let response: HTTPResponse<Empty> = try await client(server, redirectHandler: .doNotFollow).get(endpoint(old))

        #expect(response.statusCode == 302)
        #expect(server.requests.count == 1)
    }

    @Test("given .secure, when redirected to another origin, then Cookie and Authorization are not sent there")
    func secure_stripsCredentialsCrossOrigin() async throws {
        let server = StubServer()
        server.redirect(.get, from: old, to: otherOrigin)
        server.stub(.get, otherOrigin, json: Profile(fullName: "Ada"))

        let _: HTTPResponse<Profile> = try await client(server, redirectHandler: .secure)
            .get(endpoint(old, headers: ["Authorization": "Bearer secret", "Cookie": "session=1"]))

        let requests = server.requests
        #expect(requests.count == 2)
        #expect(requests[0].headers["Cookie"] == "session=1")
        #expect(requests[1].headers["Cookie"] == nil)
        #expect(requests[1].headers["Authorization"] == nil)
    }

    @Test("given .follow, when redirected to another origin, then Cookie is sent there unchanged")
    func follow_keepsCookieCrossOrigin() async throws {
        let server = StubServer()
        server.redirect(.get, from: old, to: otherOrigin)
        server.stub(.get, otherOrigin, json: Profile(fullName: "Ada"))

        let _: HTTPResponse<Profile> = try await client(server, redirectHandler: .follow)
            .get(endpoint(old, headers: ["Cookie": "session=1"]))

        #expect(server.requests.last?.headers["Cookie"] == "session=1")
    }

    @Test("given .secure, when redirected on the same origin, then Authorization is kept")
    func secure_keepsAuthorizationSameOrigin() async throws {
        let server = StubServer()
        server.redirect(.get, from: old, to: new)
        server.stub(.get, new, json: Profile(fullName: "Ada"))

        let _: HTTPResponse<Profile> = try await client(server, redirectHandler: .secure)
            .get(endpoint(old, headers: ["Authorization": "Bearer secret"]))

        #expect(server.requests.last?.headers["Authorization"] == "Bearer secret")
    }

    @Test("given a custom handler, when it modifies the request, then the modified request is sent")
    func customHandler_modifiesTheRedirect() async throws {
        let server = StubServer()
        server.redirect(.get, from: old, to: new)
        server.stub(.get, new, json: Profile(fullName: "Ada"))
        let handler = RedirectHandler { proposed, _ in
            var request = proposed
            request.setValue("rewritten", forHTTPHeaderField: "X-Hop")
            return .modify(request)
        }

        let _: HTTPResponse<Profile> = try await client(server, redirectHandler: handler).get(endpoint(old))

        #expect(server.requests.last?.headers["X-Hop"] == "rewritten")
    }

    @Test("given a redirect loop, when followed, then the request fails instead of hanging")
    func redirectLoop_fails() async throws {
        let server = StubServer()
        server.redirect(.get, from: old, to: new)
        server.redirect(.get, from: new, to: old)

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await server.netti().get(endpoint(old))
        }

        #expect(error?.urlErrorCode == .httpTooManyRedirects)
    }
}
