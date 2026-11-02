//
//  FuzzHeaderTests.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/10/26.
//

import Foundation
import NettiTesting
import Testing

@testable import Netti

/// Seeded fuzzing of header handling (TM-14): with random header names and values, set on the
/// endpoint or by an adapter, no request ever leaves with CR, LF or NUL in a header; a request
/// carrying one fails with `encodingFailed(InvalidHeaderError)` and its description never shows the value.
@Suite("Fuzz: headers", .timeLimit(.minutes(30)))
struct FuzzHeaderTests {

    // MARK: - Building

    @Test("given random endpoint headers, when the request is built, then it throws for a non-token name or a control character and is clean otherwise")
    func randomEndpointHeaders_buildCleanOrThrow() async {
        let netti = makeNetti()

        await Fuzz.run("headers.build") { fuzz in
            let fields = HeaderGenerator.fields(using: &fuzz.random)
            let endpoint = TestEndpoint(headers: HTTPHeaders(fields.map { HTTPHeader(name: $0.name, value: $0.value) }))
            fuzz.input = FuzzCase.describe(fields)
            let isUnsafe = fields.contains(where: HeaderGenerator.isUnsafe)

            var results: [Result<URLRequest, HTTPRequestError>] = []
            do throws(HTTPRequestError) {
                results.append(.success(try endpoint.asURLRequest(for: .get)))
            } catch {
                results.append(.failure(error))
            }
            do throws(HTTPRequestError) {
                results.append(.success(try netti.buildRequest(endpoint, method: .post)))
            } catch {
                results.append(.failure(error))
            }

            for result in results {
                switch result {
                    case .success(let request):
                        fuzz.check(isUnsafe == false, "built a request from unsafe headers")
                        fuzz.check(HeaderGenerator.isClean(request), "built request carries CR, LF or NUL: \(String(describing: request.allHTTPHeaderFields))")
                    case .failure(let error):
                        fuzz.check(isUnsafe, "rejected safe headers: \(error)")
                        fuzz.check(isInvalidHeader(error), "threw \(error), not encodingFailed(InvalidHeaderError)")
                        checkRedacted(error, fields: fields, in: &fuzz)
                }
            }
        }
    }

    // MARK: - Sending

    /// Multiplier 0.25 (minimum 50): every case sends through a `URLSession` and `StubURLProtocol`.
    /// The per-case bound is wide: at 100k iterations the CPU-bound suites running beside this one
    /// can delay a URLSession callback by a minute (a stalled case replays alone in milliseconds).
    @Test("given random headers from the endpoint and an adapter, when sent on the URLSession engine, then no CR, LF or NUL reaches the server")
    func randomHeaders_sent_neverReachServerUnsafe() async {
        let iterations = Fuzz.iterations(multiplier: 0.25, minimum: 50)

        await Fuzz.run("headers.send", iterations: iterations, timeLimitPerCase: .seconds(180)) { fuzz in
            let endpointFields = HeaderGenerator.fields(using: &fuzz.random)
            let adapterFields = HeaderGenerator.fields(using: &fuzz.random)
            fuzz.input = "endpoint=\(FuzzCase.describe(endpointFields)) adapter=\(FuzzCase.describe(adapterFields))"
            // Foundation silently drops an adapter-set value holding CR or LF before Netti sees it,
            // so only what survives `allHTTPHeaderFields` must make the request fail.
            let isUnsafe = endpointFields.contains(where: HeaderGenerator.isUnsafe)
                || HeaderGenerator.isClean(HeaderGenerator.applying(adapterFields, to: makeURLRequest())) == false

            let server = StubServer()
            server.stub(.get, "https://api.test/v1/items")
            let adapter = ClosureAdapter { HeaderGenerator.applying(adapterFields, to: $0) }
            let netti = server.netti(interceptors: [adapter])
            let endpoint = TestEndpoint(headers: HTTPHeaders(endpointFields.map { HTTPHeader(name: $0.name, value: $0.value) }))

            do throws(HTTPRequestError) {
                try await netti.get(endpoint)
            } catch {
                if isUnsafe {
                    fuzz.check(isInvalidHeader(error), "unsafe headers failed with \(error), not encodingFailed(InvalidHeaderError)")
                }
            }

            fuzz.check(isUnsafe == false || server.requests.isEmpty, "\(server.requests.count) request(s) with unsafe headers reached the server")
            for recorded in server.requests {
                fuzz.check(HeaderGenerator.isClean(recorded.request), "server saw CR, LF or NUL: \(String(describing: recorded.request.allHTTPHeaderFields))")
            }
        }
    }

    // MARK: - Private Helpers

    private func isInvalidHeader(_ error: HTTPRequestError) -> Bool {
        guard case .encodingFailed(let underlying) = error else {
            return false
        }
        return underlying is InvalidHeaderError
    }

    /// The error names the header, never the value (TM-19). Only checked for values distinctive
    /// enough that they cannot appear in the names or the fixed text by chance.
    private func checkRedacted(_ error: HTTPRequestError, fields: [HeaderGenerator.Field], in fuzz: inout FuzzCase) {
        let text = "\(error) \(String(reflecting: error)) \(error.localizedDescription)"
        for field in fields where field.value.count >= 12 && fields.allSatisfy({ $0.name.contains(field.value) == false }) {
            fuzz.check(text.contains(field.value) == false, "error text shows a header value: \(text.debugDescription)")
        }
    }
}

// MARK: - HeaderGenerator

private enum HeaderGenerator {
    struct Field: CustomDebugStringConvertible {
        let name: String
        let value: String

        var debugDescription: String {
            "\(name.debugDescription): \(value.debugDescription)"
        }
    }

    private static let tokenCharacters = Array("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let tokenBytes = Set(tokenCharacters.flatMap(\.utf8))
    private static let injections = ["\r\nX-Injected: 1", "\n", "\r", "\0", "\r\n\r\nGET /admin HTTP/1.1", "%0D%0A", "\u{0085}", "\u{2028}"]

    static func fields(using random: inout SeededRandom) -> [Field] {
        var names = Set<String>()
        var fields: [Field] = []
        for _ in 0..<random.int(0...5) {
            let name = self.name(using: &random)
            guard names.insert(name.lowercased()).inserted else {
                continue
            }
            fields.append(Field(name: name, value: value(using: &random)))
        }
        return fields
    }

    /// RFC 9110: the name is a non-empty token; the value holds no control character but tab.
    static func isUnsafe(_ field: Field) -> Bool {
        isUnsafe(name: field.name, value: field.value)
    }

    static func isUnsafe(name: String, value: String) -> Bool {
        name.isEmpty
            || name.utf8.allSatisfy(tokenBytes.contains) == false
            || value.utf8.contains { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7F }
    }

    /// Sets `fields` the way an adapter would, through `allHTTPHeaderFields`.
    static func applying(_ fields: [Field], to request: URLRequest) -> URLRequest {
        var request = request
        var headers = request.allHTTPHeaderFields ?? [:]
        for field in fields {
            headers[field.name] = field.value
        }
        request.allHTTPHeaderFields = headers
        return request
    }

    static func isClean(_ request: URLRequest) -> Bool {
        (request.allHTTPHeaderFields ?? [:]).allSatisfy { isUnsafe(name: $0.key, value: $0.value) == false }
    }

    private static func name(using random: inout SeededRandom) -> String {
        var name = "X-" + String((0..<random.int(1...12)).map { _ in random.pick(tokenCharacters) })
        switch random.int(0...9) {
            case 0:
                name.insert(contentsOf: random.pick(injections), at: name.index(name.startIndex, offsetBy: random.int(0...name.count)))
            case 1:
                name = random.string(maximumLength: 16)
            default:
                break
        }
        return name
    }

    private static func value(using random: inout SeededRandom) -> String {
        switch random.int(0...9) {
            case 0...1:
                var value = random.string(maximumLength: 32, alphabet: .printableASCII)
                value.insert(contentsOf: random.pick(injections), at: value.index(value.startIndex, offsetBy: random.int(0...value.count)))
                return value
            case 2...3:
                return random.string(maximumLength: 64)
            case 4:
                return random.string(maximumLength: 32, alphabet: .ascii)
            default:
                return random.string(maximumLength: 48, alphabet: .printableASCII)
        }
    }
}
