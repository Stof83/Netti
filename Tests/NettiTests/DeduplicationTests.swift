import Foundation
import Testing

@testable import Netti
import NettiTesting

@Suite("Request deduplication", .timeLimit(.minutes(1)))
struct DeduplicationTests {

    @Test("given 10 identical concurrent GETs, when sent, then 1 transfer occurs and all 10 callers receive the result")
    func identicalGETsShareOneTransfer() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let service = StubNetworkService { request in
            for await _ in gate {
                break
            }
            return try .json(for: request, Widget(id: 1, name: "shared"))
        }
        let netti = makeNetti(service: service)
        let key = try netti.buildRequest(TestEndpoint(), method: .get).deduplicationKey

        let tasks = (0..<10).map { _ in
            Task { () async throws -> Widget? in try await netti.get(TestEndpoint()).data }
        }
        #expect(await eventually { netti.deduplicator?.waiterCount(for: key) == 10 })
        release.yield()

        for task in tasks {
            #expect(try await task.value == Widget(id: 1, name: "shared"))
        }
        #expect(service.requests.count == 1)
    }

    @Test("given two concurrent GETs with different Authorization headers, when sent, then two transfers occur")
    func differentAuthorizationNotShared() async throws {
        let service = StubNetworkService { request in
            try await Task.sleep(for: .milliseconds(50))
            return .stub(for: request)
        }
        let netti = makeNetti(service: service)
        var alice = TestEndpoint()
        alice.headers = ["Authorization": "Bearer alice"]
        var bob = TestEndpoint()
        bob.headers = ["Authorization": "Bearer bob"]

        async let first = netti.get(alice)
        async let second = netti.get(bob)
        _ = try await (first, second)

        #expect(service.requests.count == 2)
    }

    @Test("given deduplication turned off, when identical GETs run concurrently, then each gets its own transfer")
    func canBeDisabled() async throws {
        let service = StubNetworkService { request in
            try await Task.sleep(for: .milliseconds(20))
            return .stub(for: request)
        }
        let netti = makeNetti(service: service, deduplicatesRequests: false)

        async let first = netti.get(TestEndpoint())
        async let second = netti.get(TestEndpoint())
        async let third = netti.get(TestEndpoint())
        _ = try await (first, second, third)

        #expect(service.requests.count == 3)
    }

    @Test("given identical concurrent POSTs, when sent, then they are never shared")
    func postsAreNotShared() async throws {
        let service = StubNetworkService { request in
            try await Task.sleep(for: .milliseconds(20))
            return .stub(for: request)
        }
        let netti = makeNetti(service: service)

        async let first = netti.post(TestEndpoint(), body: Widget(id: 1, name: "a"))
        async let second = netti.post(TestEndpoint(), body: Widget(id: 1, name: "a"))
        _ = try await (first, second)

        #expect(service.requests.count == 2)
    }

    @Test("given a shared transfer, when one waiter is cancelled, then it gets cancelled at once and the others still get the result")
    func cancelledWaiterLeavesOthers() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let service = StubNetworkService { request in
            for await _ in gate {
                break
            }
            return try .json(for: request, Widget(id: 1, name: "shared"))
        }
        let netti = makeNetti(service: service)
        let key = try netti.buildRequest(TestEndpoint(), method: .get).deduplicationKey
        let leaving = Task { () async throws -> Widget? in try await netti.get(TestEndpoint()).data }
        let staying = Task { () async throws -> Widget? in try await netti.get(TestEndpoint()).data }
        #expect(await eventually { netti.deduplicator?.waiterCount(for: key) == 2 })

        leaving.cancel()
        let error = await #expect(throws: HTTPRequestError.self) { try await leaving.value }
        release.yield()

        #expect(error?.isCancelled == true)
        #expect(try await staying.value == Widget(id: 1, name: "shared"))
        #expect(service.requests.count == 1)
    }

    @Test("given every waiter is cancelled, when the transfer is abandoned, then it is cancelled and a new request starts a new transfer")
    func abandonedTransferIsCancelled() async throws {
        let transferCancelled = Counter()
        let service = StubNetworkService { request in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                transferCancelled.increment()
                throw error
            }
            return .stub(for: request)
        }
        let netti = makeNetti(service: service)
        let key = try netti.buildRequest(TestEndpoint(), method: .get).deduplicationKey
        let only = Task { try await netti.get(TestEndpoint()) }
        #expect(await eventually { netti.deduplicator?.waiterCount(for: key) == 1 })

        only.cancel()

        await #expect(throws: HTTPRequestError.self) { try await only.value }
        #expect(await eventually { transferCancelled.value == 1 })
    }

    @Test("given a per-host limit of 2, when the engine is created, then its session uses at most 2 connections per host")
    func maxConnectionsPerHost() {
        let configuration = URLSessionConfiguration.ephemeral
        let original = configuration.httpMaximumConnectionsPerHost

        let service = URLSessionNetworkService(configuration: configuration, maxConnectionsPerHost: 2)

        #expect(service.sessionConfiguration.httpMaximumConnectionsPerHost == 2)
        #expect(configuration.httpMaximumConnectionsPerHost == original)
    }
}
