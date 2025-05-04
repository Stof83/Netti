import Foundation
import Testing

@testable import Netti

extension Tag {
    @Tag static var netti: Self
    @Tag static var send: Self
    @Tag static var decode: Self
}

struct MockResponse: Codable, Equatable {
    let message: String
}

struct MockRequest: Codable {
    let id: Int
}

struct MockAPI: HTTPRequest {
    var baseURL: URL? = URL(string: "https://example.com")
    var basePath: String = "api"
    var path: String = "test"
    var headers: HTTPHeaders = [:]
    var sampleData: Data? = nil
}

@Suite(.tags(.netti))
struct NettiTests {
    private let netti: Netti

    init() {
        netti = Netti()
    }

    // MARK: - Success Case

    @Test("Successful request returns decoded data")
    func testSuccessfulSend() async throws {
        let expected = MockResponse(message: "Hello!")
        
        let response: HTTPResponse<MockResponse> = try await netti.send(
            MockAPI(),
            parameters: MockRequest(id: 123),
            method: .post
        )
        
        #expect(response.data == expected)
    }

    // MARK: - Failure: Network Error

    @Test("Transport failure throws requestFailed")
    func testRequestFailure() async throws {
        do {
            let _: HTTPResponse<MockResponse> = try await netti.send(
                MockAPI(),
                parameters: MockRequest(id: 1),
                method: .get
            )
            Issue.record("Expected to throw")
        } catch HTTPRequestError.requestFailed {
            // success
        }
    }

    // MARK: - Failure: Decoding Error

    @Test("Invalid data throws decodingFailed")
    func testDecodingFailure() async throws {
        do {
            let _: HTTPResponse<MockResponse> = try await netti.send(
                MockAPI(),
                parameters: MockRequest(id: 1),
                method: .get
            )
            Issue.record("Expected decoding failure")
        } catch HTTPRequestError.decodingFailed {
            // success
        }
    }

    // MARK: - Sample Data

    @Test("Sample data is decoded without network call")
    func testSampleDataDecoding() async throws {
        let expected = MockResponse(message: "Sampled!")
        let sampleData = try JSONEncoder().encode(expected)

        var request = MockAPI()
        request.sampleData = sampleData

        let response: HTTPResponse<MockResponse> = try await netti.send(request, method: .get)
        
        #expect(response.data == expected)
    }

    // MARK: - Decode Utility

    @Test("Decode utility returns expected response")
    func testDecodeUtility() async throws {
        let expected = MockResponse(message: "Decoded")
        let data = try JSONEncoder().encode(expected)

        let response: HTTPResponse<MockResponse> = try await netti.decode(data)
        
        #expect(response.data == expected)
    }

    @Test("Decode utility throws on invalid data")
    func testDecodeUtilityFailure() async throws {
        let invalidData = Data("broken".utf8)
        
        do {
            let _: HTTPResponse<MockResponse> = try await netti.decode(invalidData)
            Issue.record("Should have thrown decoding error")
        } catch HTTPRequestError.decodingFailed {
            // success
        }
    }
}
