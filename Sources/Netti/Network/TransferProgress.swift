//
//  TransferProgress.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation
import os

/// Called with the progress of an upload or a download.
///
/// Netti calls it on a background queue, in order, with increasing values, and at least once with
/// a ``TransferProgress/fractionCompleted`` of `1.0` when the transfer succeeds. Hop to the main
/// actor before touching UI.
public typealias ProgressHandler = @Sendable (TransferProgress) -> Void

/// A snapshot of how far an upload or a download has gone.
public struct TransferProgress: Sendable, Equatable {

    // MARK: - Properties

    /// The bytes transferred so far.
    public let completedUnitCount: Int64

    /// The total bytes to transfer, or `nil` when the size is not known in advance
    /// (a streamed upload, or a download without `Content-Length`).
    public let totalUnitCount: Int64?

    /// The completed fraction, from `0.0` to `1.0`; `0.0` while the total is unknown.
    public var fractionCompleted: Double {
        guard let totalUnitCount else {
            return 0
        }
        guard totalUnitCount > 0 else {
            return 1
        }
        return min(1, Double(completedUnitCount) / Double(totalUnitCount))
    }

    // MARK: - Initialization

    /// Creates a progress snapshot.
    ///
    /// - Parameters:
    ///   - completedUnitCount: The bytes transferred so far.
    ///   - totalUnitCount: The total bytes, or `nil` when unknown. Negative values mean unknown.
    public init(completedUnitCount: Int64, totalUnitCount: Int64?) {
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount.flatMap { $0 < 0 ? nil : $0 }
    }
}

// MARK: - ProgressReporter

/// Forwards transport progress to a ``ProgressHandler`` with the guarantees it documents:
/// increasing values only, and a final `1.0` on success even when the transport never reported one.
///
/// Both engines use it, so they report progress identically.
final class ProgressReporter: Sendable {

    // MARK: - Properties

    private let handler: ProgressHandler
    private let last = OSAllocatedUnfairLock<TransferProgress?>(initialState: nil)

    // MARK: - Initialization

    init?(_ handler: ProgressHandler?) {
        guard let handler else {
            return nil
        }
        self.handler = handler
    }

    // MARK: - Reporting

    /// Reports transport progress; values that do not move forward are dropped.
    ///
    /// - Parameters:
    ///   - completed: The bytes transferred so far.
    ///   - total: The expected total; zero or negative means unknown.
    func report(completed: Int64, total: Int64) {
        let progress = TransferProgress(completedUnitCount: completed, totalUnitCount: total > 0 ? total : nil)
        let isForward = last.withLock { last in
            guard let previous = last else {
                last = progress
                return true
            }
            guard progress.completedUnitCount > previous.completedUnitCount
                    || (progress.completedUnitCount == previous.completedUnitCount && progress.totalUnitCount != previous.totalUnitCount)
            else {
                return false
            }
            last = progress
            return true
        }
        if isForward {
            handler(progress)
        }
    }

    /// Reports completion with a fraction of `1.0`, unless the last report already reached it.
    ///
    /// - Parameter completed: The bytes the transport says it transferred.
    func finish(completed: Int64) {
        let final: TransferProgress? = last.withLock { last in
            if let last, last.totalUnitCount != nil, last.fractionCompleted >= 1 {
                return nil
            }
            let total = max(completed, last?.totalUnitCount ?? 0, last?.completedUnitCount ?? 0)
            let progress = TransferProgress(completedUnitCount: total, totalUnitCount: total)
            last = progress
            return progress
        }
        if let final {
            handler(final)
        }
    }
}
