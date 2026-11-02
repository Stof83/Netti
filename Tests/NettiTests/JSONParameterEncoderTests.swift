import Foundation
import Testing

@testable import Netti

private struct Item: Codable, Equatable, Sendable {
    let id: Int
}

@Suite("JSONParameterEncoder")
struct JSONParameterEncoderTests {
    private let request: URLRequest = {
        var request = URLRequest(url: URL(string: "https://api.test/items")!)
        request.httpMethod = "POST"
        return request
    }()

    @Test("given a top-level array, when encoded, then the body is a JSON array (B5)")
    func encode_topLevelArray() throws {
        let encoded = try JSONParameterEncoder.default.encode([Item(id: 1), Item(id: 2)], into: request)
        let body = try #require(encoded.httpBody)

        #expect(try JSONDecoder().decode([Item].self, from: body) == [Item(id: 1), Item(id: 2)])
    }

    @Test("given a decimal 0.1, when encoded, then the body contains 0.1 exactly (B5)")
    func encode_decimal_keepsPrecision() throws {
        let encoded = try JSONParameterEncoder.default.encode(["amount": Decimal(string: "0.1")!], into: request)

        #expect(encoded.httpBody.map { String(decoding: $0, as: UTF8.self) } == #"{"amount":0.1}"#)
    }

    @Test("given no Content-Type, when encoded, then application/json is set")
    func encode_setsJSONContentType() throws {
        let encoded = try JSONParameterEncoder.default.encode(Item(id: 1), into: request)

        #expect(encoded.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("given an endpoint Content-Type, when encoded, then it is kept")
    func encode_keepsEndpointContentType() throws {
        var original = request
        original.setValue("application/vnd.api+json", forHTTPHeaderField: "content-type")
        let encoded = try JSONParameterEncoder.default.encode(Item(id: 1), into: original)

        #expect(encoded.value(forHTTPHeaderField: "Content-Type") == "application/vnd.api+json")
    }

    @Test("given a configured JSONEncoder, when encoded, then its key strategy is applied")
    func encode_usesEncoderStrategies() throws {
        struct Profile: Encodable, Sendable {
            let firstName: String
        }
        let encoder = JSONManager(keyStrategy: .convertSnakeCase).encoder
        let encoded = try JSONParameterEncoder(encoder: encoder).encode(Profile(firstName: "Ada"), into: request)

        #expect(encoded.httpBody.map { String(decoding: $0, as: UTF8.self) } == #"{"first_name":"Ada"}"#)
    }

    @Test("given nil parameters, when encoded, then the request is unchanged")
    func encode_nil_unchanged() throws {
        #expect(try JSONParameterEncoder.default.encode(Item?.none, into: request) == request)
    }

    @Test("given an unencodable value, when encoded, then encodingFailed is thrown")
    func encode_unencodable_throwsEncodingFailed() {
        #expect {
            try JSONParameterEncoder.default.encode(["value": Double.nan], into: request)
        } throws: { error in
            guard case HTTPRequestError.encodingFailed = error else { return false }
            return true
        }
    }
}
