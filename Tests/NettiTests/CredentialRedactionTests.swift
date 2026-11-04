//
//  CredentialRedactionTests.swift
//  Netti
//

import Foundation
import NettiTesting
import Testing

@testable import Netti

@Suite("Credential redaction")
struct CredentialRedactionTests {
    private let secret = "abc123"
    private let securedURL = URL(string: "https://api.test/v1/me?access_token=abc123&page=2")!

    private func makeLogger() -> (NetworkLogger, Recorder<String>) {
        let messages = Recorder<String>()
        return (NetworkLogger { _, message in messages.append(message) }, messages)
    }

    private func securedResponse(status: Int = 401) -> HTTPResponse<Data> {
        var request = URLRequest(url: securedURL)
        request.setValue(secret, forHTTPHeaderField: "X-Api-Key")
        return HTTPResponse(
            request: request,
            response: HTTPURLResponse(
                url: securedURL,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Set-Cookie": "session=\(secret)", "X-Session-Token": secret]
            ),
            data: Data(),
            rawData: Data()
        )
    }

    // MARK: - Logger

    @Test("given an API key header and a token query, when a request, response and failure are logged, then the secret never appears")
    func logger_neverLogsSecrets() {
        let (logger, messages) = makeLogger()
        var request = URLRequest(url: securedURL)
        request.httpMethod = "POST"
        request.setValue(secret, forHTTPHeaderField: "X-Api-Key")
        request.httpBody = Data("password=\(secret)".utf8)
        let response = securedResponse()

        logger.requestDidSend(request)
        logger.requestDidReceiveResponse(response)
        logger.requestDidFail(request, error: .unacceptableStatusCode(401, response: response))

        let output = messages.values.joined(separator: "\n")
        #expect(messages.values.count == 3)
        #expect(output.contains(secret) == false)
        #expect(output.contains("X-Api-Key: \(NetworkLogger.redactionMarker)"))
        #expect(output.contains("page=2"))
    }

    @Test(
        "given a header whose name marks a credential, when logged as cURL, then its value is redacted",
        arguments: [
            "X-Api-Key", "X-Auth-Token", "Session-Id", "Client-Secret", "X-CSRF-Token", "x-amz-security-token", "Cookie", "Proxy-Authorization",
            "X-Password", "X-Device-Credential", "X-Otp", "X-Sig", "X-PIN", "userPin", "X-Code",
        ]
    )
    func asCurl_credentialHeaders_redacted(name: String) {
        let curl = makeURLRequest(headers: [name: secret]).asCurl()

        #expect(curl.contains(secret) == false)
        #expect(curl.contains("\(name): \(NetworkLogger.redactionMarker)"))
    }

    @Test("given ordinary headers, when logged as cURL, then their values are kept")
    func asCurl_ordinaryHeaders_kept() {
        let curl = makeURLRequest(headers: ["Accept": "application/json", "X-Request-ID": "r-1"]).asCurl()

        #expect(curl.contains("Accept: application/json"))
        #expect(curl.contains("X-Request-ID: r-1"))
    }

    @Test(
        "given a header that holds sig, pin or code only inside a longer word, when logged as cURL, then its value is kept",
        arguments: ["X-Design", "Spinner", "X-Signal", "X-Opinion", "Country-Code"]
    )
    func asCurl_lookAlikeHeaders_kept(name: String) {
        let curl = makeURLRequest(headers: [name: "visible"]).asCurl()

        #expect(curl.contains("\(name): visible"))
    }

    @Test("given credential query items, when logged as cURL, then their values are redacted and the rest kept")
    func asCurl_credentialQueryItems_redacted() throws {
        let url = try #require(URL(string: "https://user:\(secret)@api.test/x?access_token=\(secret)&API_KEY=\(secret)&page=2&sessionid=\(secret)"))

        let curl = URLRequest(url: url).asCurl()

        #expect(curl.contains(secret) == false)
        #expect(curl.contains("page=2"))
        #expect(curl.contains("access_token=\(NetworkLogger.redactionMarker)"))
    }

    @Test("given a request carrying a credential and a body, when logged as cURL, then the body is not logged")
    func asCurl_credentialRequestBody_redacted() {
        var request = makeURLRequest(method: "POST", headers: ["Authorization": "Bearer t"])
        request.httpBody = Data("password=\(secret)".utf8)

        #expect(request.asCurl().contains(secret) == false)
    }

    @Test("given a JSON body with credential keys nested in objects and arrays, when logged, then those values are redacted and the rest kept")
    func logger_nestedJSONBody_redacted() throws {
        let (logger, messages) = makeLogger()
        let body = Data(#"{"user":{"name":"ada","credentials":{"otp":"\#(secret)"}},"items":[{"label":"card","pin":"\#(secret)"}]}"#.utf8)
        var request = makeURLRequest(method: "POST", headers: ["Content-Type": "application/json"])
        request.httpBody = body
        let response = HTTPResponse(
            request: request,
            response: HTTPURLResponse(url: TestURL.api, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil),
            data: body,
            rawData: body
        )

        logger.requestDidSend(request)
        logger.requestDidReceiveResponse(response)

        let output = messages.values.joined(separator: "\n")
        #expect(messages.values.count == 2)
        #expect(output.contains(secret) == false)
        #expect(output.contains("ada"))
        #expect(output.contains("card"))
        #expect(output.contains(NetworkLogger.redactionMarker))
    }

    @Test("given a form-urlencoded token request body, when logged as cURL, then the code and secret are redacted and the rest kept")
    func asCurl_formBody_redacted() {
        var request = makeURLRequest(method: "POST")
        request.httpBody = Data("grant_type=authorization_code&code=\(secret)&client_secret=\(secret)&redirect_uri=app%3A%2F%2Fcb".utf8)

        let curl = request.asCurl()

        #expect(curl.contains(secret) == false)
        #expect(curl.contains("grant_type=authorization_code&code=\(NetworkLogger.redactionMarker)&client_secret=\(NetworkLogger.redactionMarker)&redirect_uri=app%3A%2F%2Fcb"))
    }

    @Test("given a body that is neither JSON nor form-urlencoded, when logged as cURL, then it is logged unchanged")
    func asCurl_plainBody_unchanged() {
        let text = "token: \(secret)\nsee you"
        var request = makeURLRequest(method: "POST")
        request.httpBody = Data(text.utf8)

        #expect(request.asCurl().contains("--data-raw '\(text)'"))
    }

    // MARK: - Decoding Failure (TM-37)

    @Test(
        "given a token body that does not parse, when its decoding failure is logged, then only the coding path and byte count appear",
        arguments: [#"{"access_token":"abc123","refresh_tok"#, "abc123", "access_token abc123"]
    )
    func decodingFailure_unparsedBody_notLogged(body: String) {
        let (logger, messages) = makeLogger()
        let path = [FormCodingKey(stringValue: "session"), FormCodingKey(stringValue: "token")]
        let error = DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "The given data was not valid JSON."))

        logger.log(error, type: String.self, data: Data(body.utf8))

        let output = messages.values.joined(separator: "\n")
        #expect(output.contains(secret) == false)
        #expect(output.contains("Coding path: session.token"))
        #expect(output.contains("\(body.utf8.count) bytes"))
    }

    @Test("given a JSON body, when its decoding failure is logged, then the body is logged with credential values redacted")
    func decodingFailure_jsonBody_redacted() {
        let (logger, messages) = makeLogger()
        let error = DecodingError.keyNotFound(FormCodingKey(stringValue: "expires_in"), .init(codingPath: [], debugDescription: "No value."))

        logger.log(error, type: String.self, data: Data(#"{"access_token":"\#(secret)","scope":"read"}"#.utf8))

        let output = messages.values.joined(separator: "\n")
        #expect(output.contains(secret) == false)
        #expect(output.contains("read"))
        #expect(output.contains(NetworkLogger.redactionMarker))
    }

    // MARK: - Body Size (TM-40)

    @Test("given a body over 64 KB, when the response, request and decoding failure are logged, then only its byte count is logged")
    func oversizedBody_notParsedOrLogged() {
        let (logger, messages) = makeLogger()
        let filler = String(repeating: "x", count: 64 * 1024)
        let body = Data(#"{"note":"\#(filler)","user":"ada"}"#.utf8)
        var request = makeURLRequest(method: "POST", headers: ["Content-Type": "application/json"])
        request.httpBody = body
        let response = HTTPResponse(
            request: request,
            response: HTTPURLResponse(url: TestURL.api, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil),
            data: body,
            rawData: body
        )

        logger.requestDidSend(request)
        logger.requestDidReceiveResponse(response)
        logger.log(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")), type: String.self, data: body)

        #expect(messages.values.count == 3)
        for message in messages.values {
            #expect(message.contains("ada") == false)
            #expect(message.contains("\(body.count) bytes"))
            #expect(message.contains("over the 64 KB log limit"))
        }
    }

    @Test("given a body of exactly 64 KB, when the response is logged, then it is still logged")
    func bodyAtLimit_logged() throws {
        let (logger, messages) = makeLogger()
        let prefix = #"{"user":"ada","note":""#
        let suffix = #""}"#
        let body = Data((prefix + String(repeating: "x", count: 64 * 1024 - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
        try #require(body.count == 64 * 1024)
        let response = HTTPResponse(
            request: makeURLRequest(),
            response: HTTPURLResponse(url: TestURL.api, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil),
            data: body,
            rawData: body
        )

        logger.requestDidReceiveResponse(response)

        #expect(messages.values.joined().contains("ada"))
    }

    // MARK: - Default

    @Test("given a client created with the public initializer, when read, then logging is on only in DEBUG builds")
    func logging_defaultsToDebugOnly() {
        let netti = Netti(service: StubNetworkService())

        #if DEBUG
        #expect(netti.isLoggingEnabled)
        #else
        #expect(netti.isLoggingEnabled == false)
        #endif
    }

    // MARK: - HTTPHeaders

    @Test("given an API key header, when the headers are described, then the value is redacted and other values kept")
    func headers_description_redacts() {
        let headers: HTTPHeaders = ["X-Api-Key": secret, "Accept": "application/json"]

        for text in [headers.description, String(reflecting: headers), "\(headers)", HTTPHeader(name: "X-Api-Key", value: secret).description] {
            #expect(text.contains(secret) == false)
            #expect(text.contains("X-Api-Key: \(NetworkLogger.redactionMarker)"))
        }
        #expect(headers.description.contains("Accept: application/json"))
        #expect(headers["X-Api-Key"] == secret)
    }

    // MARK: - HTTPRequestError

    @Test("given errors holding secrets in headers, URLs and values, when described, then no secret appears")
    func error_description_redacts() {
        let response = securedResponse()
        let errors: [HTTPRequestError] = [
            .unacceptableStatusCode(401, response: response),
            .unacceptableContentType("text/html", response: response),
            .validationFailed(CocoaError(.coderInvalidValue), response: response),
            .decodingFailed(CocoaError(.coderInvalidValue), response: response),
            .retryLimitExceeded(attempts: 3, lastError: .unacceptableStatusCode(503, response: response)),
            .requestFailed(URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: securedURL, NSURLErrorFailingURLStringErrorKey: securedURL.absoluteString])),
            .encodingFailed(EncodingError.invalidValue(secret, EncodingError.Context(codingPath: [], debugDescription: "bad"))),
            .downloadFailed(.requestFailed(URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: securedURL])), resumeData: Data(secret.utf8)),
            .fileSystem(CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "/tmp/\(secret)"])),
        ]

        for error in errors {
            for text in ["\(error)", String(reflecting: error), error.localizedDescription] {
                #expect(text.contains(secret) == false, "\(text)")
            }
        }
    }

    @Test("given a status error, when described, then it names the status, method, host and path")
    func error_description_keepsSafeContext() {
        let text = String(describing: HTTPRequestError.unacceptableStatusCode(401, response: securedResponse()))

        #expect(text.contains("401"))
        #expect(text.contains("GET"))
        #expect(text.contains("api.test"))
        #expect(text.contains("/v1/me"))
    }
}
