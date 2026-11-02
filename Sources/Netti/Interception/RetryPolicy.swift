//
//  RetryPolicy.swift
//  Netti
//

import Foundation

/// Retries transient failures with exponential backoff.
///
/// By default a request is retried at most twice, only when its method is idempotent or it carries
/// an `Idempotency-Key` header (see ``IdempotencyKeyAdapter``), and only
/// after a transient connection error or a `408`, `429`, `500`, `502`, `503` or `504` status.
/// The delay before retry *n* (from 0) is a random value between zero and
/// `baseDelay × 2ⁿ` (full jitter), unless the response carries a `Retry-After` header.
///
/// `Retry-After` is honoured when it is 1 to 10 decimal digits or an HTTP-date; any other value is
/// ignored and the backoff applies. When it asks for a wait longer than ``maximumRetryAfter``,
/// 60 seconds by default, the request is not retried and its response is returned.
///
/// ```swift
/// let netti = Netti()
/// netti.retryPolicy = RetryPolicy(maxRetries: 4, baseDelay: .seconds(1))
/// ```
///
/// An endpoint can override the client's policy through ``HTTPRequest/retryPolicy``, or opt out
/// with ``disabled``.
public struct RetryPolicy: RequestRetrier {
    /// Statuses retried by default.
    public static let defaultStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    /// Connection errors retried by default.
    public static let defaultURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]

    /// A policy that never retries; use it on an endpoint to opt out of the client's policy.
    public static let disabled = RetryPolicy(maxRetries: 0)

    /// The most retries after the first attempt.
    public let maxRetries: Int

    /// The backoff before the first retry, doubled for each one after.
    public let baseDelay: Duration

    /// The methods that may be retried; idempotent methods only unless changed.
    public let retryableMethods: Set<HTTPMethod>

    /// The statuses that are retried.
    public let retryableStatusCodes: Set<Int>

    /// The connection errors that are retried.
    public let retryableURLErrorCodes: Set<URLError.Code>

    /// The longest `Retry-After` wait honoured; a longer one stops the retries. 60 seconds by default.
    ///
    /// A server, or anyone in the path, can otherwise park a request for as long as it asks.
    public let maximumRetryAfter: Duration

    private let now: @Sendable () -> Date
    private let randomUnit: @Sendable () -> Double

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - maxRetries: The most retries after the first attempt.
    ///   - baseDelay: The backoff before the first retry.
    ///   - retryableMethods: The methods that may be retried.
    ///   - retryableStatusCodes: The statuses that are retried.
    ///   - retryableURLErrorCodes: The connection errors that are retried.
    ///   - maximumRetryAfter: The longest `Retry-After` wait honoured; a longer one is not retried.
    ///   - now: The clock used to read an HTTP-date `Retry-After`; injected by tests.
    ///   - randomUnit: A random value in `0...1` for the jitter; injected by tests.
    public init(
        maxRetries: Int = 2,
        baseDelay: Duration = .milliseconds(500),
        retryableMethods: Set<HTTPMethod> = Set(HTTPMethod.allCases.filter(\.isIdempotent)),
        retryableStatusCodes: Set<Int> = RetryPolicy.defaultStatusCodes,
        retryableURLErrorCodes: Set<URLError.Code> = RetryPolicy.defaultURLErrorCodes,
        maximumRetryAfter: Duration = .seconds(60),
        now: @escaping @Sendable () -> Date = { Date() },
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = baseDelay
        self.retryableMethods = retryableMethods
        self.retryableStatusCodes = retryableStatusCodes
        self.retryableURLErrorCodes = retryableURLErrorCodes
        self.maximumRetryAfter = max(.zero, maximumRetryAfter)
        self.now = now
        self.randomUnit = randomUnit
    }

    /// Asynchronously decides whether a failed attempt is retried, and after which delay.
    ///
    /// - Parameter context: The failed attempt.
    /// - Returns: ``RetryDecision/retryAfter(_:)`` with the `Retry-After` delay or a jittered
    ///   backoff; ``RetryDecision/retryLimitExceeded`` once `maxRetries` retries are spent;
    ///   ``RetryDecision/doNotRetry`` when the method, status or error is not retryable, or when
    ///   `Retry-After` asks for more than ``maximumRetryAfter``.
    public func retry(_ context: RetryContext) async -> RetryDecision {
        guard isRetryableMethod(context), isRetryable(context) else {
            return .doNotRetry
        }
        guard context.retryCount < maxRetries else {
            return context.retryCount > 0 ? .retryLimitExceeded : .doNotRetry
        }
        if let seconds = retryAfterSeconds(in: context.response?.response ?? context.error?.response?.response) {
            guard Duration.seconds(seconds) <= maximumRetryAfter else {
                return .doNotRetry
            }
            return .retryAfter(.seconds(seconds))
        }
        let ceiling = baseDelay * Double(1 << min(context.retryCount, 30))
        return .retryAfter(ceiling * min(max(randomUnit(), 0), 1))
    }

    /// A request carrying an `Idempotency-Key` is safe to repeat whatever its method.
    private func isRetryableMethod(_ context: RetryContext) -> Bool {
        if let method = context.method, retryableMethods.contains(method) {
            return true
        }
        return context.request.value(forHTTPHeaderField: IdempotencyKeyAdapter.headerName) != nil
    }

    private func isRetryable(_ context: RetryContext) -> Bool {
        if let status = context.statusCode, retryableStatusCodes.contains(status) {
            return true
        }
        if case .requestFailed(let urlError) = context.error {
            return retryableURLErrorCodes.contains(urlError.code)
        }
        return false
    }

    /// Reads `Retry-After` in whole seconds, as 1 to 10 ASCII digits or as an HTTP-date.
    ///
    /// Any other value is treated as absent. At most 10 digits keeps the result finite and far below
    /// the range `Duration` can hold, so building one from it cannot trap.
    private func retryAfterSeconds(in response: HTTPURLResponse?) -> Int64? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        if (1...10).contains(value.utf8.count), value.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) {
            return Int64(value)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else {
            return nil
        }
        let interval = date.timeIntervalSince(now()).rounded(.up)
        guard interval.isFinite else {
            return nil
        }
        // Clamped to just past any sane cap, so a date in year 9999 still converts safely.
        return Int64(min(max(0, interval), 10_000_000_000))
    }
}
