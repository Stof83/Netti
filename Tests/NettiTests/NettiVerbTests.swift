import Foundation
import Testing

@testable import Netti
import NettiTesting

@Suite("Netti verbs", .timeLimit(.minutes(1)))
struct NettiVerbTests {

    private struct Query: Encodable, Sendable {
        let ids: [Int]
        let active: Bool
    }

    private struct Page: Encodable, Sendable {
        let page: Int
    }

    private struct PageNumber: Encodable, Sendable {
        let pageNumber: Int
    }

    private struct PriceFilter: Encodable, Sendable {
        struct PriceRange: Encodable, Sendable {
            let minPrice: Int
        }
        let priceRange: PriceRange
    }

    private struct Search: Encodable, Sendable {
        let q: String
    }

    private struct Amount: Encodable, Sendable {
        let value: Decimal
    }

    // MARK: - Methods

    @Test("given each verb, when called, then the request carries its HTTP method")
    func verbs_mapToMethods() async throws {
        let service = StubNetworkService()
        let netti = makeNetti(service: service)
        let endpoint = TestEndpoint()

        try await netti.get(endpoint)
        try await netti.head(endpoint)
        try await netti.delete(endpoint)
        try await netti.options(endpoint)
        try await netti.post(endpoint)
        try await netti.put(endpoint)
        try await netti.patch(endpoint, body: Widget(id: 1, name: "a"))

        #expect(service.requests.map(\.httpMethod) == ["GET", "HEAD", "DELETE", "OPTIONS", "POST", "PUT", "PATCH"])
        #expect(service.requests.allSatisfy { $0.url?.absoluteString == "https://api.test/v1/items" })
    }

    @Test("given a GET with no arguments, when sent, then the decoded response is returned")
    func get_decodes() async throws {
        let service = StubNetworkService { try .json(for: $0, Widget(id: 7, name: "seven")) }

        let widget: Widget? = try await makeNetti(service: service).get(TestEndpoint()).data

        #expect(widget == Widget(id: 7, name: "seven"))
    }

    // MARK: - Query

    @Test("given a URL with a query, when a GET adds one, then both are kept")
    func query_keepsExistingItems() async throws {
        let service = StubNetworkService()
        let urlWithQuery = URLEndpoint(URL(string: "https://api.test/items?lang=it")!)

        try await makeNetti(service: service).get(urlWithQuery, query: Page(page: 2))

        let query = try #require(service.requests.first?.url?.query)
        #expect(query.contains("lang=it"))
        #expect(query.contains("page=2"))
    }

    @Test("given reserved characters, when encoded into the query, then they are percent-escaped")
    func query_escapesReservedCharacters() async throws {
        let service = StubNetworkService()

        try await makeNetti(service: service).get(TestEndpoint(), query: Search(q: "a+b&c"))

        #expect(service.requests.first?.url?.query == "q=a%2Bb%26c")
    }

    @Test("given arrays and booleans, when encoded with defaults, then ids repeat and booleans are literal")
    func query_encodesArraysAndBooleans() async throws {
        let service = StubNetworkService()

        try await makeNetti(service: service).delete(TestEndpoint(), query: Query(ids: [1, 2], active: true))

        let query = try #require(service.requests.first?.url?.query)
        #expect(query.contains("ids=1&ids=2"))
        #expect(query.contains("active=true"))
        #expect(service.requests.first?.httpBody == nil)
    }

    // MARK: - Query Keys

    @Test("given the default JSONManager, when GET, HEAD and DELETE send a query, then keys are snake cased")
    func queryKeys_defaultManager_snakeCased() async throws {
        let service = StubNetworkService()
        let netti = makeNetti(service: service, jsonManager: JSONManager())

        try await netti.get(TestEndpoint(), query: PageNumber(pageNumber: 2))
        try await netti.head(TestEndpoint(), query: PageNumber(pageNumber: 2))
        try await netti.delete(TestEndpoint(), query: PageNumber(pageNumber: 2))

        #expect(service.requests.map(\.url?.query) == ["page_number=2", "page_number=2", "page_number=2"])
    }

    @Test("given a JSONManager with default keys, when a GET sends a query, then keys are kept as declared")
    func queryKeys_defaultKeysManager_keptAsDeclared() async throws {
        let service = StubNetworkService()

        try await makeNetti(service: service, jsonManager: JSONManager(keyStrategy: .useDefaultKeys))
            .get(TestEndpoint(), query: PageNumber(pageNumber: 2))

        #expect(service.requests.first?.url?.query == "pageNumber=2")
    }

    @Test("given a JSONManager with a custom key strategy, when a GET sends a query, then the custom key is used")
    func queryKeys_customManager_usesCustomKey() async throws {
        let service = StubNetworkService()
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { codingPath in
            FormCodingKey(stringValue: "x_" + (codingPath.last?.stringValue ?? ""))
        }

        try await makeNetti(service: service, jsonManager: JSONManager(encoder: encoder, decoder: JSONDecoder()))
            .get(TestEndpoint(), query: PageNumber(pageNumber: 2))

        #expect(service.requests.first?.url?.query == "x_pageNumber=2")
    }

    @Test("given the default JSONManager, when a nested query is sent, then every key component is snake cased")
    func queryKeys_nested_convertedPerComponent() async throws {
        let service = StubNetworkService()

        try await makeNetti(service: service, jsonManager: JSONManager())
            .get(TestEndpoint(), query: PriceFilter(priceRange: .init(minPrice: 5)))

        #expect(service.requests.first?.url?.query == "price_range%5Bmin_price%5D=5")
    }

    // MARK: - Body

    @Test("given a top-level array, when posted, then the body is a JSON array with a JSON content type")
    func body_topLevelArray() async throws {
        let service = StubNetworkService()

        try await makeNetti(service: service).post(TestEndpoint(), body: [Widget(id: 1, name: "a"), Widget(id: 2, name: "b")])

        let request = try #require(service.requests.first)
        let body = try JSONDecoder().decode([Widget].self, from: try #require(request.httpBody))
        #expect(body == [Widget(id: 1, name: "a"), Widget(id: 2, name: "b")])
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.url?.query == nil)
    }

    @Test("given a decimal 0.1, when put, then the JSON body holds 0.1 exactly")
    func body_keepsDecimalPrecision() async throws {
        let service = StubNetworkService()

        try await makeNetti(service: service).put(TestEndpoint(), body: Amount(value: Decimal(string: "0.1")!))

        let body = try #require(service.requests.first?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"value":0.1}"#)
    }

    @Test("given an endpoint content type, when a body is posted, then the endpoint's content type is kept")
    func body_keepsEndpointContentType() async throws {
        let service = StubNetworkService()
        var endpoint = TestEndpoint()
        endpoint.headers = ["Content-Type": "application/vnd.api+json"]

        try await makeNetti(service: service).post(endpoint, body: Widget(id: 1, name: "a"))

        #expect(service.requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/vnd.api+json")
    }

    // MARK: - Empty

    @Test("given a 204 with no body, when a DELETE ignores the response, then it succeeds")
    func delete_empty204() async throws {
        let service = StubNetworkService { .stub(for: $0, status: 204) }

        let response = try await makeNetti(service: service).delete(TestEndpoint())

        #expect(response.statusCode == 204)
        #expect(response.data != nil)
    }

    @Test("given a non-JSON acknowledgement body, when the response type is Empty, then it succeeds")
    func emptyResponse_ignoresBody() async throws {
        let service = StubNetworkService { .stub(for: $0, body: Data("OK".utf8)) }

        let response: HTTPResponse<Empty> = try await makeNetti(service: service).post(TestEndpoint())

        #expect(response.rawData == Data("OK".utf8))
    }

    // MARK: - Raw Requests

    @Test("given a prebuilt URLRequest, when sent, then it runs through adapters and is decoded")
    func sendURLRequest_usesPipeline() async throws {
        let service = StubNetworkService { try .json(for: $0, Widget(id: 3, name: "raw")) }
        let adapter = ClosureAdapter { request in
            var request = request
            request.setValue("1", forHTTPHeaderField: "X-Adapted")
            return request
        }
        let netti = makeNetti(service: service, interceptors: [adapter])

        let response: HTTPResponse<Widget> = try await netti.send(URLRequest(url: TestURL.api))

        #expect(response.data == Widget(id: 3, name: "raw"))
        #expect(service.requests.first?.value(forHTTPHeaderField: "X-Adapted") == "1")
    }

    @Test("given an endpoint and a body, when a POST is built, then method, headers and body are set and nothing is sent")
    func buildRequest_sendsNothing() throws {
        let service = StubNetworkService()
        var endpoint = TestEndpoint()
        endpoint.headers = ["X-Client": "ios"]

        let request = try makeNetti(service: service).buildRequest(endpoint, parameters: Widget(id: 1, name: "a"), method: .post)

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Client") == "ios")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try JSONDecoder().decode(Widget.self, from: try #require(request.httpBody)) == Widget(id: 1, name: "a"))
        #expect(service.requests.isEmpty)
    }
}

