//
//  RedTeamTokenLeakageTests.swift
//  Netti
//

import Foundation
import Testing

@testable import Netti
import NettiTesting

/// S.12 red team, credential leakage (TM-04, TM-18, TM-19): a token never reaches an origin it was
/// not meant for, and no secret appears in a log line or an error description.
@Suite("Red team: token leakage", .timeLimit(.minutes(1)))
struct RedTeamTokenLeakageTests {

    // MARK: - Constants

    private static let secret = "s3cr3t-Value-42"
    private static let credentialHeaders = ["Authorization", "Proxy-Authorization", "Cookie"]

    // MARK: - Redirects

    @Test(
        "given .secure, when a redirect lands on a look-alike or different origin, then no credential header survives",
        arguments: [
            "https://api.test@evil.test/final",
            "https://evil.test/final#@api.test",
            "https://evil.test/final?next=https://api.test",
            "https://api.test.evil.test/final",
            "https://evil.test:443/final",
            "https://api.test:444/final",
            "https://EVIL.test/final",
            "https://xn--pi-7ka.test/final",
            "https://127.0.0.1/final",
            "wss://api.test/final",
        ]
    )
    func secureRedirect_crossOrigin_stripsCredentials(destination: String) throws {
        let source = try #require(URL(string: "https://api.test/start"))
        let target = try #require(URL(string: destination))
        let response = try #require(HTTPURLResponse(url: source, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination]))

        let outcome = RedirectHandler.secure.outcome(for: Self.authenticated(target), response: response, current: Self.authenticated(source), hasBody: false)

        guard case .send(let request) = outcome else {
            Issue.record("Expected the redirect to be followed without credentials, got \(outcome)")
            return
        }
        for name in Self.credentialHeaders {
            #expect(request.value(forHTTPHeaderField: name) == nil, "\(name) reached \(destination)")
        }
    }

    // MARK: - Host Scope

    @Test(
        "given an interceptor scoped to api.example.com, when a request targets another host, then it carries no Authorization",
        arguments: [
            "https://storage.example.net/upload?sig=1",
            "https://api.example.com.evil.com/me",
            "https://evil.com/?host=api.example.com",
            "https://api.example.com@evil.com/me",
            "https://evil.com/#api.example.com",
            "https://example.com/me",
            "https://v2.api.example.com/me",
            "https://api.example.com./me",
            "https://127.0.0.1/me",
        ]
    )
    func scopedInterceptor_thirdPartyHost_noToken(url: String) async throws {
        let service = StubNetworkService()
        let interceptor = AuthenticationInterceptor(bearerToken: Self.secret, hosts: ["api.example.com"]) { $0 }
        let netti = makeNetti(service: service, interceptors: [interceptor])

        try await netti.send(URLRequest(url: try #require(URL(string: url))))

        let sent = try #require(service.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("given an interceptor scoped to api.example.com, when the host is spelled in another case, then the token is attached")
    func scopedInterceptor_caseInsensitiveHost_attaches() async throws {
        let service = StubNetworkService()
        let interceptor = AuthenticationInterceptor(bearerToken: Self.secret, hosts: ["api.example.com"]) { $0 }
        let netti = makeNetti(service: service, interceptors: [interceptor])

        try await netti.send(URLRequest(url: try #require(URL(string: "https://API.Example.com/me"))))

        #expect(service.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.secret)")
    }

    @Test("given a third-party host that answers 401, when the scoped interceptor sees it, then it never refreshes nor retries with a token")
    func scopedInterceptor_thirdParty401_noRefresh() async throws {
        let refreshes = Counter()
        let service = StubNetworkService { .stub(for: $0, status: 401) }
        let interceptor = AuthenticationInterceptor(bearerToken: Self.secret, hosts: ["api.example.com"]) { token in
            refreshes.increment()
            return token + "-renewed"
        }
        let netti = makeNetti(service: service, interceptors: [interceptor])

        let response = try await netti.send(URLRequest(url: try #require(URL(string: "https://storage.example.net/blob"))))

        #expect(response.statusCode == 401)
        #expect(refreshes.value == 0)
        #expect(service.requests.count == 1)
        #expect(service.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    // MARK: - Logs and Errors

    @Test("given every kind of credential in headers, cookies and the URL, when a request, response and failure are logged, then no secret appears")
    func logger_neverLogsCredentials() throws {
        let messages = Recorder<String>()
        let logger = NetworkLogger { _, message in messages.append(message) }
        let url = try #require(URL(string: "https://user:\(Self.secret)@api.test/v1/me?session_id=\(Self.secret)&page=2"))
        let request = Self.credentialRequest(url)
        let response = Self.credentialResponse(for: request)

        logger.requestDidSend(request)
        logger.requestDidReceiveResponse(response)
        logger.requestDidFail(request, error: .unacceptableStatusCode(401, response: response))
        logger.requestDidFail(request, error: .requestFailed(URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])))

        let output = messages.values.joined(separator: "\n")
        #expect(messages.values.isEmpty == false)
        #expect(output.contains(Self.secret) == false, "\(output)")
        #expect(output.contains("page=2"))
    }

    @Test("given errors and headers holding every kind of credential, when described in any way, then no secret appears")
    func descriptions_neverShowCredentials() throws {
        let url = try #require(URL(string: "https://user:\(Self.secret)@api.test/v1/me?session_id=\(Self.secret)"))
        let request = Self.credentialRequest(url)
        let response = Self.credentialResponse(for: request)
        let headers = HTTPHeaders(request.allHTTPHeaderFields ?? [:])
        let errors: [HTTPRequestError] = [
            .unacceptableStatusCode(401, response: response),
            .decodingFailed(CocoaError(.coderInvalidValue), response: response),
            .validationFailed(CocoaError(.coderInvalidValue), response: response),
            .retryLimitExceeded(attempts: 2, lastError: .unacceptableStatusCode(401, response: response)),
            .requestFailed(URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString])),
            .transport(URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url])),
        ]

        var texts = [headers.description, String(reflecting: headers), request.asCurl()]
        for error in errors {
            texts += ["\(error)", String(reflecting: error), error.localizedDescription]
        }

        for text in texts {
            #expect(text.contains(Self.secret) == false, "\(text)")
        }
    }

    @Test(
        "given a credential whose name has no auth/token/key/secret/session/cookie part, when logged, then it is redacted",
        arguments: ["password", "passwd", "X-Amz-Signature", "sig", "code"]
    )
    func logger_unlistedCredentialNames(name: String) throws {
        let messages = Recorder<String>()
        let logger = NetworkLogger { _, message in messages.append(message) }
        var request = URLRequest(url: try #require(URL(string: "https://api.test/login?\(name)=\(Self.secret)")))
        request.setValue(Self.secret, forHTTPHeaderField: "X-\(name)")

        logger.requestDidSend(request)

        #expect(messages.values.joined().contains(Self.secret) == false)
    }

    @Test("given a token response to an authenticated request, when its body is logged, then the access token does not appear")
    func logger_tokenResponseBody() throws {
        let messages = Recorder<String>()
        let logger = NetworkLogger { _, message in messages.append(message) }
        let request = Self.credentialRequest(try #require(URL(string: "https://api.test/oauth/token")))
        let response = Self.credentialResponse(for: request, body: Data(#"{"access_token":"\#(Self.secret)","refresh_token":"\#(Self.secret)"}"#.utf8))

        logger.requestDidReceiveResponse(response)

        #expect(messages.values.joined().contains(Self.secret) == false)
    }

    @Test("given a login request without a credential header, when its JSON body is logged, then the password does not appear")
    func logger_loginBody() throws {
        let messages = Recorder<String>()
        let logger = NetworkLogger { _, message in messages.append(message) }
        var request = URLRequest(url: try #require(URL(string: "https://api.test/login")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"username":"ada","password":"\#(Self.secret)"}"#.utf8)

        logger.requestDidSend(request)

        #expect(messages.values.joined().contains(Self.secret) == false)
    }
}

// MARK: - Helpers

private extension RedTeamTokenLeakageTests {
    static func authenticated(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("Basic \(secret)", forHTTPHeaderField: "Proxy-Authorization")
        request.setValue("session=\(secret)", forHTTPHeaderField: "Cookie")
        return request
    }

    static func credentialRequest(_ url: URL) -> URLRequest {
        var request = authenticated(url)
        request.setValue(secret, forHTTPHeaderField: "X-Session-Id")
        request.setValue(secret, forHTTPHeaderField: "X-Api-Key")
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"refresh_token":"\#(secret)"}"#.utf8)
        return request
    }

    static func credentialResponse(for request: URLRequest, body: Data = Data(#"{"id":1}"#.utf8)) -> HTTPResponse<Data> {
        HTTPResponse(
            request: request,
            response: HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["Set-Cookie": "session=\(secret); HttpOnly", "X-Session-Id": secret, "WWW-Authenticate": "Bearer realm=\(secret)"]
            ),
            data: body,
            rawData: body
        )
    }
}
