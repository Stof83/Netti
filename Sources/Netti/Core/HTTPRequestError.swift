//
//  HTTPRequestError.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation

/// The single error type thrown by every Netti request API.
///
/// Every API uses typed throws, so a `catch` block receives an `HTTPRequestError` directly:
///
/// ```swift
/// do {
///     let user: User? = try await netti.get(UserAPI.me).data
/// } catch .unacceptableStatusCode(404, _) {
///     showSignUp()
/// } catch {
///     log(error.response?.statusCode)
/// }
/// ```
public enum HTTPRequestError: Error, Sendable {
    /// The endpoint has no base URL, or its URL could not be built.
    case invalidURL
    /// The parameters or body could not be encoded.
    case encodingFailed(any Error)
    /// The transport failed before a response was received.
    case requestFailed(URLError)
    /// TLS server trust evaluation (including pinning) rejected the host.
    case serverTrustEvaluationFailed(host: String, reason: String)
    /// Response validation rejected the status code.
    case unacceptableStatusCode(Int, response: HTTPResponse<Data>)
    /// Response validation rejected the `Content-Type` (`nil` when the header is missing).
    case unacceptableContentType(String?, response: HTTPResponse<Data>)
    /// A custom validation rejected the response; the error is the validator's reason.
    case validationFailed(any Error, response: HTTPResponse<Data>)
    /// The response body could not be decoded into the requested type.
    case decodingFailed(any Error, response: HTTPResponse<Data>?)
    /// The calling task or the request was cancelled.
    case cancelled
    /// Every allowed retry was used; `lastError` is the failure of the final attempt.
    indirect case retryLimitExceeded(attempts: Int, lastError: HTTPRequestError)
    /// A file could not be read, written or moved.
    case fileSystem(any Error)
    /// A download failed or was cancelled after part of the body arrived; pass `resumeData` to
    /// ``Netti/download(_:to:options:resumeData:progress:)`` to continue it.
    indirect case downloadFailed(HTTPRequestError, resumeData: Data)
}

extension HTTPRequestError {
    /// The raw server response associated with the failure, when one was received.
    public var response: HTTPResponse<Data>? {
        switch self {
            case .unacceptableStatusCode(_, let response), .unacceptableContentType(_, let response), .validationFailed(_, let response):
                response
            case .decodingFailed(_, let response):
                response
            case .retryLimitExceeded(_, let lastError), .downloadFailed(let lastError, _):
                lastError.response
            case .invalidURL, .encodingFailed, .requestFailed, .serverTrustEvaluationFailed, .cancelled, .fileSystem:
                nil
        }
    }

    /// The data that resumes the failed download, when the server supports resumption.
    public var resumeData: Data? {
        guard case .downloadFailed(_, let resumeData) = self else {
            return nil
        }
        return resumeData
    }

    /// Maps any error thrown by a transport into an `HTTPRequestError`.
    ///
    /// An `HTTPRequestError` passes through unchanged, so errors already classified upstream
    /// (for example `decodingFailed`) are never re-wrapped.
    package static func transport(_ error: any Error) -> HTTPRequestError {
        if let requestError = error as? HTTPRequestError {
            return requestError
        }
        if error is CancellationError {
            return .cancelled
        }
        guard let urlError = error as? URLError else {
            return .requestFailed(URLError(.unknown, userInfo: [NSUnderlyingErrorKey: error]))
        }
        return urlError.code == .cancelled ? .cancelled : .requestFailed(urlError)
    }
}

// MARK: - Description

extension HTTPRequestError: CustomStringConvertible, CustomDebugStringConvertible {
    /// The case with the status, method, host and path of the response it holds.
    ///
    /// Headers, query strings, bodies and underlying error values are left out, so the text can go
    /// to a crash reporter or analytics without carrying a credential.
    public var description: String {
        switch self {
            case .invalidURL:
                "invalidURL"
            case .encodingFailed(let error):
                "encodingFailed(\(Self.summary(of: error)))"
            case .requestFailed(let urlError):
                "requestFailed(URLError \(urlError.code.rawValue))"
            case .serverTrustEvaluationFailed(let host, let reason):
                "serverTrustEvaluationFailed(host: \(host), reason: \(reason))"
            case .unacceptableStatusCode(let status, let response):
                "unacceptableStatusCode(\(status), \(Self.summary(of: response)))"
            case .unacceptableContentType(let contentType, let response):
                "unacceptableContentType(\(contentType ?? "nil"), \(Self.summary(of: response)))"
            case .validationFailed(let error, let response):
                "validationFailed(\(Self.summary(of: error)), \(Self.summary(of: response)))"
            case .decodingFailed(let error, let response):
                "decodingFailed(\(Self.summary(of: error)), \(response.map(Self.summary(of:)) ?? "no response"))"
            case .cancelled:
                "cancelled"
            case .retryLimitExceeded(let attempts, let lastError):
                "retryLimitExceeded(attempts: \(attempts), lastError: \(lastError))"
            case .fileSystem(let error):
                "fileSystem(\(Self.summary(of: error)))"
            case .downloadFailed(let error, let resumeData):
                "downloadFailed(\(error), resumeData: \(resumeData.count) bytes)"
        }
    }

    /// The same text as ``description``.
    public var debugDescription: String {
        description
    }

    private static func summary(of response: HTTPResponse<Data>) -> String {
        Redaction.summary(of: response.request, url: response.response?.url)
    }

    /// Describes an underlying error by kind and location, never by the values it holds.
    private static func summary(of error: any Error) -> String {
        switch error {
            case let error as HTTPRequestError:
                return error.description
            case let error as InvalidHeaderError:
                return error.description
            case let error as InvalidMultipartFormError:
                return error.description
            case let error as URLError:
                return "URLError \(error.code.rawValue)"
            case let error as CocoaError:
                return "CocoaError \(error.code.rawValue)"
            case let error as EncodingError:
                guard case .invalidValue(_, let context) = error else {
                    return "EncodingError"
                }
                return "EncodingError.invalidValue at \(path(context.codingPath)): \(context.debugDescription)"
            case let error as DecodingError:
                return summary(of: error)
            default:
                return String(reflecting: type(of: error))
        }
    }

    private static func summary(of error: DecodingError) -> String {
        switch error {
            case .typeMismatch(let type, let context):
                "DecodingError.typeMismatch(\(type)) at \(path(context.codingPath))"
            case .valueNotFound(let type, let context):
                "DecodingError.valueNotFound(\(type)) at \(path(context.codingPath))"
            case .keyNotFound(let key, let context):
                "DecodingError.keyNotFound(\(key.stringValue)) at \(path(context.codingPath))"
            case .dataCorrupted(let context):
                "DecodingError.dataCorrupted at \(path(context.codingPath))"
            @unknown default:
                "DecodingError"
        }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.isEmpty ? "the top level" : codingPath.map(\.stringValue).joined(separator: ".")
    }
}
