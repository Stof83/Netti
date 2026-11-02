import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

@Suite("Batch requests", .timeLimit(.minutes(1)))
struct BatchRequestTests {

    private struct Failure: Error, Equatable {
        let index: Int
    }

    // MARK: - Concurrent

    @Test("given 10 operations finishing in random order, when run concurrently, then the results match the input order")
    func concurrent_keepsOrder() async throws {
        let results = try await makeNetti().concurrent(0..<10) { index in
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...20)))
            return index * 10
        }

        #expect(results == (0..<10).map { $0 * 10 })
    }

    @Test("given 20 operations and a limit of 3, when run concurrently, then no more than 3 are ever in flight")
    func concurrent_honoursLimit() async throws {
        let gauge = InFlightGauge()

        _ = try await makeNetti().concurrent(0..<20, maxConcurrency: 3) { index in
            gauge.enter()
            defer { gauge.leave() }
            try await Task.sleep(for: .milliseconds(5))
            return index
        }

        #expect(gauge.peak == 3)
    }

    @Test("given the second operation fails, when run concurrently, then in-flight siblings are cancelled and its error is thrown")
    func concurrent_failsFast() async {
        let cancelled = Counter()

        let error = await #expect(throws: Failure.self) {
            try await makeNetti().concurrent(0..<4) { index in
                if index == 1 {
                    throw Failure(index: index)
                }
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.increment()
                    throw Failure(index: -1)
                }
                return index
            }
        }

        #expect(error == Failure(index: 1))
        #expect(cancelled.value == 3)
    }

    @Test("given Netti requests, when run concurrently, then their typed errors are kept")
    func concurrent_typedNettiErrors() async {
        let service = StubNetworkService { request in
            guard request.url?.query == "id=2" else {
                return try .json(for: request, Widget(id: 1, name: "ok"))
            }
            throw URLError(.timedOut)
        }
        let netti = makeNetti(service: service, deduplicatesRequests: false)

        let error = await expectRequestError { () async throws(HTTPRequestError) -> [Widget?] in
            try await netti.concurrent([1, 2, 3]) { (id: Int) async throws(HTTPRequestError) -> Widget? in
                try await netti.get(TestEndpoint(), query: ["id": id]).data
            }
        }

        #expect(error?.urlErrorCode == .timedOut)
    }

    // MARK: - Settled

    @Test("given 3 of 5 operations fail, when run settled, then 5 results come back in input order")
    func settled_collectsEveryOutcome() async {
        let results = await makeNetti().concurrentSettled(0..<5) { index throws(Failure) in
            guard index.isMultiple(of: 2) == false else {
                throw Failure(index: index)
            }
            return index
        }

        #expect(results.count == 5)
        #expect(results.map { try? $0.get() } == [nil, 1, nil, 3, nil])
        #expect(results.compactMap { if case .failure(let failure) = $0 { failure.index } else { nil } } == [0, 2, 4])
    }

    // MARK: - Sequential

    @Test("given a sequential batch of 3, when run, then each starts only after the previous one finished")
    func sequential_strictOrder() async throws {
        let log = Recorder<String>()

        let results = try await makeNetti().sequential([1, 2, 3]) { index in
            log.append("start \(index)")
            try await Task.sleep(for: .milliseconds(5))
            log.append("end \(index)")
            return index
        }

        #expect(results == [1, 2, 3])
        #expect(log.values == ["start 1", "end 1", "start 2", "end 2", "start 3", "end 3"])
    }

    @Test("given the second of 3 fails, when run sequentially, then the third never starts")
    func sequential_stopsAtFirstFailure() async {
        let started = Recorder<Int>()

        await #expect(throws: Failure.self) {
            try await makeNetti().sequential([1, 2, 3]) { index in
                started.append(index)
                if index == 2 {
                    throw Failure(index: index)
                }
                return index
            }
        }

        #expect(started.values == [1, 2])
    }
}

/// Tracks how many operations run at once, and the most ever seen.
final class InFlightGauge: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))

    var peak: Int {
        state.withLock { $0.peak }
    }

    func enter() {
        state.withLock { state in
            state.current += 1
            state.peak = max(state.peak, state.current)
        }
    }

    func leave() {
        state.withLock { $0.current -= 1 }
    }
}
