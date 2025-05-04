//
//  Sequence.swift
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation

extension Sequence {
    public func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var values = [T]()

        for element in self {
            try await values.append(transform(element))
        }

        return values
    }
}

extension Sequence {
    public func asyncForEach(
        _ operation: (Element) async throws -> Void
    ) async rethrows {
        for element in self {
            try await operation(element)
        }
    }
}

/*
extension Sequence {
    public func concurrentForEach(
        _ operation: @Sendable @escaping (Element) async -> Void
    ) async {
        await withTaskGroup { group in
            for element in self {
                group.addTask {
                    await operation(element)
                }
            }
        }
    }
}
*/
