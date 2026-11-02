//
//  RequestsAndVerbs.swift
//  Netti
//

import Foundation
import NettiTesting

/// Every HTTP verb, a query, a JSON body, reading the status before the body, and sending a
/// prebuilt `URLRequest`.
///
/// Runs offline: a `StubServer` answers every request.
func requestsAndVerbsExample() async throws {
    let server = StubServer()
    let base = "https://api.example.com/v1"
    server.stub(.get, "\(base)/users/42", json: User(id: 42, name: "Ada"))
    server.stub(.get, "\(base)/users", json: [User(id: 1, name: "Ada"), User(id: 2, name: "Grace")])
    server.stub(.post, "\(base)/users", json: User(id: 3, name: "Linus"), status: 201)
    server.stub(.put, "\(base)/users/42", json: User(id: 42, name: "Ada Lovelace"))
    server.stub(.delete, "\(base)/users/42", status: 204)
    server.stub(.head, "\(base)/users", headers: ["X-Total-Count": "2"])
    server.stub(.get, "\(base)/users/99", status: 401, body: Data("nope".utf8))
    let netti = server.netti()

    // MARK: - Verbs

    // Name the type you expect; without it the overload that ignores the body is chosen.
    let user: User? = try await netti.get(UserAPI.user(42)).data
    report("GET    -> \(user?.name ?? "nil")")

    let created: HTTPResponse<User> = try await netti.post(UserAPI.users, body: NewUser(name: "Linus"))
    report("POST   -> \(created.statusCode ?? 0) \(created.data?.name ?? "nil")")

    let updated: User? = try await netti.put(UserAPI.user(42), body: NewUser(name: "Ada Lovelace")).data
    report("PUT    -> \(updated?.name ?? "nil")")

    try await netti.delete(UserAPI.user(42))
    let head = try await netti.head(UserAPI.users)
    report("HEAD   -> X-Total-Count \(head.response?.value(forHTTPHeaderField: "X-Total-Count") ?? "nil")")

    // MARK: - Query

    let users: [User]? = try await netti.get(UserAPI.users, query: UserFilter(ids: [1, 2], isActive: true)).data
    let query = server.requests.last?.url?.query ?? ""
    report("query  -> \(users?.count ?? 0) users, sent ?\(query)")
    try expect(query == "ids=1&ids=2&is_active=true", "unexpected query: \(query)")

    // MARK: - Status before body

    // A non-2xx response is returned, not thrown; `data` is nil because "nope" is not a User.
    let rejected: HTTPResponse<User> = try await netti.get(UserAPI.user(99))
    report("status -> \(rejected.statusCode ?? 0), decoded: \(rejected.data == nil ? "no" : "yes"), raw: \(rejected.rawData?.count ?? 0) bytes")

    // MARK: - Prebuilt request

    // `send(_:)` runs a `URLRequest` through the same pipeline; use it for custom headers,
    // custom encoding or verbs without a method on the client.
    var request = try netti.buildRequest(UserAPI.users, method: .get)
    request.setValue("examples/1.0", forHTTPHeaderField: "X-Client")
    let sent: [User]? = try await netti.send(request).data
    report("send   -> \(sent?.count ?? 0) users via a prebuilt request")

    // MARK: - Decode data you already have

    let fixture = Data(#"{"id": 1, "name": "Ada"}"#.utf8)
    let decoded: User? = try netti.decode(fixture, request: nil).data
    report("decode -> \(decoded?.name ?? "nil")")
}
