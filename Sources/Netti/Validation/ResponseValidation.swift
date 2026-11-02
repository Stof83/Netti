//
//  ResponseValidation.swift
//  Netti
//

import Foundation

/// Rules that decide whether a response is acceptable.
///
/// Validation is off unless a client or an endpoint turns it on. A response that fails a rule
/// throws; the raw response stays available on the error.
///
/// ```swift
/// let strict = ResponseValidation()                       // 2xx, and Content-Type matching Accept
/// let lenient = ResponseValidation(statusCodes: Set(200..<500))
/// let off = ResponseValidation.disabled                   // an endpoint opting out of the client's rules
///
/// let netti = Netti()
/// netti.validation = strict
/// ```
public struct ResponseValidation: Sendable {
    /// How the response `Content-Type` is checked.
    public enum ContentTypeRule: Sendable {
        /// Any content type is accepted.
        case any
        /// The content type must match the request's `Accept` header; no `Accept` header means any.
        case matchAcceptHeader
        /// The content type must match one of these, each optionally a `type/*` wildcard.
        case only([String])
    }

    /// The statuses accepted; `nil` accepts every status.
    public var statusCodes: Set<Int>?

    /// How the `Content-Type` is checked. Responses with an empty body are never checked.
    public var contentTypes: ContentTypeRule

    /// An extra check run last. Throw to reject the response; the thrown error is kept as the reason.
    public var custom: (@Sendable (HTTPResponse<Data>) throws -> Void)?

    /// Creates a validation.
    ///
    /// - Parameters:
    ///   - statusCodes: The statuses accepted; `2xx` by default.
    ///   - contentTypes: How the `Content-Type` is checked; against `Accept` by default.
    ///   - custom: An extra check that throws to reject the response.
    public init(
        statusCodes: Set<Int>? = Set(200..<300),
        contentTypes: ContentTypeRule = .matchAcceptHeader,
        custom: (@Sendable (HTTPResponse<Data>) throws -> Void)? = nil
    ) {
        self.statusCodes = statusCodes
        self.contentTypes = contentTypes
        self.custom = custom
    }

    /// Accepts every response; set it on an endpoint to opt out of the client's validation.
    public static let disabled = ResponseValidation(statusCodes: nil, contentTypes: .any)

    /// Checks `response` against the rules.
    ///
    /// A response without an HTTP status, such as a cached or sample one, skips the status and
    /// content type rules.
    ///
    /// - Parameter response: The raw response.
    /// - Throws: ``HTTPRequestError/unacceptableStatusCode(_:response:)``,
    ///   ``HTTPRequestError/unacceptableContentType(_:response:)`` or
    ///   ``HTTPRequestError/validationFailed(_:response:)``.
    public func validate(_ response: HTTPResponse<Data>) throws(HTTPRequestError) {
        if let statusCodes, let status = response.statusCode, statusCodes.contains(status) == false {
            throw .unacceptableStatusCode(status, response: response)
        }
        try validateContentType(of: response)
        if let custom {
            do {
                try custom(response)
            } catch {
                throw .validationFailed(error, response: response)
            }
        }
    }

    private func validateContentType(of response: HTTPResponse<Data>) throws(HTTPRequestError) {
        guard let httpResponse = response.response, response.rawData?.isEmpty == false else {
            return
        }
        let accepted: [String]
        switch contentTypes {
            case .any:
                return
            case .matchAcceptHeader:
                guard let accept = response.request?.value(forHTTPHeaderField: "Accept") else {
                    return
                }
                accepted = accept.split(separator: ",").map { String($0) }
            case .only(let types):
                accepted = types
        }
        let received = httpResponse.value(forHTTPHeaderField: "Content-Type")
        let receivedType = received.map(Self.mediaType)
        let matches = accepted.map(Self.mediaType).contains { pattern in
            pattern == "*/*" || receivedType.map { Self.matches($0, pattern: pattern) } ?? false
        }
        if matches == false {
            throw .unacceptableContentType(received, response: response)
        }
    }

    /// `"Application/JSON; charset=utf-8"` becomes `"application/json"`.
    private static func mediaType(_ value: String) -> String {
        let type = value.split(separator: ";", maxSplits: 1).first ?? ""
        return type.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func matches(_ type: String, pattern: String) -> Bool {
        if pattern.hasSuffix("/*") {
            return type.hasPrefix(pattern.dropLast())
        }
        return type == pattern
    }
}
