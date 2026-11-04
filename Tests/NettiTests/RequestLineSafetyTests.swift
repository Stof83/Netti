//
//  RequestLineSafetyTests.swift
//  Netti
//

import Foundation
import NettiTesting
import Testing

@testable import Netti

/// Wire-level characterization of the request line: whatever a caller puts in a path or query, the
/// bytes a real server receives never hold a raw control character.
@Suite("Request line safety")
struct RequestLineSafetyTests {

    // MARK: - Query

    @Test(
        "given a control character in a query value, when sent with get, then the request line holds it percent-encoded",
        arguments: Self.controlCodes
    )
    func get_queryValue_isPercentEncoded(code: UInt8) async throws {
        let server = try await LocalHTTPServer.start { _ in .text("ok") }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))
        let value = "a\(Self.character(code))b"

        try await netti.get(Self.endpoint(server, path: "search"), query: Query(q: value))

        let request = try #require(server.requests.first)
        Self.expectNoRawControl(in: request)
        #expect(Self.decodedQueryValue(of: request) == value)
    }

    @Test(
        "given a control character in a query value, when sent with delete, then the request line holds it percent-encoded",
        arguments: Self.controlCodes
    )
    func delete_queryValue_isPercentEncoded(code: UInt8) async throws {
        let server = try await LocalHTTPServer.start { _ in .text("ok") }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))
        let value = "a\(Self.character(code))b"

        try await netti.delete(Self.endpoint(server, path: "search"), query: Query(q: value))

        let request = try #require(server.requests.first)
        Self.expectNoRawControl(in: request)
        #expect(Self.decodedQueryValue(of: request) == value)
    }

    @Test("given a CRLF and a forged header in a query value, when sent, then the server sees %0D%0A and no injected header")
    func get_queryCRLF_cannotInjectHeader() async throws {
        let server = try await LocalHTTPServer.start { _ in .text("ok") }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))

        try await netti.get(Self.endpoint(server, path: "search"), query: Query(q: "a\r\nHost: evil.example"))

        let request = try #require(server.requests.first)
        #expect(request.target.contains("%0D%0A"))
        #expect(request.header("host")?.contains("evil.example") != true)
        Self.expectNoRawControl(in: request)
    }

    @Test("given a newline as ordinary text in a query value, when sent, then the server decodes the same value")
    func get_queryNewline_roundTrips() async throws {
        let server = try await LocalHTTPServer.start { _ in .text("ok") }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))

        try await netti.get(Self.endpoint(server, path: "search"), query: Query(q: "line one\nline two"))

        let request = try #require(server.requests.first)
        #expect(Self.decodedQueryValue(of: request) == "line one\nline two")
    }

    // MARK: - Path

    @Test(
        "given a control character in a path segment, when sent with get, then the request line holds it percent-encoded",
        arguments: Self.controlCodes
    )
    func get_pathSegment_isPercentEncoded(code: UInt8) async throws {
        let server = try await LocalHTTPServer.start { _ in .text("ok") }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))

        try await netti.get(Self.endpoint(server, path: "users/a\(Self.character(code))b"))

        let request = try #require(server.requests.first)
        Self.expectNoRawControl(in: request)
        #expect(request.path.removingPercentEncoding == "/v1/users/a\(Self.character(code))b")
    }

    // MARK: - Prebuilt Requests

    @Test(
        "given a prebuilt URLRequest built from text with a control character, when sent, then the wire never holds a raw one",
        arguments: Self.controlCodes
    )
    func send_prebuiltRequest_neverPutsRawControlOnTheWire(code: UInt8) async throws {
        let server = try await LocalHTTPServer.start { _ in .text("ok") }
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral))
        let text = "\(server.baseURL.absoluteString)/a\(Self.character(code))b?q=x\(Self.character(code))y"

        for url in Self.urls(from: text) {
            do {
                try await netti.send(URLRequest(url: url))
            } catch {
                #expect(isInvalidURL(error), "unexpected error for \(code): \(error)")
            }
        }

        for request in server.requests {
            Self.expectNoRawControl(in: request)
        }
    }

    // MARK: - Helpers

    /// U+0000 to U+001F and U+007F.
    static let controlCodes: [UInt8] = Array(0...0x1F) + [0x7F]

    static func character(_ code: UInt8) -> Character {
        Character(Unicode.Scalar(code))
    }

    static func endpoint(_ server: LocalHTTPServer, path: String) -> PathEndpoint {
        PathEndpoint(baseURL: server.baseURL, path: path)
    }

    /// Every way the test can turn text into a `URL`, dropping the ones Foundation refuses.
    static func urls(from text: String) -> [URL] {
        [
            URL(string: text),
            URL(dataRepresentation: Data(text.utf8), relativeTo: nil),
            URL(string: text, encodingInvalidCharacters: false),
        ].compactMap { $0 }
    }

    static func expectNoRawControl(in request: LocalHTTPServer.Request, sourceLocation: SourceLocation = #_sourceLocation) {
        let raw = request.target.unicodeScalars.filter { $0.value < 0x20 || $0.value == 0x7F }
        #expect(raw.isEmpty, "raw control characters in the request line: \(raw.map(\.value))", sourceLocation: sourceLocation)
    }

    static func decodedQueryValue(of request: LocalHTTPServer.Request) -> String? {
        URLComponents(string: "http://x\(request.target)")?.queryItems?.first { $0.name == "q" }?.value
    }
}

// MARK: - Fixtures

struct PathEndpoint: HTTPRequest {
    let baseURL: URL?
    let path: String
    var basePath: String { "v1" }
    var headers: HTTPHeaders { [:] }
}

private struct Query: Encodable, Sendable {
    let q: String
}

private func isInvalidURL(_ error: any Error) -> Bool {
    guard let error = error as? HTTPRequestError, case .invalidURL = error else {
        return false
    }
    return true
}
