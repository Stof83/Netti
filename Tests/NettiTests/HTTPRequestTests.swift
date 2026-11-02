import Foundation
import Testing

@testable import Netti

private struct Endpoint: HTTPRequest {
    var baseURL: URL? = URL(string: "https://api.test")
    var basePath = "v1"
    var path = "users"
    var headers: HTTPHeaders = ["Accept": "application/json"]
    var timeoutInterval: TimeInterval = 15
}

@Suite("HTTPRequest")
struct HTTPRequestTests {
    @Test("given an endpoint that sets nothing, when validation and retryPolicy are read, then both inherit the client's (nil)")
    func overrides_defaultToInherit() {
        #expect(Endpoint().validation == nil)
        #expect(Endpoint().retryPolicy == nil)
    }

    @Test("given a base URL, when requestURL is read, then base path and path are appended")
    func requestURL_appendsPaths() throws {
        #expect(try Endpoint().requestURL.absoluteString == "https://api.test/v1/users")
    }

    @Test("given no base URL, when the request is built, then invalidURL is thrown and the process does not crash (B9)")
    func asURLRequest_missingBaseURL_throwsInvalidURL() {
        var endpoint = Endpoint()
        endpoint.baseURL = nil

        #expect {
            try endpoint.asURLRequest(for: .get)
        } throws: { error in
            guard case HTTPRequestError.invalidURL = error else { return false }
            return true
        }
    }

    @Test("given an endpoint, when the request is built, then method, headers and timeout are applied")
    func asURLRequest_appliesConfiguration() throws {
        let urlRequest = try Endpoint().asURLRequest(for: .patch)

        #expect(urlRequest.httpMethod == "PATCH")
        #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(urlRequest.timeoutInterval == 15)
    }

    @Test("given requests differing only in query, when keys are computed, then they differ (B2)")
    func cacheKey_differentQuery_differs() throws {
        let pageOne = URLRequest(url: try #require(URL(string: "https://api.test/users?page=1")))
        let pageTwo = URLRequest(url: try #require(URL(string: "https://api.test/users?page=2")))

        #expect(pageOne.cacheKey != pageTwo.cacheKey)
    }

    @Test("given the same query in a different order, when keys are computed, then they match")
    func cacheKey_queryOrder_isIgnored() throws {
        let ordered = URLRequest(url: try #require(URL(string: "https://api.test/users?a=1&b=2")))
        let reversed = URLRequest(url: try #require(URL(string: "https://api.test/users?b=2&a=1#section")))

        #expect(ordered.cacheKey == reversed.cacheKey)
    }

    @Test("given different methods or bodies, when keys are computed, then they differ")
    func cacheKey_methodAndBody_areIncluded() throws {
        let url = try #require(URL(string: "https://api.test/users"))
        var get = URLRequest(url: url)
        get.httpMethod = "GET"
        var post = URLRequest(url: url)
        post.httpMethod = "POST"
        post.httpBody = Data(#"{"id":1}"#.utf8)
        var otherPost = post
        otherPost.httpBody = Data(#"{"id":2}"#.utf8)

        #expect(get.cacheKey != post.cacheKey)
        #expect(post.cacheKey != otherPost.cacheKey)
    }

    @Test("given an endpoint, when its cache key is computed, then it equals the built request's key")
    func cacheKey_endpoint_matchesBuiltRequest() throws {
        let endpoint = Endpoint()

        #expect(try endpoint.cacheKey(for: .get) == endpoint.asURLRequest(for: .get).cacheKey)
    }
}
