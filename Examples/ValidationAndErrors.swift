//
//  ValidationAndErrors.swift
//  Netti
//

import Foundation
import NettiTesting

/// Turning validation on, custom rules, a per-endpoint override, and catching each kind of error.
///
/// Runs offline: a `StubServer` answers every request.
func validationAndErrorsExample() async throws {
    struct APIError: Decodable, Sendable {
        let message: String
    }

    let server = StubServer()
    let base = "https://api.example.com/v1"
    server.stub(.get, "\(base)/users/1", json: User(id: 1, name: "Ada"))
    server.stub(.get, "\(base)/users/404", status: 404, body: Data(#"{"message": "no such user"}"#.utf8))
    server.stub(.get, "\(base)/users/500", status: 500)
    server.stub(.get, "\(base)/users/bad", body: Data(#"{"unexpected": true}"#.utf8))
    server.stub(.get, "\(base)/users/offline", error: URLError(.notConnectedToInternet))
    server.stub(.get, "\(base)/health", status: 503)
    let netti = server.netti()

    // MARK: - Default: every response is returned

    let lenient = try await netti.get(UserAPI.user(404))
    report("returned -> status \(lenient.statusCode ?? 0), no throw")

    // MARK: - Opt in: unacceptable responses throw

    netti.validation = ResponseValidation()

    do {
        try await netti.get(UserAPI.user(404))
    } catch .unacceptableStatusCode(404, let response) {
        let apiError = try? JSONDecoder().decode(APIError.self, from: response.rawData ?? Data())
        report("404      -> \(apiError?.message ?? "nil")")
    } catch {
        report("404      -> unexpected \(error)")
    }

    do {
        try await netti.get(UserAPI.user(500))
    } catch {
        report("500      -> \(error.response?.statusCode ?? 0) via error.response")
    }

    // MARK: - Decoding failure on a 2xx

    do {
        let _: User? = try await netti.get(BadUserAPI.bad).data
    } catch .decodingFailed(_, let response) {
        report("decode   -> decodingFailed, raw body kept: \(response?.rawData?.count ?? 0) bytes")
    } catch {
        report("decode   -> unexpected \(error)")
    }

    // MARK: - Transport failure

    do {
        try await netti.get(OfflineAPI.offline)
    } catch .requestFailed(let urlError) {
        report("offline  -> requestFailed(\(urlError.code == .notConnectedToInternet ? "notConnectedToInternet" : "other"))")
    } catch {
        report("offline  -> unexpected \(error)")
    }

    // MARK: - Custom rule

    netti.validation = ResponseValidation(custom: { response in
        if response.response?.value(forHTTPHeaderField: "X-Request-ID") == nil {
            throw MissingRequestID()
        }
    })
    do {
        try await netti.get(UserAPI.user(1))
    } catch .validationFailed(let reason, _) {
        report("custom   -> validationFailed(\(type(of: reason)))")
    } catch {
        report("custom   -> unexpected \(error)")
    }

    // MARK: - Per-endpoint override

    // `.disabled` accepts every response, even while the client validates.
    let health = try await netti.get(HealthAPI.status)
    report("override -> status \(health.statusCode ?? 0) returned despite client validation")
    try expect(health.statusCode == 503, "the endpoint override should accept the 503")
}

// MARK: - Helpers

private struct MissingRequestID: Error {}

private enum HealthAPI: HTTPRequest {
    case status

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String { "health" }
    var headers: HTTPHeaders { [] }
    var validation: ResponseValidation? { .disabled }
}

private enum BadUserAPI: HTTPRequest {
    case bad

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String { "users/bad" }
    var headers: HTTPHeaders { [] }
}

private enum OfflineAPI: HTTPRequest {
    case offline

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String { "users/offline" }
    var headers: HTTPHeaders { [] }
}
