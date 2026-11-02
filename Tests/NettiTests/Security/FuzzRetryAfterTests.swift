//
//  FuzzRetryAfterTests.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/10/26.
//

import Foundation
import Testing

@testable import Netti

/// Seeded fuzzing of `Retry-After` handling (TM-01): random strings, numbers and HTTP-dates never
/// trap; the policy honours only up to 10 digits or an HTTP-date, treats anything else as absent
/// (exponential backoff), and never waits longer than `maximumRetryAfter`.
@Suite("Fuzz: Retry-After", .timeLimit(.minutes(30)))
struct FuzzRetryAfterTests {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let baseDelay = Duration.milliseconds(1_234)

    // MARK: - Tests

    @Test("given random Retry-After values, when decided, then any requested wait is at most the cap and the rest fall back to backoff")
    func randomValues_respectCap() async {
        await Fuzz.run("retry-after.random") { fuzz in
            let cap = Duration.seconds(fuzz.random.int(0...120))
            let retryCount = fuzz.random.int(0...1)
            let (value, expected) = RetryAfterGenerator.value(using: &fuzz.random, now: Self.now)
            let policy = RetryPolicy(baseDelay: Self.baseDelay, maximumRetryAfter: cap, now: { Self.now }, randomUnit: { 1 })
            let context = makeRetryContext(retryAfter: value, retryCount: retryCount, carriedByError: fuzz.random.chance(0.3))
            fuzz.input = "Retry-After=\(value.debugDescription) cap=\(cap) retryCount=\(retryCount)"

            let decision = await policy.retry(context)
            let backoff = Self.baseDelay * (1 << retryCount)

            switch decision {
                case .doNotRetry:
                    break
                case .retryAfter(let delay) where delay == backoff:
                    break
                case .retryAfter(let delay):
                    fuzz.check(delay <= cap, "waits \(delay), above the cap \(cap)")
                    fuzz.check(delay >= .zero && delay.components.attoseconds == 0, "waits \(delay), not whole non-negative seconds")
                default:
                    fuzz.fail("unexpected decision \(decision)")
            }

            guard let expected else {
                return
            }
            let expectedDecision: RetryDecision = switch expected {
                case .absent:
                    .retryAfter(backoff)
                case .seconds(let seconds):
                    Duration.seconds(seconds) <= cap ? .retryAfter(.seconds(seconds)) : .doNotRetry
            }
            fuzz.check(decision == expectedDecision, "decided \(decision), expected \(expectedDecision)")
        }
    }

    // MARK: - Private Helpers

    private func makeRetryContext(retryAfter: String, retryCount: Int, carriedByError: Bool) -> RetryContext {
        let response = makeResponse(status: 503, headers: ["Retry-After": retryAfter])
        if carriedByError {
            return RetryContext(request: makeURLRequest(), response: nil, error: .unacceptableStatusCode(503, response: response), retryCount: retryCount)
        }
        return RetryContext(request: makeURLRequest(), response: response, error: nil, retryCount: retryCount)
    }
}

// MARK: - RetryAfterGenerator

private enum RetryAfterGenerator {
    /// What the spec makes of a value: absent (backoff), or a wait in whole seconds.
    enum Expectation {
        case absent
        case seconds(Int64)
    }

    /// Values that look numeric but are not 1 to 10 ASCII digits.
    private static let numericLookalikes = [
        "inf", "-inf", "Infinity", "nan", "NaN", "1e308", "1e21", "-1e308", "-0", "+5", "-1", "0x10", "1.5", "0.0",
        "１２", "٣", "۵", "1_000", "1,000", "", " ", "\t", "99999999999", "18446744073709551616", "5s", "5 5",
    ]

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    /// A value and, when the spec fixes the outcome, what it must mean.
    static func value(using random: inout SeededRandom, now: Date) -> (String, Expectation?) {
        switch random.int(0...9) {
            case 0...2:
                let digits = String((0..<random.int(1...12)).map { _ in random.pick(Array("0123456789")) })
                let padded = random.pick(["", " ", "\t", "  "]) + digits + random.pick(["", " ", "\t"])
                return (padded, digits.count <= 10 ? .seconds(Int64(digits) ?? -1) : .absent)
            case 3:
                return (random.pick(numericLookalikes), .absent)
            case 4...5:
                let offset = random.chance(0.6) ? Double(random.int(-120...240)) : Double(random.int(-2_000_000_000...250_000_000_000))
                let date = now.addingTimeInterval(offset)
                let seconds = max(0, Int64(offset))
                return (formatter.string(from: date), .seconds(seconds))
            case 6:
                return (random.pick(["Fri, 31 Dec 9999 23:59:59 GMT", "Mon, 01 Jan 0001 00:00:00 GMT", "Thu, 01 Jan 1970 00:00:00 GMT"]), nil)
            case 7:
                let date = formatter.string(from: now.addingTimeInterval(Double(random.int(-60...60))))
                return (String(decoding: random.mutate(Data(date.utf8)), as: UTF8.self), nil)
            default:
                return (random.string(maximumLength: 40), nil)
        }
    }
}
