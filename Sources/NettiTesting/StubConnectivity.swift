//
//  StubConnectivity.swift
//  NettiTesting
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation
import os

/// A connectivity source the test sets by hand.
///
/// ```swift
/// let connectivity = StubConnectivity(.disconnected)
/// let netti = server.netti(connectivity: connectivity)
/// connectivity.set(.connected)
/// ```
public final class StubConnectivity: ConnectivitySource {

    private typealias Observer = AsyncStream<NetworkMonitor.Status>.Continuation

    private let state: OSAllocatedUnfairLock<(status: NetworkMonitor.Status, observers: [Observer])>

    /// Creates a source in a state.
    ///
    /// - Parameter status: The initial state. `.connected` by default.
    public init(_ status: NetworkMonitor.Status = .connected) {
        state = OSAllocatedUnfairLock(initialState: (status, []))
    }

    /// The state last set, initially the one passed to ``init(_:)``.
    public var currentStatus: NetworkMonitor.Status {
        state.withLock { $0.status }
    }

    /// The current state followed by every ``set(_:)``, in order.
    ///
    /// - Returns: A stream that yields the current state at once, then each new one; it never ends.
    public func statusUpdates() -> AsyncStream<NetworkMonitor.Status> {
        let (stream, continuation) = AsyncStream<NetworkMonitor.Status>.makeStream()
        state.withLock { state in
            state.observers.append(continuation)
            continuation.yield(state.status)
        }
        return stream
    }

    /// Changes the state and tells every observer.
    ///
    /// - Parameter status: The new state.
    public func set(_ status: NetworkMonitor.Status) {
        let observers = state.withLock { state in
            state.status = status
            return state.observers
        }
        observers.forEach { $0.yield(status) }
    }
}
