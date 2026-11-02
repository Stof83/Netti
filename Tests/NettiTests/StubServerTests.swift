import Foundation
import Testing

import Netti
import NettiTesting

@Suite("StubServer", .timeLimit(.minutes(1)))
struct StubServerTests {

    private struct Profile: Codable, Equatable, Sendable {
        let fullName: String
    }

    private let endpoint = TestEndpoint()
    private let itemsURL = "https://api.test/v1/items"

    // MARK: - Stubbed responses

    @Test("given a stubbed GET, when called, then the decoded stub body is returned and nothing leaves the process")
    func stubbedGet_returnsDecodedBody() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL, json: Profile(fullName: "Ada Lovelace"))

        let response: HTTPResponse<Profile> = try await server.netti().get(endpoint)

        #expect(response.statusCode == 200)
        #expect(response.data == Profile(fullName: "Ada Lovelace"))
        #expect(server.requests.count == 1)
    }

    @Test("given a JSON stub, when decoded by the server's client, then the key strategy round-trips")
    func jsonStub_usesTheServersJSONManager() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL, json: Profile(fullName: "Grace"))

        let raw = try await server.netti().get(endpoint) as HTTPResponse<Empty>
        let body = try #require(raw.rawData.flatMap { String(data: $0, encoding: .utf8) })

        #expect(body.contains("full_name"))
    }

    @Test("given status, headers and body, when called, then the response carries them")
    func rawStub_isServedVerbatim() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL, status: 404, headers: ["X-Reason": "gone"], body: Data("missing".utf8))

        let response: HTTPResponse<Empty> = try await server.netti().get(endpoint)

        #expect(response.statusCode == 404)
        #expect(response.response?.value(forHTTPHeaderField: "X-Reason") == "gone")
        #expect(response.rawData == Data("missing".utf8))
    }

    @Test("given a HEAD stub with a body, when called, then no body is delivered")
    func headStub_dropsBody() async throws {
        let server = StubServer()
        server.stub(.head, itemsURL, headers: ["X-Count": "3"], body: Data("ignored".utf8))

        let response = try await server.netti().head(endpoint)

        #expect(response.response?.value(forHTTPHeaderField: "X-Count") == "3")
        #expect(response.rawData?.isEmpty != false)
    }

    @Test("given a stubbed error, when called, then the request fails with it")
    func stubbedError_failsTheRequest() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL, error: URLError(.notConnectedToInternet))

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await server.netti().get(endpoint)
        }

        #expect(error?.urlErrorCode == .notConnectedToInternet)
    }

    @Test("given a delayed stub, when called, then the answer waits")
    func delayedStub_waits() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL, delay: .milliseconds(150))
        let netti = server.netti()
        let start = ContinuousClock.now

        try await netti.get(endpoint)

        #expect(ContinuousClock.now - start >= .milliseconds(140))
    }

    // MARK: - Unstubbed

    @Test("given no matching stub, when called, then it fails naming the method and URL")
    func unstubbedRequest_namesMethodAndURL() async throws {
        let server = StubServer()
        server.stub(.post, itemsURL)

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await server.netti().get(endpoint)
        }

        let message = error?.urlError?.localizedDescription
        #expect(message == "No stub registered for GET \(itemsURL)")
        #expect(server.requests.count == 1, "an unmatched request is still recorded")
    }

    // MARK: - Matching

    @Test("given a stub without a query, when the request has one, then it still matches")
    func stubWithoutQuery_matchesAnyQuery() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL, status: 202)

        let response: HTTPResponse<Empty> = try await server.netti().get(endpoint, query: ["page": 2])

        #expect(response.statusCode == 202)
    }

    @Test("given a stub with a query, when the request differs, then only the exact query matches")
    func stubWithQuery_matchesExactly() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL, status: 202)
        server.stub(.get, "\(itemsURL)?page=2", status: 203)
        let netti = server.netti()

        let exact: HTTPResponse<Empty> = try await netti.get(endpoint, query: ["page": 2])
        let other: HTTPResponse<Empty> = try await netti.get(endpoint, query: ["page": 3])

        #expect(exact.statusCode == 203)
        #expect(other.statusCode == 202)
    }

    @Test("given two stubs for one URL, when called, then the newest wins")
    func newestStub_wins() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL, status: 200)
        server.stub(.get, itemsURL, status: 201)

        let response: HTTPResponse<Empty> = try await server.netti().get(endpoint)

        #expect(response.statusCode == 201)
    }

    @Test("given a stub limited to two uses, when called three times, then the older stub answers the third")
    func timesLimit_fallsBackToOlderStub() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL, status: 200)
        server.stub(.get, itemsURL, status: 503, times: 2)
        let netti = server.netti(deduplicatesRequests: false)

        var statuses: [Int?] = []
        for _ in 0..<3 {
            let response: HTTPResponse<Empty> = try await netti.get(endpoint)
            statuses.append(response.statusCode)
        }

        #expect(statuses == [503, 503, 200])
    }

    @Test("given a retry policy, when the first attempts fail, then the retry succeeds without waiting")
    func retryAgainstLimitedStub_succeeds() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL, status: 200)
        server.stub(.get, itemsURL, status: 503, times: 2)
        let netti = server.netti(retryPolicy: RetryPolicy())

        let response: HTTPResponse<Empty> = try await netti.get(endpoint)

        #expect(response.statusCode == 200)
        #expect(server.requests.count == 3)
    }

    // MARK: - Inspection

    @Test("given a posted body, when inspected, then the recorded request decodes it")
    func recordedRequest_decodesBody() async throws {
        let server = StubServer()
        server.stub(.post, itemsURL, status: 201)

        try await server.netti().post(endpoint, body: Profile(fullName: "Alan Turing"))

        let recorded = try #require(server.requests.first)
        #expect(recorded.method == "POST")
        #expect(recorded.url?.absoluteString == itemsURL)
        #expect(try recorded.decodedBody() as Profile == Profile(fullName: "Alan Turing"))
    }

    @Test("given a request without a body, when decoded, then it throws")
    func recordedRequest_withoutBody_throwsOnDecode() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL)
        try await server.netti().get(endpoint)

        let recorded = try #require(server.requests.first)

        #expect(recorded.body == nil)
        #expect(throws: (any Error).self) { try recorded.decodedBody() as Profile }
    }

    @Test("given request headers, when inspected, then they are recorded without the routing header")
    func recordedRequest_keepsHeaders_dropsRoutingHeader() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL)
        var endpoint = endpoint
        endpoint.headers = ["X-Trace": "abc"]

        try await server.netti().get(endpoint)

        let headers = try #require(server.requests.first?.headers)
        #expect(headers["X-Trace"] == "abc")
        #expect(headers.keys.contains { $0.lowercased().hasPrefix("x-netti-stub") } == false)
    }

    @Test("given an upload, when inspected, then the streamed body is recorded")
    func upload_recordsStreamedBody() async throws {
        let server = StubServer()
        server.stub(.post, itemsURL)
        let payload = Data("binary-payload".utf8)

        try await server.netti().upload(endpoint, data: payload)

        #expect(server.requests.first?.body == payload)
    }

    @Test("given recordings and stubs, when reset, then both are gone")
    func reset_clearsStubsAndRequests() async throws {
        let server = StubServer()
        server.stub(.get, itemsURL)
        try await server.netti().get(endpoint)

        server.reset()

        #expect(server.requests.isEmpty)
        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await server.netti().get(endpoint)
        }
        #expect(error?.urlError != nil)
    }

    // MARK: - Isolation

    @Test("given two servers stubbing one URL, when used in parallel, then each client gets its own stub")
    func parallelServers_areIsolated() async throws {
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let server = StubServer()
                    server.stub(.get, "https://api.test/v1/items", json: Profile(fullName: "client \(index)"), delay: .milliseconds(Int.random(in: 0...20)))
                    let response: HTTPResponse<Profile>? = try? await server.netti().get(TestEndpoint())
                    return response?.data == Profile(fullName: "client \(index)") && server.requests.count == 1
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.count == 20)
        #expect(results.allSatisfy { $0 })
    }

    @Test("given a server that is gone, when its configuration is still used, then requests fail clearly")
    func releasedServer_failsClearly() async throws {
        var server: StubServer? = StubServer()
        let configuration = try #require(server?.configuration)
        server = nil
        let service = URLSessionNetworkService(configuration: configuration)

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Data> in
            try await service.data(for: URLRequest(url: URL(string: "https://api.test/v1/items")!))
        }

        #expect(error?.urlErrorCode == .cannotConnectToHost)
    }

    // MARK: - Connectivity

    @Test("given a stub connectivity, when it changes, then observers see the new state")
    func stubConnectivity_publishesChanges() async throws {
        let connectivity = StubConnectivity(.disconnected)
        var updates = connectivity.statusUpdates().makeAsyncIterator()

        #expect(await updates.next() == .disconnected)
        connectivity.set(.connected)

        #expect(await updates.next() == .connected)
        #expect(connectivity.currentStatus == .connected)
    }
}

private extension HTTPRequestError {
    var urlError: URLError? {
        if case .requestFailed(let urlError) = self {
            return urlError
        }
        return nil
    }
}
