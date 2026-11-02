import Foundation
import Testing

@testable import Netti

@Suite("RetryPolicy")
struct RetryPolicyTests {
    /// No jitter: the full ceiling, so delays are exact.
    private let policy = RetryPolicy(randomUnit: { 1 })

    @Test("given the defaults, when read, then they match the design")
    func defaults() {
        #expect(policy.maxRetries == 2)
        #expect(policy.baseDelay == .milliseconds(500))
        #expect(policy.retryableStatusCodes == [408, 429, 500, 502, 503, 504])
        #expect(policy.retryableMethods.contains(.post) == false)
        #expect(policy.retryableMethods.contains(.get))
    }

    @Test("given a retryable status on a GET, when decided, then it retries")
    func retry_retryableStatus_retries() async {
        for status in [408, 429, 500, 502, 503, 504] {
            let decision = await policy.retry(makeContext(status: status))
            #expect(decision == .retryAfter(.milliseconds(500)), "status \(status)")
        }
    }

    @Test("given a status that is not retryable, when decided, then it does not retry", arguments: [200, 301, 400, 401, 404, 501])
    func retry_otherStatus_doesNotRetry(status: Int) async {
        #expect(await policy.retry(makeContext(status: status)) == .doNotRetry)
    }

    @Test("given a POST failing with 503, when decided under the default policy, then it is not retried")
    func retry_postIsNotRetried() async {
        #expect(await policy.retry(makeContext(method: "POST", status: 503)) == .doNotRetry)
    }

    @Test("given a PATCH and a PUT failing with 503, when decided, then only the idempotent one retries")
    func retry_onlyIdempotentMethods() async {
        #expect(await policy.retry(makeContext(method: "PATCH", status: 503)) == .doNotRetry)
        #expect(await policy.retry(makeContext(method: "PUT", status: 503)) != .doNotRetry)
    }

    @Test("given methods widened to POST, when a POST fails, then it retries")
    func retry_customMethods_allowsPost() async {
        let custom = RetryPolicy(retryableMethods: [.get, .post], randomUnit: { 1 })

        #expect(await custom.retry(makeContext(method: "POST", status: 503)) != .doNotRetry)
    }

    @Test("given a transient connection error, when decided, then it retries")
    func retry_transientURLError_retries() async {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed] {
            let context = makeContext(error: .requestFailed(URLError(code)))
            #expect(await policy.retry(context) != .doNotRetry, "code \(code.rawValue)")
        }
    }

    @Test("given a connection error that is not transient, when decided, then it does not retry")
    func retry_permanentURLError_doesNotRetry() async {
        for code in [URLError.Code.badURL, .unsupportedURL, .serverCertificateUntrusted, .userAuthenticationRequired] {
            let context = makeContext(error: .requestFailed(URLError(code)))
            #expect(await policy.retry(context) == .doNotRetry, "code \(code.rawValue)")
        }
    }

    @Test("given cancellation, a trust failure or an encoding failure, when decided, then it does not retry")
    func retry_nonTransientErrors_doNotRetry() async {
        let errors: [HTTPRequestError] = [
            .cancelled,
            .serverTrustEvaluationFailed(host: "api.test", reason: "pin"),
            .encodingFailed(CocoaError(.coderInvalidValue)),
            .invalidURL,
        ]
        for error in errors {
            #expect(await policy.retry(makeContext(error: error)) == .doNotRetry)
        }
    }

    @Test("given a retryable status carried by a thrown error, when decided, then it retries")
    func retry_statusInError_retries() async {
        let error = HTTPRequestError.unacceptableStatusCode(503, response: makeResponse(status: 503))

        #expect(await policy.retry(makeContext(error: error)) != .doNotRetry)
    }

    // MARK: - Backoff

    @Test("given consecutive failures, when decided, then the ceiling doubles each time")
    func retry_backoff_doubles() async {
        let long = RetryPolicy(maxRetries: 5, baseDelay: .milliseconds(100), randomUnit: { 1 })
        var delays: [Duration] = []
        for retryCount in 0..<4 {
            if case .retryAfter(let delay) = await long.retry(makeContext(status: 503, retryCount: retryCount)) {
                delays.append(delay)
            }
        }

        #expect(delays == [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800)])
    }

    @Test("given jitter, when decided, then the delay is a fraction of the ceiling")
    func retry_jitter_scalesDelay() async {
        let jittered = RetryPolicy(baseDelay: .seconds(1), randomUnit: { 0.25 })

        #expect(await jittered.retry(makeContext(status: 503)) == .retryAfter(.milliseconds(250)))
        #expect(await jittered.retry(makeContext(status: 503, retryCount: 1)) == .retryAfter(.milliseconds(500)))
    }

    @Test("given the real random source, when decided many times, then the delay stays within the ceiling")
    func retry_realJitter_staysWithinCeiling() async {
        let real = RetryPolicy(baseDelay: .seconds(1))

        for _ in 0..<50 {
            guard case .retryAfter(let delay) = await real.retry(makeContext(status: 503, retryCount: 1)) else {
                Issue.record("Expected a retry")
                return
            }
            #expect(delay >= .zero && delay <= .seconds(2))
        }
    }

    // MARK: - Limit

    @Test("given a GET failing three times, when decided after the second retry, then the limit is exceeded")
    func retry_limit_exceeded() async {
        #expect(await policy.retry(makeContext(status: 503, retryCount: 0)) != .retryLimitExceeded)
        #expect(await policy.retry(makeContext(status: 503, retryCount: 1)) != .retryLimitExceeded)
        #expect(await policy.retry(makeContext(status: 503, retryCount: 2)) == .retryLimitExceeded)
    }

    @Test("given a failure that is not retryable, when the limit is reached, then it is not reported as exceeded")
    func retry_limit_onlyForRetryableFailures() async {
        #expect(await policy.retry(makeContext(status: 404, retryCount: 2)) == .doNotRetry)
    }

    @Test("given the disabled policy, when a retryable failure occurs, then it neither retries nor reports a limit")
    func retry_disabled_doesNothing() async {
        #expect(await RetryPolicy.disabled.retry(makeContext(status: 503)) == .doNotRetry)
    }

    // MARK: - Retry-After

    @Test("given Retry-After in seconds, when decided, then the delay is honoured exactly")
    func retry_retryAfterSeconds_isHonoured() async {
        let context = makeContext(status: 429, headers: ["Retry-After": "2"])

        #expect(await policy.retry(context) == .retryAfter(.seconds(2)))
    }

    @Test("given Retry-After as an HTTP date, when decided, then the delay is the time until that date")
    func retry_retryAfterDate_isHonoured() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dated = RetryPolicy(now: { now }, randomUnit: { 1 })
        let target = Date(timeIntervalSince1970: 1_700_000_030)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let context = makeContext(status: 503, headers: ["Retry-After": formatter.string(from: target)])

        #expect(await dated.retry(context) == .retryAfter(.seconds(30)))
    }

    @Test("given Retry-After in the past, when decided, then the retry is immediate")
    func retry_retryAfterInThePast_isImmediate() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dated = RetryPolicy(now: { now }, randomUnit: { 1 })
        let context = makeContext(status: 503, headers: ["Retry-After": "Wed, 01 Jan 2020 00:00:00 GMT"])

        #expect(await dated.retry(context) == .retryAfter(.zero))
    }

    @Test("given an unreadable Retry-After, when decided, then backoff applies")
    func retry_retryAfterGarbage_fallsBackToBackoff() async {
        let context = makeContext(status: 503, headers: ["Retry-After": "soon"])

        #expect(await policy.retry(context) == .retryAfter(.milliseconds(500)))
    }

    @Test("given Retry-After on a thrown status error, when decided, then it is honoured")
    func retry_retryAfterInError_isHonoured() async {
        let error = HTTPRequestError.unacceptableStatusCode(429, response: makeResponse(status: 429, headers: ["Retry-After": "3"]))

        #expect(await policy.retry(makeContext(error: error)) == .retryAfter(.seconds(3)))
    }

    // MARK: - Hostile Retry-After

    @Test(
        "given a Retry-After that is not 1 to 10 digits, when decided, then it is ignored and backoff applies",
        arguments: ["inf", "-inf", "nan", "NaN", "1e21", "1e308", "-1", "-0", "99999999999", "1.5", "+5", " 0x10", "5 5", "٣"]
    )
    func retry_retryAfterHostile_fallsBackToBackoff(value: String) async {
        let context = makeContext(status: 503, headers: ["Retry-After": value])

        #expect(await policy.retry(context) == .retryAfter(.milliseconds(500)))
    }

    @Test("given a Retry-After above the cap, when decided, then the request is not retried", arguments: ["86400", "61", "9999999999"])
    func retry_retryAfterAboveCap_doesNotRetry(value: String) async {
        let context = makeContext(status: 503, headers: ["Retry-After": value])

        #expect(await policy.retry(context) == .doNotRetry)
    }

    @Test("given a Retry-After exactly at the cap, when decided, then it is honoured")
    func retry_retryAfterAtCap_isHonoured() async {
        let context = makeContext(status: 503, headers: ["Retry-After": "60"])

        #expect(await policy.retry(context) == .retryAfter(.seconds(60)))
    }

    @Test("given an HTTP-date far in the future, when decided, then the request is not retried")
    func retry_retryAfterDateFarAway_doesNotRetry() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dated = RetryPolicy(now: { now }, randomUnit: { 1 })
        let context = makeContext(status: 503, headers: ["Retry-After": "Fri, 31 Dec 9999 23:59:59 GMT"])

        #expect(await dated.retry(context) == .doNotRetry)
    }

    @Test("given a custom cap, when the wait exceeds it, then the request is not retried")
    func retry_customCap_isApplied() async {
        let strict = RetryPolicy(maximumRetryAfter: .seconds(5), randomUnit: { 1 })

        #expect(strict.maximumRetryAfter == .seconds(5))
        #expect(await strict.retry(makeContext(status: 503, headers: ["Retry-After": "6"])) == .doNotRetry)
        #expect(await strict.retry(makeContext(status: 503, headers: ["Retry-After": "5"])) == .retryAfter(.seconds(5)))
    }

    @Test("given the default policy, when read, then the Retry-After cap is 60 seconds")
    func defaults_maximumRetryAfter() {
        #expect(RetryPolicy().maximumRetryAfter == .seconds(60))
    }
}
