//
//  DecodingError.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 06/05/25.
//

import Foundation

extension DecodingError {
    /// Returns a detailed, multi-line description of the decoding error.
    ///
    /// - Parameters:
    ///   - type: The type that was attempted to decode.
    ///   - data: The raw `Data` that failed to decode.
    /// - Returns: A formatted string describing the error and its context.
    func stringDescription<T: Decodable>(as type: T.Type, data: Data) -> String {
        var lines: [String] = []
        lines.append("Decoding failed for type: \(T.self)")

        switch self {
        case .typeMismatch(let expected, let context):
            lines.append("Type mismatch: expected \(expected)")
            lines.append("Coding path: \(context.codingPath.pathString())")
            lines.append("Debug description: \(context.debugDescription)")

        case .valueNotFound(let expected, let context):
            lines.append("Value not found: \(expected)")
            lines.append("Coding path: \(context.codingPath.pathString())")
            lines.append("Debug description: \(context.debugDescription)")

        case .keyNotFound(let key, let context):
            lines.append("Key not found: '\(key.stringValue)'")
            lines.append("Coding path: \(context.codingPath.pathString())")
            lines.append("Debug description: \(context.debugDescription)")

        case .dataCorrupted(let context):
            lines.append("Data corrupted")
            lines.append("Coding path: \(context.codingPath.pathString())")
            lines.append("Debug description: \(context.debugDescription)")

        @unknown default:
            lines.append("Unknown decoding error")
        }

        if let rawJSON = String(data: data, encoding: .utf8) {
            lines.append("Raw JSON:")
            lines.append(rawJSON)
        }

        return lines.joined(separator: "\n")
    }
}

private extension Array where Element == CodingKey {
    func pathString() -> String {
        map(\.stringValue).joined(separator: ".")
    }
}
