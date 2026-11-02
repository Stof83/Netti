//
//  RequestDeduplicator.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation
import os

/// Shares one transfer among concurrent identical requests.
///
/// The first caller for a key starts the transfer; callers arriving while it runs wait for the same
/// result. A waiter that is cancelled stops waiting at once with ``HTTPRequestError/cancelled``,
/// and the transfer itself is cancelled only when every waiter has left.
final class RequestDeduplicator: Sendable {

    // MARK: - Types

    typealias Outcome = Result<HTTPResponse<Data>, HTTPRequestError>
    typealias Waiter = CheckedContinuation<Outcome, Never>

    private struct Transfer {
        let id: Int
        var task: Task<Void, Never>?
        var waiters: [Int: Waiter] = [:]
    }

    private struct State {
        var transfers: [String: Transfer] = [:]
        var nextWaiterID = 0
        var nextTransferID = 0
    }

    // MARK: - Properties

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Deduplication

    /// Returns the response of the transfer running for `key`, starting `operation` when none is.
    ///
    /// - Parameters:
    ///   - key: Identifies requests that may share a transfer.
    ///   - operation: Performs the transfer.
    /// - Returns: The shared response.
    /// - Throws: The transfer's error, or ``HTTPRequestError/cancelled`` when the calling task is cancelled.
    func response(
        for key: String,
        operation: @escaping @Sendable () async throws(HTTPRequestError) -> HTTPResponse<Data>
    ) async throws(HTTPRequestError) -> HTTPResponse<Data> {
        let id = state.withLock { state in
            defer { state.nextWaiterID += 1 }
            return state.nextWaiterID
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: Waiter) in
                join(key, id: id, continuation: continuation, operation: operation)
            }
        } onCancel: {
            leave(key, id: id)
        }
        return try outcome.get()
    }

    /// The number of callers waiting on the transfer for `key`.
    func waiterCount(for key: String) -> Int {
        state.withLock { $0.transfers[key]?.waiters.count ?? 0 }
    }
}

// MARK: - Private Helpers

private extension RequestDeduplicator {
    func join(
        _ key: String,
        id: Int,
        continuation: Waiter,
        operation: @escaping @Sendable () async throws(HTTPRequestError) -> HTTPResponse<Data>
    ) {
        let isCancelled = state.withLock { state in
            // A cancellation handler that ran before this point found no waiter to remove.
            guard Task.isCancelled == false else {
                return true
            }
            if state.transfers[key] == nil {
                let transferID = state.nextTransferID
                state.nextTransferID += 1
                var transfer = Transfer(id: transferID)
                transfer.task = Task {
                    let outcome: Outcome
                    do throws(HTTPRequestError) {
                        outcome = .success(try await operation())
                    } catch {
                        outcome = .failure(error)
                    }
                    self.finish(key, transferID: transferID, with: outcome)
                }
                state.transfers[key] = transfer
            }
            state.transfers[key]?.waiters[id] = continuation
            return false
        }
        if isCancelled {
            continuation.resume(returning: .failure(.cancelled))
        }
    }

    func leave(_ key: String, id: Int) {
        let (waiter, abandonedTask) = state.withLock { state -> (Waiter?, Task<Void, Never>?) in
            guard let waiter = state.transfers[key]?.waiters.removeValue(forKey: id) else {
                return (nil, nil)
            }
            guard state.transfers[key]?.waiters.isEmpty == true else {
                return (waiter, nil)
            }
            return (waiter, state.transfers.removeValue(forKey: key)?.task)
        }
        waiter?.resume(returning: .failure(.cancelled))
        abandonedTask?.cancel()
    }

    /// Hands `outcome` to the waiters of transfer `transferID`, unless every waiter left and a new
    /// transfer has taken the key since.
    func finish(_ key: String, transferID: Int, with outcome: Outcome) {
        let waiters = state.withLock { state -> [Waiter] in
            guard state.transfers[key]?.id == transferID else {
                return []
            }
            return state.transfers.removeValue(forKey: key)?.waiters.values.map { $0 } ?? []
        }
        waiters.forEach { $0.resume(returning: outcome) }
    }
}

extension URLRequest {
    /// Identifies requests that may share one transfer: method, URL with sorted query, body and every header.
    var deduplicationKey: String {
        let headers = (allHTTPHeaderFields ?? [:])
            .map { "\($0.key.lowercased()):\($0.value)" }
            .sorted()
            .joined(separator: "\n")
        return [cacheKey, headers].joined(separator: "|").sha256
    }
}
