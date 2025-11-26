//
//  JSONManager.swift
//  
//
//  Created by El Mostafa El Ouatri on 30/09/24.
//

import Foundation

/// An enumeration representing the key encoding and decoding strategies for JSON.
public enum KeyEncodingDecodingStrategy {
    case convertSnakeCase
    case useDefaultKeys

    /// Converts the `KeyEncodingDecodingStrategy` to a `JSONEncoder.KeyEncodingStrategy`.
    public func toEncoderStrategy() -> JSONEncoder.KeyEncodingStrategy {
        switch self {
            case .convertSnakeCase:
                return .convertToSnakeCase
            case .useDefaultKeys:
                return .useDefaultKeys
        }
    }
    
    /// Converts the `KeyEncodingDecodingStrategy` to a `JSONDecoder.KeyDecodingStrategy`.
    public func toDecoderStrategy() -> JSONDecoder.KeyDecodingStrategy {
        switch self {
            case .convertSnakeCase:
                return .convertFromSnakeCase
            case .useDefaultKeys:
                return .useDefaultKeys
        }
    }
}

/// A class that provides a unified interface for JSON encoding and decoding.
public class JSONManager {

    // MARK: Public Properties
    public let encoder: JSONEncoder
    public let decoder: JSONDecoder
    
    /// Initializes a `JSONManager` with custom date and key strategies for both encoding and decoding.
    ///
    /// - Parameters:
    ///   - dateFormat: A `String` representing the date format to be used for encoding and decoding dates.
    ///     The default value is `"yyyy-MM-dd'T'HH:mm:ss.SSSZ"`.
    ///   - keyStrategy: A `KeyEncodingDecodingStrategy` indicating how keys should be encoded and decoded.
    ///     The default value is `.convertSnakeCase`, which converts keys to snake case during encoding and decoding.
    public init(
        dateFormat: String = "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        keyStrategy: KeyEncodingDecodingStrategy = .convertSnakeCase
    ) {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = dateFormat

        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = keyStrategy.toEncoderStrategy()
        encoder.dateEncodingStrategy = .formatted(dateFormatter)

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = keyStrategy.toDecoderStrategy()
        decoder.dateDecodingStrategy = .formatted(dateFormatter)
    }
    
    /// Initializes a `JSONManager` with preconfigured `JSONEncoder` and `JSONDecoder`.
    ///
    /// - Parameters:
    ///   - encoder: A preconfigured `JSONEncoder` instance to be used for encoding.
    ///   - decoder: A preconfigured `JSONDecoder` instance to be used for decoding.
    public init(encoder: JSONEncoder, decoder: JSONDecoder) {
        self.encoder = encoder
        self.decoder = decoder
    }
    
    /// Encodes a Swift object to JSON data.
    ///
    /// - Parameter value: The value to encode.
    /// - Throws: An error if the encoding fails.
    /// - Returns: The encoded JSON data.
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }
    
    /// Decodes JSON data to a Swift object.
    ///
    /// - Parameter type: The type of the value to decode.
    /// - Parameter data: The JSON data to decode.
    /// - Throws: An error if the decoding fails.
    /// - Returns: The decoded value.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data?) throws -> T {
        try decoder.decode(T.self, from: data ?? Data())
    }
}
