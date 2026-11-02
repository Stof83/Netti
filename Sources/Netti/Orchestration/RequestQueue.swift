//
//  RequestQueue.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 28/10/26.
//

import Foundation

/// Runs operations in order, a limited number at a time.
///
/// Higher-priority work starts first; work of equal priority starts in enqueue order. Each caller
/// gets its own operation's result. A queue that waits for connectivity holds its pending work
/// while the device is offline and drains it on reconnect.
///
/// ```swift
/// let queue = netti.queue(.serial(waitsForConnectivity: true))
/// let receipt: HTTPResponse<Receipt> = try await queue.enqueue {
///     try await netti.post(PaymentAPI.pay, body: payment)
/// }
/// ```
public actor RequestQueue {

    // MARK: - Types

    /// How many operations run at once, and whether the queue waits for connectivity.
    public struct Mode: Sendable {
        /// The most operations running at once.
        public let maxConcurrentOperations: Int

        /// Whether pending work is held while the device is offline.
        public let waitsForConnectivity: Bool

        /// One operation at a time.
        public static let serial = Mode(maxConcurrentOperations: 1, waitsForConnectivity: false)

        /// One operation at a time, optionally held while offline.
        ///
        /// - Parameter waitsForConnectivity: Whether pending work is held while the device is offline.
        /// - Returns: The mode.
        public static func serial(waitsForConnectivity: Bool) -> Mode {
            Mode(maxConcurrentOperations: 1, waitsForConnectivity: waitsForConnectivity)
        }

        /// Up to `max` operations at a time, optionally held while offline.
        ///
        /// - Parameters:
        ///   - max: The most operations running at once; values below 1 count as 1.
        ///   - waitsForConnectivity: Whether pending work is held while the device is offline. `false` by default.
        /// - Returns: The mode.
        public static func concurrent(max: Int, waitsForConnectivity: Bool = false) -> Mode {
            Mode(maxConcurrentOperations: Swift.max(1, max), waitsForConnectivity: waitsForConnectivity)
        }
    }

    /// The order in which pending operations start.
    public enum Priority: Int, Sendable, Comparable {
        /// Starts after every `normal` and `high` operation pending.
        case low
        /// The default priority.
        case normal
        /// Starts before every `normal` and `low` operation pending.
        case high

        /// Whether `lhs` starts after `rhs`, being of lower priority.
        ///
        /// - Parameters:
        ///   - lhs: A priority.
        ///   - rhs: Another priority.
        /// - Returns: `true` when `lhs` is lower than `rhs`.
        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    fileprivate struct PendingOperation {
        let id: Int
        let priority: Priority
        let start: CheckedContinuation<Bool, Never>
    }

    // MARK: - Properties

    /// The configuration of the queue.
    public nonisolated let mode: Mode

    /// Whether the queue is paused.
    public private(set) var isPaused = false

    private let connectivity: any ConnectivitySource
    private var pending: [PendingOperation] = []
    private var running: [Int: @Sendable () -> Void] = [:]
    private var nextID = 0
    private var connectivityObservation: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a queue.
    ///
    /// - Parameters:
    ///   - mode: Serial by default.
    ///   - connectivity: Decides when a queue that waits for connectivity is offline. Defaults to
    ///     ``NetworkMonitor/shared``.
    public init(_ mode: Mode = .serial, connectivity: any ConnectivitySource = NetworkMonitor.shared) {
        self.mode = mode
        self.connectivity = connectivity
    }

    deinit {
        connectivityObservation?.cancel()
    }

    // MARK: - State

    /// The number of operations waiting to start.
    public var pendingCount: Int {
        pending.count
    }

    /// The number of operations running.
    public var runningCount: Int {
        running.count
    }

    // MARK: - Enqueueing

    /// Runs `operation` once the queue lets it start, and returns its result.
    ///
    /// Cancelling the calling task withdraws a pending operation or cancels a running one.
    ///
    /// ```swift
    /// let response = try await queue.enqueue(priority: .high) {
    ///     try await netti.post(TripAPI.end, body: trip)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - priority: `normal` by default.
    ///   - operation: The work.
    /// - Returns: The operation's result.
    /// - Throws: The operation's error, or ``HTTPRequestError/cancelled`` when the calling task or
    ///   ``cancelAll()`` cancels it.
    @discardableResult
    public func enqueue<Value: Sendable>(
        priority: Priority = .normal,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = nextID
        nextID += 1
        observeConnectivityIfNeeded()

        let started = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                admit(PendingOperation(id: id, priority: priority, start: continuation))
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
        guard started else {
            throw HTTPRequestError.cancelled
        }

        let task = Task { try await operation() }
        running[id] = { task.cancel() }
        defer { finish(id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Control

    /// Stops starting pending operations; running ones continue.
    public func pause() {
        isPaused = true
    }

    /// Starts pending operations again.
    public func resume() {
        isPaused = false
        startPending()
    }

    /// Cancels every pending and running operation; their callers receive ``HTTPRequestError/cancelled``.
    public func cancelAll() {
        let cancelled = pending
        pending.removeAll()
        cancelled.forEach { $0.start.resume(returning: false) }
        running.values.forEach { $0() }
    }
}

// MARK: - Private Methods

private extension RequestQueue {
    var isHeldOffline: Bool {
        mode.waitsForConnectivity && connectivity.currentStatus == .disconnected
    }

    func admit(_ operation: PendingOperation) {
        // A cancellation handler that ran before this point found nothing to withdraw.
        guard Task.isCancelled == false else {
            operation.start.resume(returning: false)
            return
        }
        pending.append(operation)
        startPending()
    }

    func withdraw(_ id: Int) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            return
        }
        pending.remove(at: index).start.resume(returning: false)
    }

    func finish(_ id: Int) {
        running[id] = nil
        startPending()
    }

    func startPending() {
        while isPaused == false, isHeldOffline == false, running.count < mode.maxConcurrentOperations, let index = nextIndex() {
            let operation = pending.remove(at: index)
            // Reserves the slot until `enqueue` registers the running task.
            running[operation.id] = {}
            operation.start.resume(returning: true)
        }
    }

    /// The highest-priority pending operation, the earliest enqueued among equals.
    func nextIndex() -> Int? {
        pending.indices.min { lhs, rhs in
            (pending[lhs].priority, pending[rhs].id) > (pending[rhs].priority, pending[lhs].id)
        }
    }

    func observeConnectivityIfNeeded() {
        guard mode.waitsForConnectivity, connectivityObservation == nil else {
            return
        }
        let updates = connectivity.statusUpdates()
        connectivityObservation = Task { [weak self] in
            for await _ in updates {
                await self?.startPending()
            }
        }
    }
}
