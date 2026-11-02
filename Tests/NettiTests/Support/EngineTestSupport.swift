import Foundation
import os
import Testing

@testable import Netti

/// The engines under the shared contract suite.
enum EngineKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case urlSession = "URLSession"
    case alamofire = "Alamofire"

    var testDescription: String {
        rawValue
    }

    func makeService() -> any NetworkService {
        switch self {
            case .urlSession:
                URLSessionNetworkService(configuration: .ephemeral)
            case .alamofire:
                AFNetworkService(configuration: .ephemeral)
        }
    }
}

/// Records every progress update it receives.
final class ProgressRecorder: Sendable {
    private let values = OSAllocatedUnfairLock<[TransferProgress]>(initialState: [])

    var updates: [TransferProgress] {
        values.withLock { $0 }
    }

    var handler: ProgressHandler {
        { [values] progress in values.withLock { $0.append(progress) } }
    }

    /// Records issues unless updates only move forward and the last one reaches `1.0`.
    func expectCompleted(total: Int64? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let updates = updates
        #expect(updates.isEmpty == false, "no progress reported", sourceLocation: sourceLocation)
        let completedCounts = updates.map(\.completedUnitCount)
        #expect(completedCounts == completedCounts.sorted(), "progress moved backwards: \(completedCounts)", sourceLocation: sourceLocation)
        #expect(updates.last?.fractionCompleted == 1, sourceLocation: sourceLocation)
        if let total {
            #expect(updates.last?.completedUnitCount == total, sourceLocation: sourceLocation)
        }
    }
}

/// Runs `body` and returns the error it throws, recording an issue when it does not throw.
func expectRequestError<Value>(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws(HTTPRequestError) -> Value
) async -> HTTPRequestError? {
    do {
        let value = try await body()
        Issue.record("Expected an HTTPRequestError, got \(value)", sourceLocation: sourceLocation)
        return nil
    } catch {
        return error
    }
}

extension HTTPRequestError {
    /// The `URLError` code of a `requestFailed` error.
    var urlErrorCode: URLError.Code? {
        guard case .requestFailed(let urlError) = self else {
            return nil
        }
        return urlError.code
    }

    var isCancelled: Bool {
        if case .cancelled = self {
            return true
        }
        return false
    }

    var isFileSystem: Bool {
        if case .fileSystem = self {
            return true
        }
        return false
    }
}

/// A payload with a recognizable, non-repeating-at-small-scale byte pattern.
func testPayload(count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 % 251) })
}
