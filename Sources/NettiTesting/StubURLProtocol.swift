//
//  StubURLProtocol.swift
//  NettiTesting
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation
import os

/// The `URLProtocol` behind ``StubServer``: it answers requests from stubs instead of the network.
///
/// You rarely touch it directly. ``StubServer/configuration`` installs it, and tags the session
/// with the server's ID so each request finds its own server's stubs.
public final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    // MARK: - Registry

    /// The header that routes a request to its server; removed before the request is recorded.
    static let serverHeader = "X-Netti-Stub-Server"

    private struct Entry: Sendable {
        weak let storage: StubStorage?
    }

    private static let registry = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    static func register(_ storage: StubStorage) {
        registry.withLock { $0[storage.id] = Entry(storage: storage) }
    }

    static func unregister(_ storage: StubStorage) {
        registry.withLock { $0[storage.id] = nil }
    }

    private static func storage(for request: URLRequest) -> StubStorage? {
        guard let id = request.value(forHTTPHeaderField: serverHeader) else {
            return nil
        }
        return registry.withLock { $0[id]?.storage }
    }

    // MARK: - Properties

    private let isStopped = OSAllocatedUnfairLock(initialState: false)

    // MARK: - URLProtocol

    /// Whether the request carries a ``StubServer``'s routing header.
    ///
    /// - Parameter request: The request URLSession is about to load.
    /// - Returns: `true` for requests made through a ``StubServer/configuration``.
    override public class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: serverHeader) != nil
    }

    /// Returns the request unchanged.
    ///
    /// - Parameter request: The request.
    /// - Returns: The same request.
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    /// Records the request with its server and answers with the newest matching stub, after its
    /// delay; fails with a `URLError` when no stub matches or the server is gone.
    override public func startLoading() {
        var recorded = request
        recorded.setValue(nil, forHTTPHeaderField: Self.serverHeader)
        let body = Self.readBody(of: request)
        recorded.httpBody = body
        recorded.httpBodyStream = nil

        guard let storage = Self.storage(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost, userInfo: [
                NSLocalizedDescriptionKey: "The StubServer for this request no longer exists",
            ]))
            return
        }
        guard let stub = storage.receive(recorded, body: body) else {
            let method = recorded.httpMethod ?? HTTPMethod.get.rawValue
            let url = recorded.url?.absoluteString ?? "(no URL)"
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable, userInfo: [
                NSLocalizedDescriptionKey: "No stub registered for \(method) \(url)",
                NSURLErrorFailingURLStringErrorKey: url,
            ]))
            return
        }

        let isHead = recorded.httpMethod == HTTPMethod.head.rawValue
        let seconds = stub.delay.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? 0
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            guard isStopped.withLock({ $0 }) == false else {
                return
            }
            deliver(stub.outcome, isHead: isHead)
        }
    }

    /// Drops the pending answer of a cancelled request.
    override public func stopLoading() {
        isStopped.withLock { $0 = true }
    }

    // MARK: - Delivery

    private func deliver(_ outcome: StubStorage.Outcome, isHead: Bool) {
        switch outcome {
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .redirect(let status, let location):
                redirect(to: location, status: status)
            case .response(let status, let headers, let body):
                guard let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
                else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if isHead == false, body.isEmpty == false {
                    client?.urlProtocol(self, didLoad: body)
                }
                client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// Hands a redirect to URLSession, which asks the engine's ``RedirectHandler`` whether to follow.
    private func redirect(to location: URL, status: Int) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location.absoluteString])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var proposed = request
        proposed.url = location
        // URLSession drops these from a followed redirect; the handler decides what returns.
        proposed.setValue(nil, forHTTPHeaderField: "Authorization")
        proposed.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        if [301, 302, 303].contains(status), request.httpMethod != HTTPMethod.head.rawValue {
            proposed.httpMethod = HTTPMethod.get.rawValue
            proposed.httpBody = nil
            proposed.httpBodyStream = nil
        }
        client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
        // URLSession holds these callbacks until the redirect handler has decided. When the
        // redirect is followed it discards them and loads the new request; when it is declined,
        // this response is what the caller receives.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: - Body

    /// The body of `request`, drained from its stream when URLSession converted it to one.
    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
