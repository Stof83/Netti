//
//  Support.swift
//  Netti
//

import Foundation
import Netti
import os

// MARK: - Output

/// Writes a line to stdout. The package never uses `print(`.
func report(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

// MARK: - Checks

/// A failed expectation inside an example; makes `swift run NettiExamples` exit non-zero.
struct ExampleError: Error, CustomStringConvertible {
    let description: String
}

/// Throws when `condition` is false, so a stale example fails loudly instead of printing nonsense.
func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if condition == false {
        throw ExampleError(description: message())
    }
}

// MARK: - Counter

/// A thread-safe counter for refresh and request counts.
final class Counter: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)

    var value: Int {
        storage.withLock { $0 }
    }

    @discardableResult
    func increment() -> Int {
        storage.withLock { count in
            count += 1
            return count
        }
    }
}

// MARK: - Models

struct User: Codable, Sendable, Equatable {
    let id: Int
    let name: String
}

struct NewUser: Codable, Sendable {
    let name: String
}

struct UserFilter: Encodable, Sendable {
    let ids: [Int]
    let isActive: Bool
}

// MARK: - Endpoints

/// The endpoints most examples use. `example.com` hosts are never contacted: every example
/// answers from a stub.
enum UserAPI: HTTPRequest {
    case users
    case user(Int)

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "v1" }
    var path: String {
        switch self {
            case .users: "users"
            case .user(let id): "users/\(id)"
        }
    }
    var headers: HTTPHeaders { [.accept("application/json")] }
}

// MARK: - Unwrapping

/// Returns `value`, or throws when it is nil; examples never force-unwrap.
func expectValue<Value>(_ value: Value?, _ message: @autoclosure () -> String) throws -> Value {
    guard let value else {
        throw ExampleError(description: message())
    }
    return value
}

// MARK: - Recorder

/// A thread-safe list, for monitors and handlers that note what they saw.
final class Recorder<Element: Sendable>: Sendable {
    private let storage = OSAllocatedUnfairLock<[Element]>(initialState: [])

    var values: [Element] {
        storage.withLock { $0 }
    }

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }
}
