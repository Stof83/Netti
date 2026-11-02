import Foundation
import Testing

@testable import Netti

private struct User: Codable, Equatable, Sendable {
    let name: String
}

@Suite("HTTPResponse")
struct HTTPResponseTests {
    private let jsonManager = JSONManager(keyStrategy: .useDefaultKeys)

    private func rawResponse(statusCode: Int?, body: String) -> HTTPResponse<Data> {
        let url = URL(string: "https://api.test/user")!
        return HTTPResponse(
            request: URLRequest(url: url),
            response: statusCode.flatMap { HTTPURLResponse(url: url, statusCode: $0, httpVersion: nil, headerFields: nil) },
            data: Data(body.utf8),
            rawData: Data(body.utf8)
        )
    }

    @Test("given an HTTP response, when statusCode is read, then it is the response status")
    func statusCode_readsResponse() {
        #expect(rawResponse(statusCode: 201, body: "").statusCode == 201)
        #expect(rawResponse(statusCode: nil, body: "").statusCode == nil)
    }

    @Test("given a matching 200 body, when decoded, then the value and metadata are kept")
    func decoded_success_keepsMetadata() throws {
        let response: HTTPResponse<User> = try rawResponse(statusCode: 200, body: #"{"name":"Ada"}"#).decoded(using: jsonManager)

        #expect(response.data == User(name: "Ada"))
        #expect(response.statusCode == 200)
        #expect(response.rawData == Data(#"{"name":"Ada"}"#.utf8))
        #expect(response.request?.url?.absoluteString == "https://api.test/user")
    }

    @Test("given a 200 body that does not match, when decoded, then decodingFailed carries the raw response")
    func decoded_mismatch_throwsDecodingFailed() {
        #expect {
            let _: HTTPResponse<User> = try rawResponse(statusCode: 200, body: #"{"id":1}"#).decoded(using: jsonManager)
        } throws: { error in
            guard case HTTPRequestError.decodingFailed(_, let response) = error else { return false }
            return response?.statusCode == 200
        }
    }

    @Test("given a 401 with a decodable envelope, when decoded, then the status and body are returned")
    func decoded_unauthorizedEnvelope_isReturned() throws {
        let response: HTTPResponse<User> = try rawResponse(statusCode: 401, body: #"{"name":"error"}"#).decoded(using: jsonManager)

        #expect(response.statusCode == 401)
        #expect(response.data == User(name: "error"))
    }

    @Test("given a 500 with an undecodable body, when decoded, then the response is returned without a value")
    func decoded_failureStatusUndecodable_returnsNilValue() throws {
        let response: HTTPResponse<User> = try rawResponse(statusCode: 500, body: "<html>").decoded(using: jsonManager)

        #expect(response.statusCode == 500)
        #expect(response.data == nil)
        #expect(response.rawData == Data("<html>".utf8))
    }

    @Test("given an Empty response type, when the body is empty or not JSON, then decoding succeeds", arguments: ["", "OK", "{}"])
    func decoded_empty_ignoresBody(body: String) throws {
        let response: HTTPResponse<Empty> = try rawResponse(statusCode: 204, body: body).decoded(using: jsonManager)

        #expect(response.data != nil)
        #expect(response.statusCode == 204)
    }

    @Test("given a download response, when created, then status and resume data are exposed")
    func downloadResponse_exposesStatusAndResumeData() {
        let url = URL(string: "https://api.test/file")!
        let response = HTTPDownloadResponse<URL>(
            request: URLRequest(url: url),
            response: HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: nil),
            fileURL: nil,
            resumeData: Data([1, 2])
        )

        #expect(response.statusCode == 206)
        #expect(response.resumeData == Data([1, 2]))
        #expect(response.metrics == nil)
    }
}
