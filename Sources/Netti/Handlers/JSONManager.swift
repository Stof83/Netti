//
//  JSONManager.swift
//  
//
//  Created by El Mostafa El Ouatri on 30/09/24.
//

import Foundation

/// An enumeration representing the key encoding and decoding strategies for JSON.
public enum KeyEncodingDecodingStrategy: Sendable {
    /// Maps `camelCase` properties to `snake_case` keys when encoding, and back when decoding.
    case convertSnakeCase
    /// Uses the property names as keys, unchanged.
    case useDefaultKeys

    /// Converts the `KeyEncodingDecodingStrategy` to a `JSONEncoder.KeyEncodingStrategy`.
    ///
    /// `.convertSnakeCase` keeps acronyms together, the same conversion query keys use: `URLValue`
    /// becomes `url_value` and `ID` becomes `id`, where `JSONEncoder`'s own `.convertToSnakeCase`
    /// writes `u_rl_value` and `i_d`.
    ///
    /// - Returns: A `.custom` snake_case strategy, or `.useDefaultKeys`.
    public func toEncoderStrategy() -> JSONEncoder.KeyEncodingStrategy {
        switch self {
            case .convertSnakeCase:
                return .custom { codingPath in
                    FormCodingKey(stringValue: codingPath.last?.stringValue.snakeCased ?? "")
                }
            case .useDefaultKeys:
                return .useDefaultKeys
        }
    }
    
    /// Converts the `KeyEncodingDecodingStrategy` to a `JSONDecoder.KeyDecodingStrategy`.
    ///
    /// - Returns: `.convertFromSnakeCase` or `.useDefaultKeys`.
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
///
/// ``Netti`` uses one to encode JSON bodies and decode every response. By default keys are
/// converted to and from `snake_case`:
///
/// ```swift
/// let netti = Netti()
/// netti.jsonManager = JSONManager(keyStrategy: .useDefaultKeys)
/// ```
public final class JSONManager: Sendable {

    // MARK: Public Properties
    /// The encoder for request bodies and WebSocket messages.
    public let encoder: JSONEncoder
    /// The decoder for response bodies and WebSocket messages.
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
    /// - Throws: `EncodingError` if the encoding fails.
    /// - Returns: The encoded JSON data.
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }
    
    /// Decodes JSON data to a Swift object.
    ///
    /// When `T` conforms to ``EmptyResponse`` the body is ignored and `T.emptyValue()` is returned.
    ///
    /// - Parameter type: The type of the value to decode.
    /// - Parameter data: The JSON data to decode.
    /// - Throws: `DecodingError` if the decoding fails.
    /// - Returns: The decoded value.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data?) throws -> T {
        if let emptyType = T.self as? any EmptyResponse.Type, let emptyValue = emptyType.emptyValue() as? T {
            return emptyValue
        }
        return try decoder.decode(T.self, from: data ?? Data())
    }
}
