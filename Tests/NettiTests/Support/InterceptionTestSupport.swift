import Foundation
import os

@testable import Netti

/// A thread-safe counter for closures that run on several tasks.
final class Counter: Sendable {
    private let storage = OSAllocatedUnfairLock<Int>(initialState: 0)

    var value: Int {
        storage.withLock { $0 }
    }

    @discardableResult
    func increment() -> Int {
        storage.withLock {
            $0 += 1
            return $0
        }
    }
}

/// A thread-safe list for closures that record what they saw.
final class Recorder<Element: Sendable>: Sendable {
    private let storage = OSAllocatedUnfairLock<[Element]>(initialState: [])

    var values: [Element] {
        storage.withLock { $0 }
    }

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }
}

enum TestURL {
    static let api = URL(string: "https://api.test/items")!
}

func makeURLRequest(method: String = "GET", headers: [String: String] = [:]) -> URLRequest {
    var request = URLRequest(url: TestURL.api)
    request.httpMethod = method
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    return request
}

func makeResponse(
    status: Int,
    headers: [String: String] = [:],
    body: Data = Data(),
    request: URLRequest? = nil
) -> HTTPResponse<Data> {
    HTTPResponse(
        request: request ?? makeURLRequest(),
        response: HTTPURLResponse(url: TestURL.api, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers),
        data: body,
        rawData: body
    )
}

func makeContext(
    method: String = "GET",
    status: Int? = nil,
    headers: [String: String] = [:],
    error: HTTPRequestError? = nil,
    retryCount: Int = 0,
    request: URLRequest? = nil
) -> RetryContext {
    let request = request ?? makeURLRequest(method: method)
    return RetryContext(
        request: request,
        response: status.map { makeResponse(status: $0, headers: headers, request: request) },
        error: error,
        retryCount: retryCount
    )
}
