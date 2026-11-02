import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

/// S.11: retry, deduplication, the request queue and cancellation stay live while the server
/// drops, resets and stalls connections.
@Suite("Chaos: resilience", .timeLimit(.minutes(1)))
struct ChaosResilienceTests {

    // MARK: - Retry

    @Test("given a GET dropped mid-body on every attempt, when retried, then it is sent 1 + maxRetries times and fails with retryLimitExceeded")
    func retry_get_exhaustsThenFails() async throws {
        let server = try await makeChaosServer { _ in .closeMidBody() }
        defer { server.stop() }
        let netti = makeChaosNetti(retryPolicy: RetryPolicy(maxRetries: 2))

        let outcome = try #require(await withinBound { await chaosGET(netti, ChaosEndpoint(url: server.url("/chaos"))) })

        guard case .retryLimitExceeded(let attempts, let lastError)? = outcome.failure else {
            Issue.record("Expected retryLimitExceeded, got \(outcome)")
            return
        }
        #expect(attempts == 3)
        #expect(lastError.urlErrorCode == .networkConnectionLost)
        #expect(Self.chaosRequests(on: server).count == 3)
    }

    @Test("given a GET dropped mid-body twice, when retried, then the third attempt's response is returned")
    func retry_get_recoversFromTransientDrops() async throws {
        let attempts = Counter()
        let server = try await makeChaosServer { _ in
            attempts.increment() <= 2 ? .closeMidBody() : .text("recovered")
        }
        defer { server.stop() }
        let netti = makeChaosNetti(retryPolicy: RetryPolicy(maxRetries: 2))

        let outcome = try #require(await withinBound { await chaosGET(netti, ChaosEndpoint(url: server.url("/chaos"))) })

        #expect(try outcome.get().rawData == Data("recovered".utf8))
        #expect(attempts.value == 3)
    }

    @Test("given a POST dropped mid-body, when sent with a retry policy, then it is sent once and fails with the transport error")
    func retry_post_notRetried() async throws {
        let server = try await makeChaosServer { _ in .closeMidBody() }
        defer { server.stop() }
        let netti = makeChaosNetti(retryPolicy: RetryPolicy(maxRetries: 2))
        let endpoint = ChaosEndpoint(url: server.url("/chaos"))

        let outcome = try #require(await withinBound { await Self.post(netti, endpoint) })

        #expect(outcome.failure?.urlErrorCode == .networkConnectionLost)
        #expect(Self.chaosRequests(on: server).map(\.method) == ["POST"])
    }

    @Test("given a POST with an Idempotency-Key dropped mid-body, when sent with a retry policy, then it is retried up to the limit")
    func retry_postWithIdempotencyKey_retried() async throws {
        let server = try await makeChaosServer { _ in .closeMidBody() }
        defer { server.stop() }
        let netti = makeChaosNetti(retryPolicy: RetryPolicy(maxRetries: 2))
        let endpoint = ChaosEndpoint(url: server.url("/chaos"), headers: ["Idempotency-Key": "chaos-1"])

        let outcome = try #require(await withinBound { await Self.post(netti, endpoint) })

        guard case .retryLimitExceeded(let attempts, _)? = outcome.failure else {
            Issue.record("Expected retryLimitExceeded, got \(outcome)")
            return
        }
        #expect(attempts == 3)
        #expect(Self.chaosRequests(on: server).map { $0.header("Idempotency-Key") } == ["chaos-1", "chaos-1", "chaos-1"])
    }

    // MARK: - Deduplication

    @Test("given 10 identical concurrent GETs sharing a transfer, when the server drops it, then every caller fails and a follow-up GET succeeds")
    func dedup_droppedTransfer_releasesEveryWaiter() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let hits = Counter()
        let server = try await makeChaosServer { _ in
            guard hits.increment() == 1 else {
                return .text("fresh")
            }
            for await _ in gate {
                break
            }
            return .closeMidBody()
        }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let endpoint = ChaosEndpoint(url: server.url("/chaos"))
        let key = try netti.buildRequest(endpoint, method: .get).deduplicationKey

        let tasks = (0..<10).map { _ in Task { await chaosGET(netti, endpoint) } }
        #expect(await eventually { netti.deduplicator?.waiterCount(for: key) == 10 })
        release.yield()

        let outcomes = try #require(await withinBound { await Self.values(of: tasks) })
        #expect(outcomes.allSatisfy { $0.failure?.urlErrorCode == .networkConnectionLost })
        #expect(hits.value == 1)
        let followUp = try #require(await withinBound { await chaosGET(netti, endpoint) })
        #expect(try followUp.get().rawData == Data("fresh".utf8))
    }

    // MARK: - Request Queue

    @Test("given a burst through a concurrent queue against a server that severs, resets and stalls, when it runs, then every request completes with its expected outcome")
    func queue_burst_drains() async throws {
        let count = 24
        var random = ChaosRandom(seed: 42)
        let plan = (0..<count).map { $0 % 4 }.shuffled(using: &random)
        let server = try await makeChaosServer { request in
            switch Int(request.path.dropFirst("/chaos/".count)).map({ plan[$0] }) ?? 3 {
                case 0: .closeMidBody()
                case 1: .resetBeforeHead
                case 2: .silence
                default: .text("ok")
            }
        }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let queue = RequestQueue(.concurrent(max: 4), connectivity: StubConnectivity())

        let tasks = (0..<count).map { index in
            Task { await Self.enqueueGET(netti, on: queue, ChaosEndpoint(url: server.url("/chaos/\(index)"), timeoutInterval: 0.5)) }
        }

        let outcomes = try #require(await withinBound(.seconds(15)) { await Self.values(of: tasks) })
        for (index, outcome) in outcomes.enumerated() {
            #expect((plan[index] == 3) == (outcome.failure == nil), "request \(index), plan \(plan[index]): \(outcome)")
        }
        #expect(await queue.pendingCount == 0)
        #expect(await eventually { await queue.runningCount == 0 })
        await Self.expectQueueUsable(queue, netti, server)
    }

    @Test("given a serial queue stuck on a stalled request, when cancelAll is called, then every caller completes with cancelled and the queue takes new work")
    func queue_cancelAllMidChaos_releasesEveryCaller() async throws {
        let server = try await makeChaosServer { _ in .silence }
        defer { server.stop() }
        let netti = makeChaosNetti()
        let queue = RequestQueue(.serial, connectivity: StubConnectivity())
        let endpoint = ChaosEndpoint(url: server.url("/chaos"), timeoutInterval: 30)

        let tasks = (0..<8).map { _ in Task { await Self.enqueueGET(netti, on: queue, endpoint) } }
        #expect(await eventually { await queue.pendingCount == 7 })
        #expect(await server.wait { $0.requests.count == 1 })
        await queue.cancelAll()

        let outcomes = try #require(await withinBound(.seconds(3)) { await Self.values(of: tasks) })
        #expect(outcomes.allSatisfy { $0.failure?.isCancelled == true }, "\(outcomes)")
        #expect(await queue.pendingCount == 0)
        #expect(await eventually { await queue.runningCount == 0 })
        #expect(await server.wait { $0.disconnects == 1 })
        await Self.expectQueueUsable(queue, netti, server)
    }

    // MARK: - Cancellation

    @Test("given a GET reading a slow drip, when its task is cancelled, then it ends promptly with cancelled and the client and engine deallocate")
    func cancelDuringDrip_finishesPromptly_andReleasesClient() async throws {
        let server = try await makeChaosServer { _ in .drip(count: 16, every: .milliseconds(100)) }
        defer { server.stop() }

        let (netti, service) = try await Self.cancelMidDrip(on: server)

        #expect(await server.wait { $0.disconnects == 1 })
        #expect(await eventually { netti.object == nil }, "Netti was not released")
        #expect(await eventually { service.object == nil }, "URLSessionNetworkService was not released")
    }
}

// MARK: - Helpers

private extension ChaosResilienceTests {
    static func chaosRequests(on server: LocalHTTPServer) -> [LocalHTTPServer.Request] {
        server.requests.filter { $0.path != "/ok" }
    }

    static func post(_ netti: Netti, _ endpoint: ChaosEndpoint) async -> Result<HTTPResponse<Empty>, HTTPRequestError> {
        do {
            return .success(try await netti.post(endpoint))
        } catch {
            return .failure(error)
        }
    }

    static func enqueueGET(_ netti: Netti, on queue: RequestQueue, _ endpoint: ChaosEndpoint) async -> Result<HTTPResponse<Empty>, HTTPRequestError> {
        do {
            return .success(try await queue.enqueue { try await netti.get(endpoint) as HTTPResponse<Empty> })
        } catch {
            return .failure(.transport(error))
        }
    }

    static func values<Value: Sendable>(of tasks: [Task<Value, Never>]) async -> [Value] {
        var values: [Value] = []
        for task in tasks {
            values.append(await task.value)
        }
        return values
    }

    static func expectQueueUsable(_ queue: RequestQueue, _ netti: Netti, _ server: LocalHTTPServer, sourceLocation: SourceLocation = #_sourceLocation) async {
        let endpoint = ChaosEndpoint(url: server.url("/ok"))
        let outcome = await withinBound(sourceLocation: sourceLocation) { await enqueueGET(netti, on: queue, endpoint) }
        #expect(outcome?.failure == nil, "queue rejected new work: \(String(describing: outcome))", sourceLocation: sourceLocation)
    }

    /// Starts a GET on a new client, cancels it mid-drip, and returns weak references to the client
    /// and its engine once nothing here holds them.
    static func cancelMidDrip(on server: LocalHTTPServer) async throws -> (WeakReference<Netti>, WeakReference<URLSessionNetworkService>) {
        let service = URLSessionNetworkService(configuration: .ephemeral)
        let netti = makeChaosNetti(service: service)
        let endpoint = ChaosEndpoint(url: server.url("/chaos"), timeoutInterval: 5)
        let task = Task { await chaosGET(netti, endpoint) }
        #expect(await server.wait { $0.requests.count == 1 })
        try await Task.sleep(for: .milliseconds(150))

        let start = ContinuousClock.now
        task.cancel()
        let outcome = await withinBound(.seconds(2)) { await task.value }

        #expect(outcome?.failure?.isCancelled == true, "\(String(describing: outcome))")
        #expect(ContinuousClock.now - start < .seconds(1))
        return (WeakReference(netti), WeakReference(service))
    }
}
