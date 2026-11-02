import Foundation
import Testing

@testable import Netti
import NettiTesting

@Suite("Request queue", .timeLimit(.minutes(1)))
struct RequestQueueTests {

    @Test("given 3 operations on a serial queue, when they run, then one runs at a time, in enqueue order")
    func serial_fifo() async throws {
        let queue = RequestQueue(.serial, connectivity: StubConnectivity())
        let log = Recorder<String>()
        let gauge = InFlightGauge()
        await queue.pause()

        let tasks = try await enqueueInOrder(3, on: queue) { index in
            gauge.enter()
            log.append("start \(index)")
            try await Task.sleep(for: .milliseconds(5))
            log.append("end \(index)")
            gauge.leave()
            return index
        }
        await queue.resume()

        #expect(try await results(of: tasks) == [0, 1, 2])
        #expect(log.values == ["start 0", "end 0", "start 1", "end 1", "start 2", "end 2"])
        #expect(gauge.peak == 1)
    }

    @Test("given a concurrent queue with a maximum of 2, when 6 operations run, then no more than 2 are in flight")
    func concurrent_honoursMaximum() async throws {
        let queue = RequestQueue(.concurrent(max: 2), connectivity: StubConnectivity())
        let gauge = InFlightGauge()

        let tasks = (0..<6).map { index in
            Task {
                try await queue.enqueue {
                    gauge.enter()
                    defer { gauge.leave() }
                    try await Task.sleep(for: .milliseconds(10))
                    return index
                }
            }
        }

        #expect(try await results(of: tasks) == Array(0..<6))
        #expect(gauge.peak == 2)
    }

    @Test("given pending work of mixed priority, when the queue resumes, then high starts first and equals keep FIFO order")
    func priorityOrdering() async throws {
        let queue = RequestQueue(.serial, connectivity: StubConnectivity())
        let order = Recorder<String>()
        await queue.pause()

        let priorities: [(String, RequestQueue.Priority)] = [("low", .low), ("normal 1", .normal), ("high", .high), ("normal 2", .normal)]
        var tasks: [Task<String, any Error>] = []
        for (index, (name, priority)) in priorities.enumerated() {
            tasks.append(Task {
                try await queue.enqueue(priority: priority) {
                    order.append(name)
                    return name
                }
            })
            #expect(await eventually { await queue.pendingCount == index + 1 })
        }
        await queue.resume()
        _ = try await results(of: tasks)

        #expect(order.values == ["high", "normal 1", "normal 2", "low"])
    }

    @Test("given 2 pending operations, when cancelAll is called, then both callers receive cancelled and nothing is pending")
    func cancelAll_cancelsPending() async throws {
        let queue = RequestQueue(.serial, connectivity: StubConnectivity())
        let ran = Counter()
        await queue.pause()
        let tasks = try await enqueueInOrder(2, on: queue) { index in
            ran.increment()
            return index
        }

        await queue.cancelAll()

        for task in tasks {
            let error = await #expect(throws: HTTPRequestError.self) { try await task.value }
            #expect(error?.isCancelled == true)
        }
        #expect(await queue.pendingCount == 0)
        #expect(ran.value == 0)
    }

    @Test("given a running operation, when cancelAll is called, then it is cancelled too")
    func cancelAll_cancelsRunning() async throws {
        let queue = RequestQueue(.serial, connectivity: StubConnectivity())
        let task = Task {
            try await queue.enqueue {
                try await Task.sleep(for: .seconds(30))
            }
        }
        #expect(await eventually { await queue.runningCount == 1 })

        await queue.cancelAll()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await eventually { await queue.runningCount == 0 })
    }

    @Test("given a caller whose task is cancelled while pending, when cancelled, then it leaves the queue and receives cancelled")
    func callerCancellation_withdraws() async throws {
        let queue = RequestQueue(.serial, connectivity: StubConnectivity())
        await queue.pause()
        let tasks = try await enqueueInOrder(1, on: queue) { $0 }

        tasks[0].cancel()

        let error = await #expect(throws: HTTPRequestError.self) { try await tasks[0].value }
        #expect(error?.isCancelled == true)
        #expect(await eventually { await queue.pendingCount == 0 })
    }

    @Test("given a queue waiting for connectivity, when 2 operations are enqueued offline and connectivity returns, then both run in order")
    func offlineHold_drainsOnReconnect() async throws {
        let connectivity = StubConnectivity(.disconnected)
        let queue = RequestQueue(.serial(waitsForConnectivity: true), connectivity: connectivity)
        let order = Recorder<Int>()

        let tasks = try await enqueueInOrder(2, on: queue) { index in
            order.append(index)
            return index
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(order.values.isEmpty)
        #expect(await queue.pendingCount == 2)

        connectivity.set(.connected)

        #expect(try await results(of: tasks) == [0, 1])
        #expect(order.values == [0, 1])
    }

    @Test("given a client, when it makes a queue, then the queue uses the client's connectivity source")
    func clientQueue_usesClientConnectivity() async throws {
        let connectivity = StubConnectivity(.disconnected)
        let netti = makeNetti(connectivity: connectivity)
        let queue = netti.queue(.serial(waitsForConnectivity: true))

        let task = Task { try await queue.enqueue { 1 } }
        #expect(await eventually { await queue.pendingCount == 1 })
        connectivity.set(.connected)

        #expect(try await task.value == 1)
    }

    @Test("given a fire-and-forget operation, when its result is discarded, then it still runs")
    func enqueue_discardedResult_runs() async throws {
        let queue = RequestQueue(.serial, connectivity: StubConnectivity())
        let ran = Counter()

        try await queue.enqueue { ran.increment() }

        #expect(ran.value == 1)
    }

    // MARK: - Helpers

    /// Enqueues `count` operations from separate tasks, each one pending before the next is enqueued.
    private func enqueueInOrder<Value: Sendable>(
        _ count: Int,
        on queue: RequestQueue,
        _ operation: @escaping @Sendable (Int) async throws -> Value
    ) async throws -> [Task<Value, any Error>] {
        var tasks: [Task<Value, any Error>] = []
        for index in 0..<count {
            let before = await queue.pendingCount
            tasks.append(Task { try await queue.enqueue { try await operation(index) } })
            #expect(await eventually { await queue.pendingCount == before + 1 })
        }
        return tasks
    }

    private func results<Value>(of tasks: [Task<Value, any Error>]) async throws -> [Value] {
        var values: [Value] = []
        for task in tasks {
            values.append(try await task.value)
        }
        return values
    }
}
