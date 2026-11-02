import Foundation
import Testing

@testable import Netti

@Suite("DecodingError description")
struct DecodingErrorDescriptionTests {

    private struct Payload: Decodable {
        let user: User

        struct User: Decodable {
            let age: Int
        }
    }

    private func failure(for json: String) -> DecodingError? {
        do {
            _ = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
            return nil
        } catch let error as DecodingError {
            return error
        } catch {
            return nil
        }
    }

    @Test("given a wrong type, when described, then it names the expected type, the coding path and the raw JSON")
    func typeMismatch() throws {
        let json = #"{"user":{"age":"old"}}"#
        let error = try #require(failure(for: json))

        let text = error.stringDescription(as: Payload.self, data: Data(json.utf8))

        #expect(text.contains("Decoding failed for type: Payload"))
        #expect(text.contains("Type mismatch: expected Int"))
        #expect(text.contains("Coding path: user.age"))
        #expect(text.contains("Raw JSON:\n\(json)"))
    }

    @Test("given a missing key, when described, then it names the key")
    func keyNotFound() throws {
        let json = #"{"user":{}}"#
        let error = try #require(failure(for: json))

        let text = error.stringDescription(as: Payload.self, data: Data(json.utf8))

        #expect(text.contains("Key not found: 'age'"))
        #expect(text.contains("Coding path: user"))
    }

    @Test("given a null value, when described, then it reports the missing value")
    func valueNotFound() throws {
        let json = #"{"user":{"age":null}}"#
        let error = try #require(failure(for: json))

        let text = error.stringDescription(as: Payload.self, data: Data(json.utf8))

        #expect(text.contains("Value not found: Int"))
    }

    @Test("given malformed JSON, when described, then it reports corrupted data")
    func dataCorrupted() throws {
        let json = "{not json"
        let error = try #require(failure(for: json))

        let text = error.stringDescription(as: Payload.self, data: Data(json.utf8))

        #expect(text.contains("Data corrupted"))
    }

    @Test("given a body that is not UTF-8, when described, then the raw section is omitted")
    func binaryBody_omitsRawJSON() throws {
        let error = try #require(failure(for: "{not json"))

        let text = error.stringDescription(as: Payload.self, data: Data([0xFF, 0xFE, 0xFD]))

        #expect(text.contains("Raw JSON:") == false)
    }
}
