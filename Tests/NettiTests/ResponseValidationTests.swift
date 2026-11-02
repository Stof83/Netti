import Foundation
import Testing

@testable import Netti

@Suite("ResponseValidation")
struct ResponseValidationTests {
    private let json = Data(#"{"ok":true}"#.utf8)

    private func response(
        status: Int = 200,
        contentType: String? = "application/json",
        body: Data? = nil,
        accept: String? = nil
    ) -> HTTPResponse<Data> {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        return makeResponse(
            status: status,
            headers: headers,
            body: body ?? json,
            request: makeURLRequest(headers: accept.map { ["Accept": $0] } ?? [:])
        )
    }

    // MARK: - Status

    @Test("given the default rules, when the status is 2xx, then the response is accepted", arguments: [200, 201, 204, 299])
    func validate_2xx_accepted(status: Int) throws {
        try ResponseValidation().validate(response(status: status))
    }

    @Test("given validation on, when the server returns 404, then it throws with the status and the raw body")
    func validate_404_throwsStatusError() {
        let error = #expect(throws: HTTPRequestError.self) {
            try ResponseValidation().validate(response(status: 404))
        }

        guard case .unacceptableStatusCode(let status, let rejected) = error else {
            Issue.record("Expected unacceptableStatusCode, got \(String(describing: error))")
            return
        }
        #expect(status == 404)
        #expect(rejected.rawData == json)
    }

    @Test("given a widened status set, when a 404 arrives, then it is accepted")
    func validate_customStatuses_accepted() throws {
        try ResponseValidation(statusCodes: Set(200..<500)).validate(response(status: 404))
    }

    @Test("given no status rule, when a 500 arrives, then it is accepted")
    func validate_noStatusRule_acceptsAnything() throws {
        try ResponseValidation(statusCodes: nil).validate(response(status: 500))
    }

    @Test("given a response without an HTTP status, when validated, then status and content type are skipped")
    func validate_cachedResponse_skipsChecks() throws {
        let cached = HTTPResponse<Data>.cached(data: json)

        try ResponseValidation(contentTypes: .only(["text/plain"])).validate(cached)
    }

    // MARK: - Content type

    @Test("given JSON expected, when the server returns text/html, then it throws unacceptableContentType")
    func validate_htmlInsteadOfJSON_throws() {
        let html = response(contentType: "text/html; charset=utf-8", body: Data("<html/>".utf8), accept: "application/json")

        let error = #expect(throws: HTTPRequestError.self) {
            try ResponseValidation().validate(html)
        }

        guard case .unacceptableContentType(let received, _) = error else {
            Issue.record("Expected unacceptableContentType, got \(String(describing: error))")
            return
        }
        #expect(received == "text/html; charset=utf-8")
    }

    @Test("given an Accept header, when the content type matches ignoring case and parameters, then it is accepted")
    func validate_matchingContentType_accepted() throws {
        let matching = response(contentType: "Application/JSON; charset=utf-8", accept: "application/json")

        try ResponseValidation().validate(matching)
    }

    @Test("given an Accept header with several types and q-values, when one matches, then it is accepted")
    func validate_acceptList_oneMatches() throws {
        let matching = response(contentType: "application/xml", accept: "application/json;q=0.9, application/xml")

        try ResponseValidation().validate(matching)
    }

    @Test("given a type/* wildcard, when the subtype differs, then it is accepted; when the type differs, rejected")
    func validate_wildcardSubtype() throws {
        let rule = ResponseValidation(contentTypes: .only(["image/*"]))

        try rule.validate(response(contentType: "image/png"))
        #expect(throws: HTTPRequestError.self) {
            try rule.validate(response(contentType: "application/json"))
        }
    }

    @Test("given */* accepted, when any type arrives, then it is accepted")
    func validate_anyWildcard_accepted() throws {
        try ResponseValidation().validate(response(contentType: "text/csv", accept: "*/*"))
    }

    @Test("given no Accept header and the default rule, when any type arrives, then it is accepted")
    func validate_noAcceptHeader_skipsContentType() throws {
        try ResponseValidation().validate(response(contentType: "text/html"))
    }

    @Test("given an expected type, when the response has no Content-Type, then it throws with a nil received type")
    func validate_missingContentType_throws() {
        let error = #expect(throws: HTTPRequestError.self) {
            try ResponseValidation(contentTypes: .only(["application/json"])).validate(response(contentType: nil))
        }

        guard case .unacceptableContentType(let received, _) = error else {
            Issue.record("Expected unacceptableContentType, got \(String(describing: error))")
            return
        }
        #expect(received == nil)
    }

    @Test("given an empty body, when the content type does not match, then the check is skipped")
    func validate_emptyBody_skipsContentType() throws {
        let empty = response(status: 204, contentType: "text/html", body: Data(), accept: "application/json")

        try ResponseValidation().validate(empty)
    }

    // MARK: - Custom

    @Test("given a custom validator rejecting a missing X-Signature, when it is missing, then it throws with the validator's reason")
    func validate_custom_rejects() {
        struct MissingSignature: Error, Equatable {}
        let rule = ResponseValidation { response in
            if response.response?.value(forHTTPHeaderField: "X-Signature") == nil { throw MissingSignature() }
        }

        let error = #expect(throws: HTTPRequestError.self) {
            try rule.validate(response())
        }

        guard case .validationFailed(let reason, let rejected) = error else {
            Issue.record("Expected validationFailed, got \(String(describing: error))")
            return
        }
        #expect(reason is MissingSignature)
        #expect(rejected.statusCode == 200)
        #expect(error?.response?.statusCode == 200)
    }

    @Test("given a custom validator, when the response passes, then it is accepted")
    func validate_custom_accepts() throws {
        let rule = ResponseValidation { _ in }

        try rule.validate(response())
    }

    @Test("given a failing status, when a custom validator exists, then the status error wins and the validator is not run")
    func validate_statusFailure_skipsCustom() {
        let calls = Counter()
        let rule = ResponseValidation { _ in calls.increment() }

        let error = #expect(throws: HTTPRequestError.self) {
            try rule.validate(response(status: 500))
        }

        guard case .unacceptableStatusCode = error else {
            Issue.record("Expected unacceptableStatusCode, got \(String(describing: error))")
            return
        }
        #expect(calls.value == 0)
    }

    // MARK: - Disabled and endpoint override

    @Test("given the disabled validation, when any response arrives, then it is accepted")
    func disabled_acceptsEverything() throws {
        try ResponseValidation.disabled.validate(response(status: 500, contentType: "text/html", accept: "application/json"))
    }

    @Test("given a request without validation, when read, then it inherits (nil); an endpoint can set or disable it")
    func httpRequest_validationOverride() {
        struct Inherits: HTTPRequest {
            var baseURL: URL? { TestURL.api }
            var basePath: String { "" }
            var path: String { "" }
            var headers: HTTPHeaders { [:] }
        }
        struct Disables: HTTPRequest {
            var baseURL: URL? { TestURL.api }
            var basePath: String { "" }
            var path: String { "" }
            var headers: HTTPHeaders { [:] }
            var validation: ResponseValidation? { .disabled }
        }

        #expect(Inherits().validation == nil)
        #expect(Disables().validation?.statusCodes == nil)
    }
}
