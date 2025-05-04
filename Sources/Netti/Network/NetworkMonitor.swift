//
//  NetworkMonitor.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation
import Network
import Combine

/// Monitors network connectivity and publishes updates about connection status.
///
/// This actor uses `NWPathMonitor` to track changes in network availability
/// and exposes an observable `status` property that can be observed using SwiftUI or Combine.
public actor NetworkMonitor: ObservableObject {
    /// Represents the network connection status.
    public enum Status {
        case connected
        case disconnected
    }

    /// The current connectivity status. Changes are published on the main thread.
    @MainActor @Published public private(set) var status: Status = .disconnected

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "NetworkMonitorQueue")

    /// Creates and starts the network monitor.
    public init() {
        self.monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            let newStatus: Status = path.status == .satisfied ? .connected : .disconnected

            Task { @MainActor in
                self.status = newStatus
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
