//
//  Redirects.swift
//  Netti
//

import Foundation
import Netti
import NettiTesting

/// What each redirect handler decides when the server answers with a redirect.
///
/// Runs offline. `StubServer.redirect` answers with a real `302`, so the engine asks its
/// `RedirectHandler` and the outcome is observed, not assumed.
func redirectsExample() async throws {
    let old = "https://api.example.com/v1/users"
    let moved = "https://api.example.com/v2/users"
    let elsewhere = "https://cdn.example.net/users"

    // MARK: - .secure (the default)

    // Same origin: followed, and `Authorization` is kept.
    do {
        let server = StubServer()
        server.redirect(.get, from: old, to: moved)
        server.stub(.get, moved, json: [User(id: 1, name: "Ada")])
        let netti = client(server, redirectHandler: .secure)
        let users: [User]? = try await netti.get(FullURLRequest(url: old)).data
        let sent = server.requests.last?.headers["Authorization"]
        report("redirect -> .secure, same origin: followed, \(users?.count ?? 0) user, Authorization \(sent == nil ? "dropped" : "kept")")
        try expect(sent == "Bearer token", "same-origin redirect must keep Authorization")
    }

    // Another origin: followed, but `Authorization` and `Cookie` are not sent to the new host.
    do {
        let server = StubServer()
        server.redirect(.get, from: old, to: elsewhere)
        server.stub(.get, elsewhere, json: [User(id: 1, name: "Ada")])
        let netti = client(server, redirectHandler: .secure)
        let _: HTTPResponse<[User]> = try await netti.get(FullURLRequest(url: old))
        let first = server.requests.first?.headers
        let second = server.requests.last?.headers
        report("redirect -> .secure, other origin: first hop sent Cookie \(first?["Cookie"] == nil ? "no" : "yes"), second hop \(second?["Cookie"] == nil ? "none" : "yes")")
        try expect(first?["Cookie"] != nil && second?["Cookie"] == nil && second?["Authorization"] == nil, "cross-origin redirect must strip credentials")
    }

    // MARK: - .doNotFollow

    // The redirect response itself comes back, so the app can read `Location`.
    do {
        let server = StubServer()
        server.redirect(.get, from: old, to: moved)
        server.stub(.get, moved, json: [User(id: 1, name: "Ada")])
        let netti = client(server, redirectHandler: .doNotFollow)
        let response: HTTPResponse<Empty> = try await netti.get(UserAPI.users)
        let location = response.response?.value(forHTTPHeaderField: "Location") ?? "nil"
        report("redirect -> .doNotFollow: status \(response.statusCode ?? 0), Location \(location), \(server.requests.count) request")
        try expect(response.statusCode == 302 && server.requests.count == 1, "expected the 302, with no second request")
    }

    // MARK: - A custom handler

    // A custom handler replaces `.secure` entirely, so it takes on those protections itself:
    // here it follows only on the same host and marks the request it sends on.
    do {
        let server = StubServer()
        server.redirect(.get, from: old, to: moved)
        server.redirect(.get, from: "https://api.example.com/v1/files", to: elsewhere)
        server.stub(.get, moved, json: [User(id: 1, name: "Ada")])
        server.stub(.get, elsewhere, status: 200)
        let sameHostOnly = RedirectHandler { proposed, response in
            guard proposed.url?.host == response.url?.host else {
                return .doNotFollow
            }
            var request = proposed
            request.setValue("followed", forHTTPHeaderField: "X-Redirect")
            return .modify(request)
        }
        let netti = client(server, redirectHandler: sameHostOnly)

        let _: HTTPResponse<[User]> = try await netti.get(UserAPI.users)
        let marked = server.requests.last?.headers["X-Redirect"]
        report("redirect -> custom, same host: followed, X-Redirect \(marked ?? "missing")")
        try expect(marked == "followed", "the custom handler must have modified the request")

        let blocked: HTTPResponse<Empty> = try await netti.get(FullURLRequest(url: "https://api.example.com/v1/files"))
        report("redirect -> custom, other host: not followed, status \(blocked.statusCode ?? 0)")
        try expect(blocked.statusCode == 302, "a cross-host redirect must come back as received")
    }

    // MARK: - .follow

    // Follows everything unchanged, including to another origin: the explicit opt-out of `.secure`.
    do {
        let server = StubServer()
        server.redirect(.get, from: old, to: elsewhere)
        server.stub(.get, elsewhere, json: [User(id: 1, name: "Ada")])
        let netti = client(server, redirectHandler: .follow)
        let _: HTTPResponse<[User]> = try await netti.get(FullURLRequest(url: old))
        let cookie = server.requests.last?.headers["Cookie"]
        report("redirect -> .follow: followed to \(server.requests.last?.url?.host ?? "nil"), Cookie \(cookie == nil ? "dropped" : "sent")")
        try expect(cookie == "session=1", ".follow must send the Cookie on unchanged")
    }
}

// MARK: - Helpers

/// A client whose engine answers from `server` and asks `redirectHandler` about every redirect.
private func client(_ server: StubServer, redirectHandler: RedirectHandler) -> Netti {
    let netti = Netti(service: URLSessionNetworkService(configuration: server.configuration, redirectHandler: redirectHandler))
    netti.isLoggingEnabled = false
    return netti
}

/// A request to a full URL that carries a bearer `Authorization`.
private struct FullURLRequest: HTTPRequest {
    let url: String

    var baseURL: URL? { URL(string: url) }
    var basePath: String { "" }
    var path: String { "" }
    var headers: HTTPHeaders { [.authorization(bearerToken: "token"), HTTPHeader(name: "Cookie", value: "session=1")] }
}
