//
//  Testing.swift
//  Netti
//

import Foundation
import NettiTesting

/// Testing code that uses Netti without a network: stubs, recorded requests, failures, `times:`,
/// a stub engine that records what reaches it, a scripted WebSocket, and runtime sample data.
///
/// Runs offline, as every other example does; this one shows what each piece of `NettiTesting`
/// is for. `StubConnectivity` is shown in the CachingAndOffline example. In a real test, replace
/// `expect` with Swift Testing's `#expect`.
func testingExample() async throws {
    let base = "https://api.example.com/v1"

    // MARK: - Stub a response, inspect what was sent

    let server = StubServer()
    server.stub(.post, "\(base)/users", json: User(id: 9, name: "Ada"), status: 201)
    let netti = server.netti()

    let created: HTTPResponse<User> = try await netti.post(UserAPI.users, body: NewUser(name: "Ada"))
    let sent = try expectValue(server.requests.first, "no request recorded")
    let body: NewUser = try sent.decodedBody()
    report("stub     -> \(created.statusCode ?? 0) \(created.data?.name ?? "nil"); server received \(sent.method) with name \(body.name)")
    try expect(sent.method == "POST" && body.name == "Ada", "the recorded request is not what was sent")

    // MARK: - A request with no stub fails, and never reaches the network

    do {
        try await netti.get(UserAPI.user(1))
    } catch .requestFailed(let error) {
        report("no stub  -> \(error.localizedDescription)")
    } catch {
        report("no stub  -> unexpected \(error)")
    }

    // MARK: - The newest stub wins; `times:` hands over to an older one

    server.stub(.get, "\(base)/users/1", json: User(id: 1, name: "Ada"))
    server.stub(.get, "\(base)/users/1", status: 503, times: 2)
    let flaky = server.netti(retryPolicy: RetryPolicy())
    let recovered: HTTPResponse<User> = try await flaky.get(UserAPI.user(1))
    report("times    -> status \(recovered.statusCode ?? 0) after two 503s (retry delays are not waited out)")
    try expect(recovered.statusCode == 200, "expected the retry to succeed")

    // MARK: - Assert what reaches the engine

    let service = StubNetworkService(data: { try .json(for: $0, User(id: 1, name: "Ada")) })
    let direct = Netti(service: service)
    direct.isLoggingEnabled = false
    try await direct.get(UserAPI.user(1))
    report("engine   -> \(service.requests.count) request recorded: \(service.requests.first?.url?.path ?? "nil")")
    try expect(service.requests.count == 1, "expected one request at the engine")

    // MARK: - WebSockets

    let socket = StubWebSocketTransport(echoes: true)
    let chat = Netti(service: StubNetworkService(webSocket: { _ in socket }))
    chat.isLoggingEnabled = false
    let connection = try await chat.webSocket(UserAPI.users)
    try await connection.send("ping")
    var echoed: WebSocketMessage?
    for try await message in connection.messages {
        echoed = message
        break
    }
    report("socket   -> sent \(socket.sent.count) frame, echoed back: \(echoed == .text("ping"))")
    try expect(echoed == .text("ping"), "the stub socket did not echo")
    await connection.close()

    // MARK: - Sample data: mock an API at runtime, in DEBUG builds only

    #if DEBUG
    let preview = Netti(service: StubNetworkService())
    preview.isLoggingEnabled = false
    preview.usesSampleData = true
    preview.sampleDelay = .milliseconds(50)

    let profile: HTTPResponse<User> = try await preview.get(ProfileAPI.profile)
    report("sample   -> \(profile.statusCode ?? 0) \(profile.data?.name ?? "nil"), served without any request")
    try expect(profile.data == User(id: 1, name: "Ada"), "expected the sample")

    preview.validation = ResponseValidation()
    var rejectedStatus: Int?
    do {
        let _: HTTPResponse<User> = try await preview.get(ProfileAPI.missing)
    } catch .unacceptableStatusCode(let status, _) {
        rejectedStatus = status
    }
    report("sample   -> a sampled \(rejectedStatus ?? 0) goes through validation like a real one")
    try expect(rejectedStatus == 404, "expected the sampled 404 to throw")
    #endif
}

#if DEBUG
/// An endpoint with a fixture for each state a screen has to show.
private enum ProfileAPI: HTTPRequest {
    case profile
    case missing

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String { "users/1" }
    var headers: HTTPHeaders { [.accept("application/json")] }
    var sampleData: Data? {
        switch self {
            case .profile: Data(#"{"id": 1, "name": "Ada"}"#.utf8)
            case .missing: Data(#"{"message": "not found"}"#.utf8)
        }
    }
    var sampleStatusCode: Int { self == .missing ? 404 : 200 }
}
#endif
