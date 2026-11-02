//
//  RequestInterceptor.swift
//  Netti
//

import Foundation

/// A type that both adapts requests and decides retries.
///
/// Both requirements have pass-through defaults, so an interceptor implements only what it needs.
/// Set them on ``Netti/interceptors``; they run in order.
///
/// ```swift
/// struct LocaleInterceptor: RequestInterceptor {
///     func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
///         var request = urlRequest
///         request.setValue(Locale.current.identifier, forHTTPHeaderField: "Accept-Language")
///         return request
///     }
/// }
/// ```
public protocol RequestInterceptor: RequestAdapter, RequestRetrier {}

extension RequestInterceptor {
    /// Returns `urlRequest` unchanged.
    ///
    /// - Parameter urlRequest: The request about to be sent.
    /// - Returns: The same request.
    /// - Throws: Never; the signature matches ``RequestAdapter/adapt(_:)``.
    public func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        urlRequest
    }

    /// Never retries.
    ///
    /// - Parameter context: The failed attempt.
    /// - Returns: ``RetryDecision/doNotRetry``.
    public func retry(_ context: RetryContext) async -> RetryDecision {
        .doNotRetry
    }
}

/// Combines any number of adapters and retriers into one interceptor.
///
/// Adapters run in order, each receiving the previous one's output. Retriers are asked in order:
/// the first to ask for a retry wins; otherwise ``RetryDecision/retryLimitExceeded`` from any
/// retrier beats ``RetryDecision/doNotRetry``.
public struct CompositeInterceptor: RequestInterceptor {
    private let adapters: [any RequestAdapter]
    private let retriers: [any RequestRetrier]

    /// Creates a composite from separate adapters and retriers.
    ///
    /// - Parameters:
    ///   - adapters: The adapters, run in order. None by default.
    ///   - retriers: The retriers, asked in order. None by default.
    public init(adapters: [any RequestAdapter] = [], retriers: [any RequestRetrier] = []) {
        self.adapters = adapters
        self.retriers = retriers
    }

    /// Creates a composite from interceptors, each acting as adapter and retrier.
    ///
    /// - Parameter interceptors: The interceptors, in order.
    public init(_ interceptors: [any RequestInterceptor]) {
        self.init(adapters: interceptors, retriers: interceptors)
    }

    /// Asynchronously runs every adapter in order, each on the previous one's output.
    ///
    /// - Parameter urlRequest: The request about to be sent.
    /// - Returns: The request after the last adapter.
    /// - Throws: The first error an adapter throws; later adapters do not run.
    public func adapt(_ urlRequest: URLRequest) async throws -> URLRequest {
        var request = urlRequest
        for adapter in adapters {
            request = try await adapter.adapt(request)
        }
        return request
    }

    /// Asynchronously asks every retrier in order and returns the first retry decision.
    ///
    /// - Parameter context: The failed attempt.
    /// - Returns: The first ``RetryDecision/retry`` or ``RetryDecision/retryAfter(_:)``; otherwise
    ///   ``RetryDecision/retryLimitExceeded`` if any retrier returned it, else ``RetryDecision/doNotRetry``.
    public func retry(_ context: RetryContext) async -> RetryDecision {
        var result = RetryDecision.doNotRetry
        for retrier in retriers {
            switch await retrier.retry(context) {
                case .doNotRetry:
                    break
                case .retryLimitExceeded:
                    result = .retryLimitExceeded
                case let decision:
                    return decision
            }
        }
        return result
    }
}

extension RequestAdapter {
    /// Adapts `urlRequest`, mapping a thrown error into ``HTTPRequestError``.
    func adapted(_ urlRequest: URLRequest) async throws(HTTPRequestError) -> URLRequest {
        do {
            return try await adapt(urlRequest)
        } catch {
            throw .transport(error)
        }
    }
}
