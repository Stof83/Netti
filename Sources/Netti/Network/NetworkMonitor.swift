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
public class NetworkMonitor:  @unchecked Sendable {
    /// Represents the network connection status.
    public enum Status {
        case connected
        case disconnected
    }

    /// The current connectivity status. Changes are published on the main thread.
    public private(set) var status: Status = .disconnected
    
    @ObservationIgnored public var isConnected: Bool { status == .connected }
    @ObservationIgnored public var isDisconnected: Bool { status == .disconnected }
    
    @ObservationIgnored private let monitor: NWPathMonitor
    @ObservationIgnored private let queue = DispatchQueue(label: "NetworkMonitorQueue")

    /// Creates and starts the network monitor.
    public init() {
        self.monitor = NWPathMonitor()
        
        monitor.pathUpdateHandler = { path in
            self.status = path.status == .satisfied ? .connected : .disconnected
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
