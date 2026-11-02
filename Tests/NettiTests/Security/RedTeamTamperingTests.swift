//
//  RedTeamTamperingTests.swift
//  Netti
//

import Foundation
import Testing

@testable import Netti
import NettiTesting

/// S.12 red team, tampering: a response body altered in transit fails with `decodingFailed` and
/// never yields a partially filled model, and a header an adapter tries to inject is rejected with
/// `encodingFailed` before anything is sent.
@Suite("Red team: tampering", .timeLimit(.minutes(1)))
struct RedTeamTamperingTests {

    // MARK: - Types

    private struct Account: Codable, Equatable, Sendable {
        let id: Int
        let owner: String
        let balance: Decimal
        let isAdmin: Bool
    }

    // MARK: - Constants

    private static let tamperedAccounts: [String] = [
        #"{"id":1,"owner":"ada","balance":10.5,"isAdmin":fal"#,
        #"{"id":1,"owner":"ada","balance":10.5}"#,
        #"{"id":"1","owner":"ada","balance":10.5,"isAdmin":false}"#,
        #"{"id":1,"owner":null,"balance":10.5,"isAdmin":false}"#,
        #"{"id":1,"owner":"ada","balance":"1e400","isAdmin":false}"#,
        #"{"id":1,"owner":"ada","balance":10.5,"isAdmin":"true"}"#,
        #"{"id":1.5,"owner":"ada","balance":10.5,"isAdmin":false}"#,
        #"{"id":99999999999999999999,"owner":"ada","balance":10.5,"isAdmin":false}"#,
        #"[{"id":1,"owner":"ada","balance":10.5,"isAdmin":false}]"#,
        "<html>login</html>",
        "",
        "\u{FEFF}\u{0}",
    ]

    private static let tamperedLists: [String] = [
        #"[{"id":1,"owner":"ada","balance":1,"isAdmin":false},{"id":2,"owner":"bob","balance":1,"isAdmin":"yes"}]"#,
        #"[{"id":1,"owner":"ada","balance":1,"isAdmin":false},{"id":2}]"#,
        #"[{"id":1,"owner":"ada","balance":1,"isAdmin":false},"#,
    ]

    private static let injectedHeaders: [(String, String)] = [
        ("Authorization", "Bearer t\u{0}X-Admin: 1"),
        ("X-Trace\r\nX-Admin", "1"),
        ("X-Trace\nHost", "evil.test"),
        ("X-Trace\u{0}", "1"),
    ]

    // MARK: - Body Tampering

    @Test("given a tampered response body, when decoded as a model, then decodingFailed is thrown", arguments: tamperedAccounts)
    func tamperedBody_decodingFailed(body: String) async {
        let netti = makeNetti(service: StubNetworkService { .stub(for: $0, headers: ["Content-Type": "application/json"], body: Data(body.utf8)) })

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Account> in
            try await netti.get(TestEndpoint())
        }

        #expect(error?.isDecodingFailure == true, "\(String(describing: error))")
    }

    @Test("given a list with one tampered element, when decoded, then decodingFailed is thrown instead of the valid prefix", arguments: tamperedLists)
    func tamperedList_noPartialModel(body: String) async {
        let netti = makeNetti(service: StubNetworkService { .stub(for: $0, body: Data(body.utf8)) })

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<[Account]> in
            try await netti.get(TestEndpoint())
        }

        #expect(error?.isDecodingFailure == true, "\(String(describing: error))")
    }

    @Test("given an intact body, when decoded, then the model is complete (control)")
    func intactBody_decodes() async throws {
        let account = Account(id: 1, owner: "ada", balance: 10.5, isAdmin: false)
        let netti = makeNetti(service: StubNetworkService { try .json(for: $0, account) })

        let response: HTTPResponse<Account> = try await netti.get(TestEndpoint())

        #expect(response.data == account)
    }

    // MARK: - Header Injection

    @Test("given an adapter that injects CR, LF or NUL into a header, when sent, then encodingFailed is thrown and nothing is sent", arguments: injectedHeaders)
    func adapterInjection_rejected(name: String, value: String) async {
        let service = StubNetworkService()
        let monitor = RedTeamFailureMonitor()
        let adapter = ClosureAdapter { request in
            var request = request
            var fields = request.allHTTPHeaderFields ?? [:]
            fields[name] = value
            request.allHTTPHeaderFields = fields
            return request
        }
        let netti = makeNetti(service: service, interceptors: [adapter], monitors: [monitor])

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }

        #expect(error?.isEncodingFailure == true, "\(String(describing: error))")
        #expect(service.requests.isEmpty)
        #expect(monitor.sent.values.isEmpty)
        #expect(monitor.failures.values.count == 1)
    }

    /// `URLRequest` drops a header value holding CR or LF as soon as an adapter sets it, so Netti
    /// never sees it: the injection is neutralised, but the request goes out without the header.
    @Test("given an adapter that sets a header value with CR or LF, when sent, then no injected header reaches the transport", arguments: ["Bearer t\r\nX-Admin: 1", "Bearer t\nX-Admin: 1", "Bearer t\rX-Admin: 1"])
    func adapterLineBreakValue_neutralised(value: String) async {
        let service = StubNetworkService()
        let adapter = ClosureAdapter { request in
            var request = request
            request.setValue(value, forHTTPHeaderField: "Authorization")
            return request
        }
        let netti = makeNetti(service: service, interceptors: [adapter])

        var error: HTTPRequestError?
        do {
            let _: HTTPResponse<Empty> = try await netti.get(TestEndpoint())
        } catch let thrown {
            error = thrown
        }

        for request in service.requests {
            let fields = request.allHTTPHeaderFields ?? [:]
            #expect(fields.keys.contains { $0.lowercased() == "x-admin" } == false)
            #expect(fields.values.allSatisfy { $0.contains("\r") == false && $0.contains("\n") == false })
        }
        withKnownIssue("TM-red-9: a CR/LF header value set by an adapter is silently dropped by URLRequest, so the request is sent without it instead of failing with encodingFailed") {
            #expect(error?.isEncodingFailure == true)
            #expect(service.requests.isEmpty)
        }
    }

    @Test("given a refresh that returns a token holding NUL, when the request is retried, then encodingFailed is thrown and only the first attempt was sent")
    func refreshedTokenInjection_rejectedOnRetry() async {
        let service = StubNetworkService { .stub(for: $0, status: 401) }
        let interceptor = AuthenticationInterceptor(bearerToken: "stale") { _ in "fresh\u{0}X-Admin: 1" }
        let netti = makeNetti(service: service, interceptors: [interceptor])

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }

        #expect(error?.isEncodingFailure == true, "\(String(describing: error))")
        #expect(service.requests.count == 1)
    }

    @Test("given an adapter that puts a colon in a header name, when sent, then encodingFailed is thrown and nothing is sent")
    func adapterColonInName_rejected() async {
        let service = StubNetworkService()
        let adapter = ClosureAdapter { request in
            var request = request
            request.setValue("1", forHTTPHeaderField: "X-Trace: injected")
            return request
        }
        let netti = makeNetti(service: service, interceptors: [adapter])

        var error: HTTPRequestError?
        do {
            let _: HTTPResponse<Empty> = try await netti.get(TestEndpoint())
        } catch let thrown {
            error = thrown
        }

        #expect(error?.isEncodingFailure == true)
        #expect(service.requests.isEmpty)
    }
}
