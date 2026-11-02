//
//  StreamingAndSSE.swift
//  Netti
//

import Foundation
import NettiTesting

/// Reading a response body as it arrives: Server-Sent Events, lines, and a POST stream.
///
/// Runs offline: a `StubNetworkService` plays a server that sends chunks. `StubServer` cannot
/// stream, so streams need the stub engine.
func streamingAndSSEExample() async throws {
    let service = StubNetworkService(bytes: { request in
        let chunks: [String]
        if request.httpMethod == "POST" {
            chunks = ["data: tok", "en-1\n\ndata: token-2\n\n"] // a chunk may end mid-line
        } else if request.url?.path.hasSuffix("/logs") == true {
            chunks = ["boot ok\r\nlisten", "ing on 8080\n"]
        } else {
            chunks = [": keep-alive\n\n", "event: price\nid: 7\ndata: 41.5\n\n", "data: first\ndata: second\n\n"]
        }
        return HTTPStreamResponse(
            request: request,
            response: request.url.flatMap { HTTPURLResponse(url: $0, statusCode: 200, httpVersion: nil, headerFields: nil) },
            body: AsyncThrowingStream { continuation in
                chunks.forEach { continuation.yield(Data($0.utf8)) }
                continuation.finish()
            }
        )
    })
    let netti = Netti(service: service)
    netti.isLoggingEnabled = false

    // MARK: - Server-Sent Events

    var events: [ServerSentEvent] = []
    for try await event in try await netti.stream(FeedAPI.live).serverSentEvents {
        events.append(event)
    }
    report("sse   -> \(events.map { "\($0.event ?? "message"):\($0.data.replacingOccurrences(of: "\n", with: "+"))" })")
    try expect(events.count == 2, "expected 2 events, got \(events.count)")

    // MARK: - Lines

    // Iterate only one view of a body: bytes, lines or events.
    var lines: [String] = []
    for try await line in try await netti.stream(FeedAPI.logs).lines {
        lines.append(line)
    }
    report("lines -> \(lines)")
    try expect(lines == ["boot ok", "listening on 8080"], "unexpected lines: \(lines)")

    // MARK: - Another method

    // A stream with a body or a verb other than GET starts from a built request.
    var request = try netti.buildRequest(FeedAPI.live, parameters: NewUser(name: "Ada"), method: .post)
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    var tokens: [String] = []
    for try await event in try await netti.stream(request).serverSentEvents {
        tokens.append(event.data)
    }
    report("post  -> \(tokens)")
    try expect(tokens == ["token-1", "token-2"], "unexpected tokens: \(tokens)")
}

// MARK: - Helpers

private enum FeedAPI: HTTPRequest {
    case live
    case logs

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String {
        switch self {
            case .live: "feed"
            case .logs: "logs"
        }
    }
    var headers: HTTPHeaders { [] }
}
