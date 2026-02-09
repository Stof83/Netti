//
//  NetworkMonitor.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation
import Network
import Observation

/// Monitors network connectivity and publishes updates about connection status.
///
/// This actor uses `NWPathMonitor` to track changes in network availability
/// and exposes an observable `status` property that can be observed using SwiftUI or Combine.
@Observable
@MainActor
public class NetworkMonitor {
    /// Represents the network connection status.
    public enum Status: Sendable {
        case connected
        case disconnected
    }

    /// The current connectivity status. Changes are published on the main thread.
    public private(set) var status: Status = .disconnected
    
    /// A stream of status updates for async observation.
    public let statusStream: AsyncStream<Status>

    @ObservationIgnored public var isDisconnected: Bool { get { status == .disconnected } }
    @ObservationIgnored private let monitor: NWPathMonitor
    @ObservationIgnored private let queue = DispatchQueue(label: "NetworkMonitorQueue")
    @ObservationIgnored private var statusContinuation: AsyncStream<Status>.Continuation?

    /// Creates and starts the network monitor.
    public init() {
        self.monitor = NWPathMonitor()
        
        // Initialize the stream and capture the continuation
        var localContinuation: AsyncStream<Status>.Continuation?
        self.statusStream = AsyncStream { continuation in
            localContinuation = continuation
        }
        self.statusContinuation = localContinuation
        
        guard let continuationToYield = localContinuation else { return }
        
        monitor.pathUpdateHandler = { [weak self] path in
            let newStatus: Status = path.status == .satisfied ? .connected : .disconnected
            
            continuationToYield.yield(newStatus)

            Task { @MainActor [weak self] in
                self?.status = newStatus
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        statusContinuation?.finish()
    }
}
