import Foundation
import Testing

@testable import Netti

@Suite("HTTPRequestError")
struct HTTPRequestErrorTests {
    private let rawResponse = HTTPResponse<Data>(
        request: nil,
        response: HTTPURLResponse(url: URL(string: "https://api.test")!, statusCode: 401, httpVersion: nil, headerFields: nil),
        data: Data("{}".utf8),
        rawData: Data("{}".utf8)
    )

    @Test("given a validation failure, when response is read, then the raw response is returned")
    func response_validationFailure_returnsResponse() {
        let statusError = HTTPRequestError.unacceptableStatusCode(401, response: rawResponse)
        let contentTypeError = HTTPRequestError.unacceptableContentType("text/html", response: rawResponse)
        let customError = HTTPRequestError.validationFailed(CocoaError(.coderInvalidValue), response: rawResponse)

        #expect(statusError.response?.statusCode == 401)
        #expect(contentTypeError.response?.statusCode == 401)
        #expect(customError.response?.statusCode == 401)
    }

    @Test("given a retry limit wrapping a status failure, when response is read, then the last response is returned")
    func response_retryLimitExceeded_returnsLastResponse() {
        let error = HTTPRequestError.retryLimitExceeded(
            attempts: 3,
            lastError: .unacceptableStatusCode(401, response: rawResponse)
        )

        #expect(error.response?.statusCode == 401)
    }

    @Test(
        "given an error without a response, when response is read, then it is nil",
        arguments: [
            HTTPRequestError.invalidURL,
            .cancelled,
            .encodingFailed(CocoaError(.coderInvalidValue)),
            .requestFailed(URLError(.timedOut)),
            .serverTrustEvaluationFailed(host: "api.test", reason: "pin mismatch"),
            .fileSystem(CocoaError(.fileNoSuchFile)),
            .decodingFailed(CocoaError(.coderReadCorrupt), response: nil),
        ]
    )
    func response_noResponse_isNil(error: HTTPRequestError) {
        #expect(error.response == nil)
    }

    @Test("given an HTTPRequestError, when mapped from a transport, then it is not re-wrapped (B1)")
    func transport_requestError_passesThrough() {
        let decodingError = HTTPRequestError.decodingFailed(CocoaError(.coderReadCorrupt), response: nil)

        guard case .decodingFailed = HTTPRequestError.transport(decodingError) else {
            Issue.record("decodingFailed was re-wrapped")
            return
        }
    }

    @Test("given a cancellation, when mapped from a transport, then it becomes cancelled")
    func transport_cancellation_becomesCancelled() {
        guard case .cancelled = HTTPRequestError.transport(CancellationError()),
              case .cancelled = HTTPRequestError.transport(URLError(.cancelled)) else {
            Issue.record("Cancellation was not mapped to .cancelled")
            return
        }
    }

    @Test("given a URLError, when mapped from a transport, then it becomes requestFailed with the same code")
    func transport_urlError_becomesRequestFailed() {
        guard case .requestFailed(let urlError) = HTTPRequestError.transport(URLError(.notConnectedToInternet)) else {
            Issue.record("Expected requestFailed")
            return
        }
        #expect(urlError.code == .notConnectedToInternet)
    }

    @Test("given an unknown error, when mapped from a transport, then it becomes requestFailed keeping the underlying error")
    func transport_unknownError_keepsUnderlyingError() {
        let underlying = CocoaError(.featureUnsupported)

        guard case .requestFailed(let urlError) = HTTPRequestError.transport(underlying) else {
            Issue.record("Expected requestFailed")
            return
        }
        #expect(urlError.code == .unknown)
        #expect((urlError.userInfo[NSUnderlyingErrorKey] as? CocoaError) == underlying)
    }
}
