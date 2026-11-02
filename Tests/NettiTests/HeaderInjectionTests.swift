//
//  HeaderInjectionTests.swift
//  Netti
//

import Foundation
import NettiTesting
import Testing

@testable import Netti

@Suite("Header injection")
struct HeaderInjectionTests {

    // MARK: - Foundation Behaviour

    /// Why Netti validates: `URLRequest` silently drops a value with CR/LF, but keeps a name with
    /// CR/LF and a value with NUL, and CFNetwork writes both to the wire as is.
    @Test("given CR/LF and NUL in headers, when set on a URLRequest, then Foundation drops only a CR/LF value")
    func foundation_sanitizesOnlyValues() {
        var single = URLRequest(url: TestURL.api)
        single.setValue("x\r\nX-Injected: 1", forHTTPHeaderField: "X-Test")
        var bulk = URLRequest(url: TestURL.api)
        bulk.allHTTPHeaderFields = ["X-Bad\r\nX-Injected: 3": "v", "X-Nul": "a\u{0}b"]

        #expect(single.value(forHTTPHeaderField: "X-Test") == nil)
        #expect(bulk.allHTTPHeaderFields?["X-Bad\r\nX-Injected: 3"] == "v")
        #expect(bulk.allHTTPHeaderFields?["X-Nul"] == "a\u{0}b")
    }

    // MARK: - Endpoint Headers

    @Test(
        "given an endpoint header with CR, LF or NUL, when sent, then it throws encodingFailed and nothing is sent",
        arguments: [
            ("X-Test", "x\r\nX-Injected: 1"),
            ("X-Test", "x\nX-Injected: 1"),
            ("X-Test", "x\rX-Injected: 1"),
            ("X-Test", "a\u{0}b"),
            ("X-Bad\r\nX-Injected: 1", "v"),
            ("X-Bad\u{0}", "v"),
            ("X-Test", "a\u{1}b"),
            ("X-Test", "a\u{7F}b"),
            ("X Test", "v"),
            ("X-Trace: injected", "v"),
            ("", "v"),
            ("X-Tést", "v"),
        ]
    )
    func endpointHeader_invalid_throwsEncodingFailed(name: String, value: String) async {
        let service = StubNetworkService()
        let netti = makeNetti(service: service)
        let endpoint = TestEndpoint(headers: [name: value])

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(endpoint)
        }

        #expect(error.map(isInvalidHeader) == true)
        #expect(service.requests.isEmpty)
    }

    @Test("given an endpoint header with CR/LF, when built, then asURLRequest throws encodingFailed")
    func asURLRequest_invalidHeader_throws() {
        let endpoint = TestEndpoint(headers: ["X-Test": "x\r\nX-Injected: 1"])

        #expect(throws: HTTPRequestError.self) {
            try endpoint.asURLRequest(for: .get)
        }
    }

    @Test("given ordinary headers, when sent, then they reach the transport")
    func endpointHeader_valid_isSent() async throws {
        let service = StubNetworkService()
        let netti = makeNetti(service: service)

        try await netti.get(TestEndpoint(headers: ["X-Test": "a value; with=\"quotes\"\tand a tab"]))

        #expect(service.requests.first?.value(forHTTPHeaderField: "X-Test") == "a value; with=\"quotes\"\tand a tab")
    }

    @Test("given token names with every token symbol and a UTF-8 value, when sent, then they reach the transport")
    func endpointHeader_tokenNames_areSent() async throws {
        let service = StubNetworkService()
        let netti = makeNetti(service: service)

        try await netti.get(TestEndpoint(headers: ["X-Request-ID": "r-1", "x!#$%&'*+-.^_`|~9": "v", "X-Name": "Zoë"]))

        #expect(service.requests.first?.value(forHTTPHeaderField: "X-Request-ID") == "r-1")
        #expect(service.requests.first?.value(forHTTPHeaderField: "x!#$%&'*+-.^_`|~9") == "v")
        #expect(service.requests.first?.value(forHTTPHeaderField: "X-Name") == "Zoë")
    }

    // MARK: - Adapted And Raw Requests

    @Test("given an adapter that sets a header name with CR/LF, when sent, then it throws encodingFailed and nothing is sent")
    func adapterHeader_invalid_throws() async {
        let service = StubNetworkService()
        let netti = makeNetti(service: service, interceptors: [HeaderAdapter(name: "X-Bad\r\nX-Injected", value: "1")])

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(TestEndpoint())
        }

        #expect(error.map(isInvalidHeader) == true)
        #expect(service.requests.isEmpty)
    }

    @Test("given a raw URLRequest with a NUL in a header value, when sent, then it throws encodingFailed")
    func rawRequest_invalid_throws() async {
        let service = StubNetworkService()
        let netti = makeNetti(service: service)
        var request = URLRequest(url: TestURL.api)
        request.allHTTPHeaderFields = ["X-Nul": "a\u{0}b"]

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.send(request)
        }

        #expect(error.map(isInvalidHeader) == true)
        #expect(service.requests.isEmpty)
    }

    @Test("given a header name with CR/LF on the real engine, when sent, then the server receives nothing")
    func realEngine_injectedName_neverReachesServer() async throws {
        let server = try await LocalHTTPServer.start { _ in .text("ok") }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))
        let endpoint = URLEndpoint(server.url("/"), headers: ["X-Bad\r\nX-Injected: 3": "v"])

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(endpoint)
        }

        #expect(error.map(isInvalidHeader) == true)
        #expect(server.requests.isEmpty)
    }

    // MARK: - Error Description

    @Test("given an invalid header, when the error is described, then it names the header and never shows the value")
    func error_namesHeaderNotValue() async {
        let netti = makeNetti()
        let endpoint = TestEndpoint(headers: ["X-Secret": "abc123\r\nX-Injected: 1"])

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.get(endpoint)
        }
        let text = error.map { "\($0) \(String(reflecting: $0)) \($0.localizedDescription)" } ?? ""

        #expect(text.contains("X-Secret"))
        #expect(text.contains("abc123") == false)
    }
}

// MARK: - Helpers

private struct HeaderAdapter: RequestInterceptor {
    let name: String
    let value: String

    func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        var fields = request.allHTTPHeaderFields ?? [:]
        fields[name] = value
        request.allHTTPHeaderFields = fields
        return request
    }
}

private func isInvalidHeader(_ error: HTTPRequestError) -> Bool {
    guard case .encodingFailed(let underlying) = error else {
        return false
    }
    return underlying is InvalidHeaderError
}
