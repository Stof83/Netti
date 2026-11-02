import Foundation
import Observation
import Testing

@testable import Netti

@Suite("Network monitor", .timeLimit(.minutes(1)))
struct NetworkMonitorTests {

    @Test("given a new monitor, when nothing was reported yet, then its status is unknown")
    @MainActor
    func initialStateIsUnknown() {
        let monitor = NetworkMonitor(pathMonitor: nil)

        #expect(monitor.status == .unknown)
        #expect(monitor.currentStatus == .unknown)
        #expect(monitor.isConnected == false)
        #expect(monitor.isDisconnected == false)
    }

    @Test("given a satisfied path, when reported, then the status is readable at once and main-actor observers see connected")
    func updatesReachMainActor() async {
        let monitor = NetworkMonitor(pathMonitor: nil)

        monitor.receive(.connected)

        #expect(monitor.currentStatus == .connected)
        #expect(await eventually { await MainActor.run { monitor.status == .connected } })
        #expect(await MainActor.run { monitor.isConnected })
    }

    @Test("given an observer, when the status changes, then it receives the current status and every change in order")
    func statusUpdatesStream() async {
        let monitor = NetworkMonitor(pathMonitor: nil)
        var updates = monitor.statusUpdates().makeAsyncIterator()

        #expect(await updates.next() == .unknown)
        monitor.receive(.disconnected)
        #expect(await updates.next() == .disconnected)
        monitor.receive(.disconnected)
        monitor.receive(.connected)
        #expect(await updates.next() == .connected)
    }

    @Test("given observation tracking, when the status changes, then SwiftUI-style observers are notified")
    @MainActor
    func observationNotifies() async {
        let monitor = NetworkMonitor(pathMonitor: nil)
        let changed = Counter()

        withObservationTracking {
            _ = monitor.status
        } onChange: {
            changed.increment()
        }
        monitor.receive(.connected)

        #expect(await eventually { changed.value == 1 })
    }
}
