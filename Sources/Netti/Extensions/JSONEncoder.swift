//
//  JSONEncoder.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 04/05/25.
//

import Foundation

/// Converts encodable values into JSON objects.
extension JSONEncoder {
    /// Converts the Encodable object into a dictionary using this JSONEncoder instance.
    ///
    /// - Parameter value: The `Encodable` object to convert.
    /// - Returns: A dictionary representation of the object, or `nil` if encoding fails or the value
    ///   does not encode as a JSON object.
    public func toDictionary<T: Encodable>(_ value: T) -> [String: any Any & Sendable]? {
        do {
            let data = try self.encode(value)
            let json = try JSONSerialization.jsonObject(with: data, options: .allowFragments)
            return json as? [String: any Any & Sendable]
        } catch {
            return nil
        }
    }
}
