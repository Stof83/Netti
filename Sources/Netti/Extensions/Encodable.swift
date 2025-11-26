//
//  Encodable.swift
//
//  Created by El Mostafa El Ouatri on 01/03/23.
//
//

import Foundation

extension Encodable {

    /// Converts the Encodable object into a dictionary using specified date format and key encoding strategy.
    /// - Parameters:
    ///   - dateFormat: A custom date format for encoding dates. Default is ISO 8601 format.
    ///   - keyEncodingStrategy: The key encoding strategy for encoding keys. Default is `convertToSnakeCase`.
    /// - Returns: A dictionary representation of the object, or nil if encoding fails.
    public func toDictionary(
        dateFormat: String = "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy = .convertToSnakeCase
    ) -> [String: Any]? {
        
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = dateFormat

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = keyEncodingStrategy
        encoder.dateEncodingStrategy = .formatted(dateFormatter)

        return encoder.toDictionary(self)
        
    }

}

