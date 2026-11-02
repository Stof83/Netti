//
//  URLEncodedFormComponentEncoder.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation

// MARK: - Component Tree

/// The intermediate tree a value encodes into before it is flattened into key/value pairs.
enum URLEncodedFormComponent {
    typealias Member = (key: String, value: URLEncodedFormComponent)

    case string(String)
    case array([URLEncodedFormComponent])
    case object([Member])

    /// Stores `component` at `path`, creating intermediate arrays and objects as needed.
    mutating func set(_ component: URLEncodedFormComponent, at path: some Collection<FormCodingKey>) {
        guard let first = path.first else {
            self = component
            return
        }
        let remainingPath = path.dropFirst()

        if first.isIndex, let index = first.intValue {
            var elements = if case .array(let existing) = self { existing } else { [URLEncodedFormComponent]() }
            while elements.count <= index {
                elements.append(.object([]))
            }
            elements[index].set(component, at: remainingPath)
            self = .array(elements)
        } else {
            var members = if case .object(let existing) = self { existing } else { [Member]() }
            if let memberIndex = members.firstIndex(where: { $0.key == first.stringValue }) {
                members[memberIndex].value.set(component, at: remainingPath)
            } else {
                var child = URLEncodedFormComponent.object([])
                child.set(component, at: remainingPath)
                members.append((first.stringValue, child))
            }
            self = .object(members)
        }
    }
}

/// Shared, mutable root of one encoding pass. Containers write into it by path.
final class URLEncodedFormContext {
    var component = URLEncodedFormComponent.object([])
}

/// A coding key that records whether it addresses an array element or a keyed member.
struct FormCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    let isIndex: Bool

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
        self.isIndex = false
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
        self.isIndex = true
    }

    static let superKey = FormCodingKey(stringValue: "super")
}

// MARK: - Encoder

struct URLEncodedFormComponentEncoder: Encoder {
    /// The deepest key path encoded; deeper values throw instead of exhausting the stack on a
    /// self-nesting value.
    static let maximumDepth = 32

    let context: URLEncodedFormContext
    let options: URLEncodedFormEncoder
    let formPath: [FormCodingKey]

    var codingPath: [any CodingKey] { formPath }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(KeyedContainer<Key>(encoder: self))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        UnkeyedContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleValueContainer(encoder: self)
    }

    func appending(_ key: FormCodingKey) -> URLEncodedFormComponentEncoder {
        URLEncodedFormComponentEncoder(context: context, options: options, formPath: formPath + [key])
    }

    /// Encodes leaf values directly and lets every other value describe itself through containers.
    ///
    /// Every primitive must be matched here: primitives encode by calling back into a single-value
    /// container, so an unmatched primitive would recurse forever.
    func encode<Value: Encodable>(_ value: Value) throws {
        guard formPath.count <= Self.maximumDepth else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: Array(codingPath.prefix(Self.maximumDepth)),
                    debugDescription: "URL-encoded forms nest at most \(Self.maximumDepth) levels."
                )
            )
        }
        switch value {
            case let string as String:
                set(.string(string))
            case let bool as Bool:
                set(.string(options.boolEncoding.encode(bool)))
            case let integer as any BinaryInteger:
                set(.string(String(describing: integer)))
            case let floatingPoint as any BinaryFloatingPoint:
                guard floatingPoint.isFinite else {
                    throw EncodingError.invalidValue(
                        value,
                        EncodingError.Context(codingPath: codingPath, debugDescription: "Non-finite numbers cannot be URL-encoded.")
                    )
                }
                set(.string(String(describing: floatingPoint)))
            case let decimal as Decimal:
                set(.string(decimal.description))
            case let date as Date:
                set(.string(try options.dateEncoding.encode(date)))
            case let url as URL:
                set(.string(url.absoluteString))
            default:
                try value.encode(to: self)
        }
    }

    private func set(_ component: URLEncodedFormComponent) {
        context.component.set(component, at: formPath)
    }
}

// MARK: - Containers

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: URLEncodedFormComponentEncoder

    var codingPath: [any CodingKey] { encoder.codingPath }

    /// `nil` members are omitted from the form.
    mutating func encodeNil(forKey key: Key) throws {}

    mutating func encode<Value: Encodable>(_ value: Value, forKey key: Key) throws {
        try nestedEncoder(forKey: key).encode(value)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        nestedEncoder(forKey: key).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        nestedEncoder(forKey: key).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        encoder.appending(.superKey)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        nestedEncoder(forKey: key)
    }

    private func nestedEncoder(forKey key: Key) -> URLEncodedFormComponentEncoder {
        encoder.appending(FormCodingKey(stringValue: encoder.options.keyEncoding.encode(key.stringValue)))
    }
}

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    let encoder: URLEncodedFormComponentEncoder
    private(set) var count = 0

    init(encoder: URLEncodedFormComponentEncoder) {
        self.encoder = encoder
    }

    var codingPath: [any CodingKey] { encoder.codingPath }

    /// `nil` elements keep their index but produce no pair.
    mutating func encodeNil() throws {
        count += 1
    }

    mutating func encode<Value: Encodable>(_ value: Value) throws {
        try nextEncoder().encode(value)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        nextEncoder().container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        nextEncoder().unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        nextEncoder()
    }

    private mutating func nextEncoder() -> URLEncodedFormComponentEncoder {
        defer { count += 1 }
        return encoder.appending(FormCodingKey(intValue: count))
    }
}

private struct SingleValueContainer: SingleValueEncodingContainer {
    let encoder: URLEncodedFormComponentEncoder

    var codingPath: [any CodingKey] { encoder.codingPath }

    /// A `nil` single value is omitted from the form.
    mutating func encodeNil() throws {}

    mutating func encode<Value: Encodable>(_ value: Value) throws {
        try encoder.encode(value)
    }
}
