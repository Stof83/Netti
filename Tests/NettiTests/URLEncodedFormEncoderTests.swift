import Foundation
import Testing

@testable import Netti

private struct Filter: Encodable, Sendable {
    let ids: [Int]
    let active: Bool
}

private struct Page: Encodable, Sendable {
    let page: Int
}

private struct Nested: Encodable, Sendable {
    struct Address: Encodable, Sendable {
        let city: String
        let zip: String?
    }
    let user: String
    let address: Address
}

/// Encodes one member whose key is chosen at run time.
private struct SingleKey: Encodable {
    let key: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FormCodingKey.self)
        try container.encode(1, forKey: FormCodingKey(stringValue: key))
    }
}

/// A value that nests itself `depth` levels deep: `{"child": {"child": … {"leaf": 1}}}`.
private final class Nesting: Encodable, Sendable {
    let child: Nesting?

    init(depth: Int) {
        var node: Nesting? = nil
        for _ in 0..<depth {
            node = Nesting(child: node)
        }
        self.child = node
    }

    private init(child: Nesting?) {
        self.child = child
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FormCodingKey.self)
        if let child {
            try container.encode(child, forKey: FormCodingKey(stringValue: "child"))
        } else {
            try container.encode(1, forKey: FormCodingKey(stringValue: "leaf"))
        }
    }
}

@Suite("URLEncodedFormEncoder")
struct URLEncodedFormEncoderTests {
    private let url = URL(string: "https://api.test/items")!

    private func request(_ url: URL, method: HTTPMethod) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        return request
    }

    // MARK: - Encoder

    @Test("given arrays and bools, when encoded with defaults, then ids repeat and bools are literal")
    func encode_defaults_arraysNoBracketsBoolsLiteral() throws {
        let query = try URLEncodedFormEncoder().encode(Filter(ids: [1, 2], active: true))

        #expect(query == "active=true&ids=1&ids=2")
    }

    @Test(
        "given an array strategy, when encoded, then keys follow it",
        arguments: [
            (URLEncodedFormEncoder.ArrayEncoding.noBrackets, "ids=1&ids=2"),
            (.brackets, "ids%5B%5D=1&ids%5B%5D=2"),
            (.indexInBrackets, "ids%5B0%5D=1&ids%5B1%5D=2"),
        ]
    )
    func encode_arrayStrategies(strategy: URLEncodedFormEncoder.ArrayEncoding, expected: String) throws {
        let query = try URLEncodedFormEncoder(arrayEncoding: strategy).encode(["ids": [1, 2]])

        #expect(query == expected)
    }

    @Test("given numeric bool encoding, when encoded, then bools are 1 and 0")
    func encode_numericBools() throws {
        let query = try URLEncodedFormEncoder(boolEncoding: .numeric).encode(["on": true, "off": false])

        #expect(query == "off=0&on=1")
    }

    @Test(
        "given a date strategy, when encoded, then the date follows it",
        arguments: [
            (URLEncodedFormEncoder.DateEncoding.iso8601, "2023-11-14T22%3A13%3A20Z"),
            (.secondsSince1970, "1700000000"),
            (.millisecondsSince1970, "1700000000000"),
            (.custom { _ in "today" }, "today"),
        ]
    )
    func encode_dateStrategies(strategy: URLEncodedFormEncoder.DateEncoding, expected: String) throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(try URLEncodedFormEncoder(dateEncoding: strategy).encode(["at": date]) == "at=\(expected)")
    }

    @Test("given nested values, when encoded, then bracket keys are used and nil members are omitted")
    func encode_nested_usesBracketKeys() throws {
        let value = Nested(user: "ada", address: .init(city: "Rome", zip: nil))
        let query = try URLEncodedFormEncoder().encode(value)

        #expect(query == "address%5Bcity%5D=Rome&user=ada")
    }

    @Test("given reserved characters, when encoded, then they are RFC 3986 escaped")
    func encode_reservedCharacters_areEscaped() throws {
        let query = try URLEncodedFormEncoder().encode(["q": "a+b&c=d e/f?"])

        #expect(query == "q=a%2Bb%26c%3Dd%20e/f?")
    }

    @Test("given plus space encoding, when encoded, then spaces become plus while a literal plus stays escaped")
    func encode_plusSpaces() throws {
        let query = try URLEncodedFormEncoder(spaceEncoding: .plusReplaced).encode(["q": "a b+c"])

        #expect(query == "q=a+b%2Bc")
    }

    @Test("given snake case key encoding, when encoded, then keys are converted like JSONEncoder")
    func encode_snakeCaseKeys() throws {
        struct Keys: Encodable {
            let userID: Int
            let myURLValue: String
            let plain: Int
        }
        let query = try URLEncodedFormEncoder(keyEncoding: .convertToSnakeCase).encode(Keys(userID: 1, myURLValue: "x", plain: 2))

        #expect(query == "my_url_value=x&plain=2&user_id=1")
    }

    // MARK: - Key Encoding From JSONEncoder

    @Test("given JSONEncoder default keys, when mapped, then keys are kept as declared")
    func keyEncoding_fromJSONDefaultKeys_keepsKeys() {
        let keyEncoding = URLEncodedFormEncoder.KeyEncoding(.useDefaultKeys)

        #expect(keyEncoding.encode("pageNumber") == "pageNumber")
    }

    @Test("given JSONEncoder snake case, when mapped, then keys are snake cased")
    func keyEncoding_fromJSONSnakeCase_snakeCasesKeys() {
        let keyEncoding = URLEncodedFormEncoder.KeyEncoding(.convertToSnakeCase)

        #expect(keyEncoding.encode("pageNumber") == "page_number")
    }

    @Test("given a custom JSONEncoder key strategy, when mapped, then the closure receives the key and its result is used")
    func keyEncoding_fromJSONCustom_usesClosure() {
        let keyEncoding = URLEncodedFormEncoder.KeyEncoding(.custom { codingPath in
            FormCodingKey(stringValue: "x_" + (codingPath.last?.stringValue ?? ""))
        })

        #expect(keyEncoding.encode("pageNumber") == "x_pageNumber")
    }

    @Test(
        "given a typical camelCase key, when snake cased, then the result matches JSONEncoder",
        arguments: ["pageNumber", "userID", "myURLValue", "isURL", "page2Size", "_privateKey", "plain"]
    )
    func keyEncoding_snakeCase_matchesJSONEncoder(key: String) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try JSONDecoder().decode([String: Int].self, from: encoder.encode(SingleKey(key: key)))

        #expect(URLEncodedFormEncoder.KeyEncoding.convertToSnakeCase.encode(key) == json.keys.first)
    }

    @Test(
        "given the default JSONManager, when a key starting with an acronym is encoded, then acronyms stay together",
        arguments: [("URLValue", "url_value"), ("ID", "id"), ("HTTPSUrl", "https_url"), ("userID", "user_id"), ("pageNumber", "page_number")]
    )
    func jsonManager_snakeCase_keepsAcronyms(key: String, expected: String) throws {
        let json = try JSONDecoder().decode([String: Int].self, from: JSONManager().encode(SingleKey(key: key)))

        #expect(json.keys.first == expected)
    }

    @Test(
        "given the default JSONManager, when a key is encoded as a body and as a query, then both spell it the same",
        arguments: ["URLValue", "ID", "my_Value", "myURLValue", "userID", "pageNumber"]
    )
    func jsonManager_snakeCase_bodyMatchesQuery(key: String) throws {
        let manager = JSONManager()
        let json = try JSONDecoder().decode([String: Int].self, from: manager.encode(SingleKey(key: key)))
        let query = try URLEncodedFormEncoder(keyEncoding: .init(manager.encoder.keyEncodingStrategy)).encode(SingleKey(key: key))

        #expect(query == "\(json.keys.first ?? "")=1")
    }

    @Test("given Decimal and Double values, when encoded, then digits are exact")
    func encode_numbers_areExact() throws {
        struct Numbers: Encodable {
            let amount: Decimal
            let ratio: Double
        }
        let query = try URLEncodedFormEncoder().encode(Numbers(amount: Decimal(string: "0.1")!, ratio: 0.25))

        #expect(query == "amount=0.1&ratio=0.25")
    }

    @Test("given alphabetizing disabled, when encoded, then declaration order is kept")
    func encode_declarationOrder() throws {
        let query = try URLEncodedFormEncoder(alphabetizeKeyValuePairs: false).encode(Filter(ids: [3], active: false))

        #expect(query == "ids=3&active=false")
    }

    @Test("given a top-level array, when encoded, then an encoding error is thrown")
    func encode_topLevelArray_throws() {
        #expect(throws: EncodingError.self) {
            try URLEncodedFormEncoder().encode([1, 2])
        }
    }

    @Test("given a non-finite number, when encoded, then an encoding error is thrown")
    func encode_nonFinite_throws() {
        #expect(throws: EncodingError.self) {
            try URLEncodedFormEncoder().encode(["value": Double.nan])
        }
    }

    // MARK: - Parameter Encoder

    @Test("given an existing query, when parameters are encoded, then both are kept (B4)")
    func parameterEncoder_mergesExistingQuery() throws {
        let existing = try #require(URL(string: "https://api.test/items?lang=it"))
        let encoded = try URLEncodedFormParameterEncoder.default.encode(Page(page: 2), into: request(existing, method: .get))

        #expect(encoded.url?.absoluteString == "https://api.test/items?lang=it&page=2")
    }

    @Test("given a reserved character value, when encoded into the query, then it is escaped (B4)")
    func parameterEncoder_escapesQueryValue() throws {
        let encoded = try URLEncodedFormParameterEncoder.default.encode(["q": "a+b&c"], into: request(url, method: .get))

        #expect(encoded.url?.query(percentEncoded: true) == "q=a%2Bb%26c")
    }

    @Test(
        "given a method-dependent destination, when encoded, then GET, HEAD and DELETE use the query",
        arguments: HTTPMethod.allCases
    )
    func parameterEncoder_methodDependent(method: HTTPMethod) throws {
        let encoded = try URLEncodedFormParameterEncoder.default.encode(Page(page: 1), into: request(url, method: method))

        if method.defaultParameterDestination == .queryString {
            #expect(encoded.url?.query == "page=1")
            #expect(encoded.httpBody == nil)
        } else {
            #expect(encoded.url == url)
            #expect(encoded.httpBody == Data("page=1".utf8))
            #expect(encoded.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=utf-8")
        }
    }

    @Test("given a body destination and an existing Content-Type, when encoded, then the header is kept")
    func parameterEncoder_keepsContentType() throws {
        var original = request(url, method: .post)
        original.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let encoded = try URLEncodedFormParameterEncoder(destination: .httpBody).encode(Page(page: 1), into: original)

        #expect(encoded.value(forHTTPHeaderField: "Content-Type") == "text/plain")
    }

    @Test("given nil parameters, when encoded, then the request is unchanged")
    func parameterEncoder_nilParameters_unchanged() throws {
        let original = request(url, method: .get)

        #expect(try URLEncodedFormParameterEncoder.default.encode(Page?.none, into: original) == original)
    }

    @Test("given a request without URL, when encoded, then invalidURL is thrown instead of crashing (B4)")
    func parameterEncoder_missingURL_throwsInvalidURL() {
        var original = URLRequest(url: url)
        original.url = nil

        #expect {
            try URLEncodedFormParameterEncoder.default.encode(Page(page: 1), into: original)
        } throws: { error in
            guard case HTTPRequestError.invalidURL = error else { return false }
            return true
        }
    }

    @Test("given unencodable parameters, when encoded, then encodingFailed is thrown")
    func parameterEncoder_unencodable_throwsEncodingFailed() {
        #expect {
            try URLEncodedFormParameterEncoder.default.encode(["value": Double.infinity], into: request(url, method: .get))
        } throws: { error in
            guard case HTTPRequestError.encodingFailed = error else { return false }
            return true
        }
    }

    // MARK: - Depth

    @Test("given parameters nested 32 levels deep, when encoded, then they encode")
    func depth_atLimit_encodes() throws {
        let pairs = try URLEncodedFormEncoder().encodedPairs(Nesting(depth: 31))

        #expect(pairs.count == 1)
        #expect(pairs.first?.key.hasSuffix("[leaf]") == true)
    }

    @Test("given parameters nested 33 levels deep, when encoded, then encodingFailed is thrown")
    func depth_aboveLimit_throwsEncodingFailed() {
        #expect {
            try URLEncodedFormParameterEncoder.default.encode(Nesting(depth: 32), into: request(url, method: .get))
        } throws: { error in
            guard case HTTPRequestError.encodingFailed = error else { return false }
            return true
        }
    }

    @Test("given parameters nested 1,000 levels deep, when encoded, then encodingFailed is thrown without exhausting the stack")
    func depth_thousandLevels_throwsEncodingFailed() {
        #expect {
            try URLEncodedFormParameterEncoder.default.encode(Nesting(depth: 1_000), into: request(url, method: .post))
        } throws: { error in
            guard case HTTPRequestError.encodingFailed = error else { return false }
            return true
        }
    }
}
