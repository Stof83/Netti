//
//  NetworkMonitor.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation
import Network
import Observation
import os

/// Reports network connectivity to Netti's caching and queueing.
///
/// ``NetworkMonitor/shared`` is the default. Tests inject their own source to simulate going
/// offline and back.
public protocol ConnectivitySource: Sendable {
    /// The current status, readable from any context.
    var currentStatus: NetworkMonitor.Status { get }

    /// The current status followed by every change, in order.
    ///
    /// - Returns: A stream that yields the current status at once, then each change; it ends when
    ///   the source is released or the iteration stops.
    func statusUpdates() -> AsyncStream<NetworkMonitor.Status>
}

/// Monitors network connectivity with `NWPathMonitor`.
///
/// ``status`` starts as ``Status/unknown`` until the system reports a path, so a cold start never
/// mistakes "not known yet" for "offline". It changes on the main actor and is observable from
/// SwiftUI:
///
/// ```swift
/// if NetworkMonitor.shared.isDisconnected { OfflineBanner() }
/// ```
@Observable
public final class NetworkMonitor: ConnectivitySource, @unchecked Sendable {

    // MARK: - Types

    /// The network connection status.
    public enum Status: Sendable, Equatable {
        /// The system has not reported a path yet.
        case unknown
        /// A network path is available.
        case connected
        /// No network path is available.
        case disconnected
    }

    private struct State {
        var status = Status.unknown
        var observers: [Int: AsyncStream<Status>.Continuation] = [:]
        var nextObserverID = 0
    }

    // MARK: - Properties

    /// The shared monitor, started on first use.
    public static let shared = NetworkMonitor()

    /// The current status, updated on the main actor.
    @MainActor public private(set) var status = Status.unknown

    /// `true` when a network path is available.
    @MainActor public var isConnected: Bool {
        status == .connected
    }

    /// `true` when the system reported that no network path is available.
    @MainActor public var isDisconnected: Bool {
        status == .disconnected
    }

    /// The current status, readable from any context without waiting for the main actor.
    public var currentStatus: Status {
        state.withLock { $0.status }
    }

    @ObservationIgnored private let state = OSAllocatedUnfairLock(initialState: State())
    @ObservationIgnored private let pathMonitor: NWPathMonitor?

    // MARK: - Initialization

    /// Creates and starts a monitor.
    public convenience init() {
        self.init(pathMonitor: NWPathMonitor())
    }

    /// Creates a monitor that listens to `pathMonitor`; `nil` creates one that only changes through
    /// ``receive(_:)``, for tests.
    init(pathMonitor: NWPathMonitor?) {
        self.pathMonitor = pathMonitor
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            self?.receive(path.status == .satisfied ? .connected : .disconnected)
        }
        pathMonitor?.start(queue: DispatchQueue(label: "netti.network-monitor"))
    }

    deinit {
        pathMonitor?.cancel()
        state.withLock { $0.observers }.values.forEach { $0.finish() }
    }

    // MARK: - ConnectivitySource

    /// The current status followed by every change, in order.
    ///
    /// ```swift
    /// for await status in NetworkMonitor.shared.statusUpdates() where status == .connected {
    ///     await syncPendingChanges()
    /// }
    /// ```
    ///
    /// - Returns: A stream that yields the current status at once, then each change; only the
    ///   newest status is buffered for a slow consumer.
    public func statusUpdates() -> AsyncStream<Status> {
        let (stream, continuation) = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            let id = state.nextObserverID
            state.nextObserverID += 1
            state.observers[id] = continuation
            continuation.yield(state.status)
            return id
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: - Updates

    /// Records a new status: readable at once through ``currentStatus`` and the update streams, and
    /// published to ``status`` on the main actor.
    func receive(_ status: Status) {
        let observers: [AsyncStream<Status>.Continuation]? = state.withLock { state in
            guard state.status != status else {
                return nil
            }
            state.status = status
            return state.observers.sorted { $0.key < $1.key }.map(\.value)
        }
        guard let observers else {
            return
        }
        observers.forEach { $0.yield(status) }
        Task { @MainActor [weak self] in
            self?.status = status
        }
    }
}
