import Alamofire
import Foundation
import Security
import Testing

@testable import Netti

/// Both engines must decide trust identically: the native delegate and the Alamofire trust
/// manager are fed the same fixtures and must agree, down to the error they surface.
@Suite("Engine trust parity")
struct EngineTrustParityTests {
    typealias Fixture = TrustFixtures.Certificate

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let chain: [Fixture]
        let evaluator: ServerTrustEvaluator
        let host: String

        var testDescription: String {
            name
        }
    }

    static let cases = [
        Case(name: "pin match", chain: [.p256], evaluator: .publicKeys([Fixture.p256.expectedPin, Fixture.authority.expectedPin]), host: TrustFixtures.host),
        Case(name: "pin mismatch", chain: [.p256], evaluator: .publicKeys([Fixture.unrelated.expectedPin, Fixture.otherHost.expectedPin]), host: TrustFixtures.host),
        Case(name: "expired", chain: [.expired], evaluator: .publicKeys([Fixture.expired.expectedPin, Fixture.authority.expectedPin]), host: TrustFixtures.host),
        Case(name: "wrong host", chain: [.otherHost], evaluator: .default, host: TrustFixtures.host),
        Case(name: "unlisted host", chain: [.p256], evaluator: .default, host: "unlisted.example.org"),
    ]

    @Test("given the same policy and chain, when evaluated by each engine, then the outcome and error match", arguments: cases)
    @available(*, deprecated, message: "Exercises the deprecated Alamofire engine.")
    func sameOutcomeOnBothEngines(testCase: Case) throws {
        let policy = ServerTrustPolicy([TrustFixtures.host: testCase.evaluator])
        let trust = try TrustFixtures.trust(testCase.chain)
        let request = URLRequest(url: try #require(URL(string: "https://\(testCase.host)/")))

        let nativeOutcome = Self.outcome { () throws(HTTPRequestError) in try policy.evaluate(trust, forHost: testCase.host) }
        let manager = PolicyServerTrustManager(policy: policy)
        let alamofireOutcome = Self.outcome { () throws(HTTPRequestError) in
            do {
                let evaluator = try #require(try manager.serverTrustEvaluator(forHost: testCase.host))
                try evaluator.evaluate(try TrustFixtures.trust(testCase.chain), forHost: testCase.host)
            } catch {
                let wrapped = AFError.serverTrustEvaluationFailed(reason: .customEvaluationFailed(error: error))
                throw AFNetworkService.requestError(wrapped, for: request)
            }
        }

        #expect(nativeOutcome == alamofireOutcome)
    }

    /// `nil` on success, otherwise the failing host and reason.
    static func outcome(_ body: () throws(HTTPRequestError) -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            guard case .serverTrustEvaluationFailed(let host, let reason) = error else {
                return "unexpected: \(error)"
            }
            return "\(host): \(reason)"
        }
    }
}
