//
//  RequestRetrier.swift
//  Netti
//

import Foundation

/// What a ``RequestRetrier`` wants done about a failed attempt.
public enum RetryDecision: Sendable, Equatable {
    /// Give up on this retrier's account; another retrier may still ask for a retry.
    case doNotRetry
    /// Send the request again immediately.
    case retry
    /// Send the request again no earlier than the given delay from now.
    case retryAfter(Duration)
    /// The failure is retryable but every allowed retry is spent; the call throws
    /// ``HTTPRequestError/retryLimitExceeded(attempts:lastError:)``.
    case retryLimitExceeded
}

/// Everything a retrier knows about a failed attempt.
public struct RetryContext: Sendable {
    /// The request as it was sent, after adaptation.
    public let request: URLRequest

    /// The response of the failed attempt, when one was received.
    public let response: HTTPResponse<Data>?

    /// The error of the failed attempt, when it threw.
    public let error: HTTPRequestError?

    /// How many times the request has already been retried; `0` on the first failure.
    public let retryCount: Int

    /// Creates a context.
    ///
    /// - Parameters:
    ///   - request: The request as it was sent.
    ///   - response: The response of the failed attempt, if any.
    ///   - error: The error of the failed attempt, if any.
    ///   - retryCount: How many retries have already happened.
    public init(request: URLRequest, response: HTTPResponse<Data>?, error: HTTPRequestError?, retryCount: Int) {
        self.request = request
        self.response = response
        self.error = error
        self.retryCount = retryCount
    }

    /// The server response of the failed attempt, whether it was returned or carried by the error.
    public var failureResponse: HTTPResponse<Data>? {
        response ?? error?.response
    }

    /// The HTTP status code of the failed attempt, from the response or the error.
    public var statusCode: Int? {
        failureResponse?.statusCode
    }

    /// The HTTP method of the request, `nil` when it is not a standard one.
    public var method: HTTPMethod? {
        HTTPMethod(rawValue: request.httpMethod ?? HTTPMethod.get.rawValue)
    }
}

/// Decides whether a failed attempt is sent again.
///
/// A retrier is consulted after every attempt that threw, or returned a non-2xx status.
/// With several retriers the first one that asks for a retry wins.
public protocol RequestRetrier: Sendable {
    /// Decides what to do about a failed attempt.
    ///
    /// - Parameter context: The failed attempt.
    /// - Returns: The decision.
    func retry(_ context: RetryContext) async -> RetryDecision
}
