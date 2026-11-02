//
//  Netti+Orchestration.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation

/// Many requests at once, one after another, or through a queue.
///
/// ```swift
/// let users: [User?] = try await netti.concurrent(ids, maxConcurrency: 4) { id in
///     try await netti.get(UserAPI.user(id)).data
/// }
/// ```
///
/// For a few requests of different types, use `async let`:
///
/// ```swift
/// async let user: HTTPResponse<User> = netti.get(UserAPI.me)
/// async let rides: HTTPResponse<[Ride]> = netti.get(RideAPI.history)
/// let (me, history) = try await (user, rides)
/// ```
extension Netti {

    // MARK: - Batches

    /// Runs `operation` for every element concurrently and returns the results in input order.
    ///
    /// At most `maxConcurrency` operations run at once. The first failure cancels the operations
    /// still running, and is thrown once they have stopped. Cancelling the calling task cancels
    /// every operation.
    ///
    /// ```swift
    /// let users: [User?] = try await netti.concurrent(ids, maxConcurrency: 4) { id in
    ///     try await netti.get(UserAPI.user(id)).data
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - elements: The inputs.
    ///   - maxConcurrency: The most operations running at once. 6 by default.
    ///   - operation: The work for one element.
    /// - Returns: One result per element, in input order.
    /// - Throws: The first error an operation throws.
    public func concurrent<Element: Sendable, Value: Sendable, Failure: Error>(
        _ elements: some Sequence<Element>,
        maxConcurrency: Int = 6,
        _ operation: @escaping @Sendable (Element) async throws(Failure) -> Value
    ) async throws(Failure) -> [Value] {
        let outcomes = await Self.run(Array(elements), maxConcurrency: maxConcurrency, failsFast: true, operation)
        var values: [Value] = []
        values.reserveCapacity(outcomes.count)
        for outcome in outcomes {
            switch outcome {
                case .success(let value)?:
                    values.append(value)
                case .failure(let error)?:
                    throw error
                case nil:
                    continue
            }
        }
        return values
    }

    /// Runs `operation` for every element concurrently and returns every outcome, success or
    /// failure, in input order. A failure never stops the other operations.
    ///
    /// ```swift
    /// let outcomes = await netti.concurrentSettled(photoURLs) { url in
    ///     try await netti.upload(PhotoAPI.upload, fileURL: url)
    /// }
    /// let failed = outcomes.filter { if case .failure = $0 { true } else { false } }
    /// ```
    ///
    /// - Parameters:
    ///   - elements: The inputs.
    ///   - maxConcurrency: The most operations running at once. 6 by default.
    ///   - operation: The work for one element.
    /// - Returns: One result per element, in input order.
    public func concurrentSettled<Element: Sendable, Value: Sendable, Failure: Error>(
        _ elements: some Sequence<Element>,
        maxConcurrency: Int = 6,
        _ operation: @escaping @Sendable (Element) async throws(Failure) -> Value
    ) async -> [Result<Value, Failure>] {
        await Self.run(Array(elements), maxConcurrency: maxConcurrency, failsFast: false, operation).compactMap { $0 }
    }

    /// Runs `operation` for every element strictly one after another, stopping at the first failure.
    ///
    /// ```swift
    /// let steps = try await netti.sequential(migrations) { step in
    ///     try await netti.post(MigrationAPI.run, body: step)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - elements: The inputs.
    ///   - operation: The work for one element.
    /// - Returns: One result per element, in input order.
    /// - Throws: The first error an operation throws.
    public func sequential<Element, Value, Failure: Error>(
        _ elements: some Sequence<Element>,
        _ operation: (Element) async throws(Failure) -> Value
    ) async throws(Failure) -> [Value] {
        var values: [Value] = []
        for element in elements {
            values.append(try await operation(element))
        }
        return values
    }

    // MARK: - Queues

    /// Creates a queue that runs operations in order, with a concurrency limit, priorities and an
    /// optional offline hold driven by this client's connectivity source.
    ///
    /// ```swift
    /// let uploads = netti.queue(.serial(waitsForConnectivity: true))
    /// try await uploads.enqueue { try await netti.post(TripAPI.log, body: entry) }
    /// ```
    ///
    /// - Parameter mode: Serial by default.
    /// - Returns: The queue.
    public func queue(_ mode: RequestQueue.Mode = .serial) -> RequestQueue {
        RequestQueue(mode, connectivity: connectivity)
    }
}

// MARK: - Private Helpers

private extension Netti {
    /// Runs the operations in a task group, keeping at most `maxConcurrency` in flight.
    ///
    /// - Returns: The outcome of every element; `nil` for the elements never started because an
    ///   earlier failure stopped a fail-fast batch.
    static func run<Element: Sendable, Value: Sendable, Failure: Error>(
        _ elements: [Element],
        maxConcurrency: Int,
        failsFast: Bool,
        _ operation: @escaping @Sendable (Element) async throws(Failure) -> Value
    ) async -> [Result<Value, Failure>?] {
        var outcomes = [Result<Value, Failure>?](repeating: nil, count: elements.count)
        await withTaskGroup(of: (Int, Result<Value, Failure>).self) { group in
            var nextIndex = 0
            func startNext() {
                let index = nextIndex
                let element = elements[index]
                nextIndex += 1
                group.addTask {
                    do throws(Failure) {
                        return (index, .success(try await operation(element)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            while nextIndex < min(max(1, maxConcurrency), elements.count) {
                startNext()
            }
            for await (index, outcome) in group {
                outcomes[index] = outcome
                if failsFast, case .failure = outcome {
                    group.cancelAll()
                    break
                }
                if nextIndex < elements.count {
                    startNext()
                }
            }
        }
        // A fail-fast batch stops recording at its first failure, so the siblings it cancelled never
        // replace that failure with their own.
        return outcomes
    }
}
