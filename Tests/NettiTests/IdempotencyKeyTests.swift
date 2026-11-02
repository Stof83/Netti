//
//  IdempotencyKeyTests.swift
//  Netti
//

import Foundation
import NettiTesting
import Testing

@testable import Netti

@Suite("Idempotency key")
struct IdempotencyKeyTests {
    private let header = "Idempotency-Key"

    @Test("given the adapter and a POST retried twice, when sent, then all three attempts carry the same key")
    func post_retried_keepsSameKey() async throws {
        let attempts = Counter()
        let service = StubNetworkService { request in
            .stub(for: request, status: attempts.increment() < 3 ? 503 : 200)
        }
        let netti = makeNetti(service: service, retryPolicy: RetryPolicy(randomUnit: { 1 }))
        netti.interceptors.append(.idempotencyKey)

        try await netti.post(TestEndpoint(), body: Widget(id: 1, name: "a"))

        let keys = service.requests.map { $0.value(forHTTPHeaderField: header) }
        #expect(keys.count == 3)
        #expect(Set(keys).count == 1)
        #expect(keys.first.flatMap { $0 }.flatMap(UUID.init(uuidString:)) != nil)
    }

    @Test("given the adapter, when two POSTs are sent, then each call has its own key")
    func post_separateCalls_distinctKeys() async throws {
        let service = StubNetworkService()
        let netti = makeNetti(service: service, interceptors: [.idempotencyKey])

        try await netti.post(TestEndpoint(), body: Widget(id: 1, name: "a"))
        try await netti.post(TestEndpoint(), body: Widget(id: 1, name: "a"))

        let keys = service.requests.compactMap { $0.value(forHTTPHeaderField: header) }
        #expect(keys.count == 2)
        #expect(keys[0] != keys[1])
    }

    @Test("given a caller-set key, when sent through the adapter, then it is left unchanged")
    func callerKey_isKept() async throws {
        let service = StubNetworkService()
        let netti = makeNetti(service: service, interceptors: [.idempotencyKey])

        try await netti.post(TestEndpoint(headers: [header: "order-42"]), body: Widget(id: 1, name: "a"))

        #expect(service.requests.first?.value(forHTTPHeaderField: header) == "order-42")
    }

    @Test("given the adapter, when PATCH is sent, then it carries a key; GET, PUT and DELETE do not")
    func methods_onlyPostAndPatchGetKeys() async throws {
        let service = StubNetworkService()
        let netti = makeNetti(service: service, interceptors: [.idempotencyKey])

        try await netti.patch(TestEndpoint(), body: Widget(id: 1, name: "a"))
        try await netti.get(TestEndpoint())
        try await netti.put(TestEndpoint(), body: Widget(id: 1, name: "a"))
        try await netti.delete(TestEndpoint())

        let keyed = service.requests.map { ($0.httpMethod ?? "", $0.value(forHTTPHeaderField: header) != nil) }
        #expect(keyed.map(\.0) == ["PATCH", "GET", "PUT", "DELETE"])
        #expect(keyed.map(\.1) == [true, false, false, false])
    }

    @Test("given a POST carrying an Idempotency-Key, when it fails with 503, then the default policy retries it")
    func retryPolicy_keyedPost_isRetryable() async {
        let policy = RetryPolicy(randomUnit: { 1 })
        let keyed = makeURLRequest(method: "POST", headers: [header: "k"])

        #expect(await policy.retry(makeContext(status: 503, request: keyed)) == .retryAfter(.milliseconds(500)))
        #expect(await policy.retry(makeContext(method: "POST", status: 503)) == .doNotRetry)
    }

    @Test("given a keyed POST that keeps failing, when sent, then retries stop at the limit")
    func post_keyedKeepsFailing_stopsAtLimit() async {
        let service = StubNetworkService { .stub(for: $0, status: 503) }
        let netti = makeNetti(service: service, interceptors: [.idempotencyKey], retryPolicy: RetryPolicy(randomUnit: { 1 }))

        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Empty> in
            try await netti.post(TestEndpoint(), body: Widget(id: 1, name: "a"))
        }

        guard case .retryLimitExceeded(let attempts, _)? = error else {
            Issue.record("Expected retryLimitExceeded, got \(String(describing: error))")
            return
        }
        #expect(attempts == 3)
        #expect(Set(service.requests.map { $0.value(forHTTPHeaderField: header) }).count == 1)
    }
}
