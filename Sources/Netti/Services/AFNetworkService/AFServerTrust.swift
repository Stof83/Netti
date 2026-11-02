//
//  AFServerTrust.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Alamofire
import Foundation
import Security

// MARK: - PolicyServerTrustManager

/// An Alamofire trust manager that hands every host to a Netti ``ServerTrustPolicy``.
///
/// Alamofire's own manager matches hosts exactly; the policy also matches wildcards and decides
/// unlisted hosts itself, so this manager always returns an evaluator and never lets Alamofire
/// fall back to its own rules. The policy's ``HTTPRequestError`` reaches Alamofire wrapped in
/// `AFError.ServerTrustFailureReason.customEvaluationFailed`, and ``AFNetworkService`` unwraps it.
final class PolicyServerTrustManager: ServerTrustManager, @unchecked Sendable {

    // MARK: - Properties

    let policy: ServerTrustPolicy

    // MARK: - Initialization

    init(policy: ServerTrustPolicy) {
        self.policy = policy
        super.init(allHostsMustBeEvaluated: policy.allHostsMustBeEvaluated, evaluators: [:])
    }

    // MARK: - ServerTrustManager

    override func serverTrustEvaluator(forHost host: String) throws -> (any Alamofire.ServerTrustEvaluating)? {
        PolicyTrustEvaluator(policy: policy)
    }
}

/// An Alamofire evaluator that runs a Netti ``ServerTrustPolicy``.
struct PolicyTrustEvaluator: Alamofire.ServerTrustEvaluating {
    let policy: ServerTrustPolicy

    func evaluate(_ trust: SecTrust, forHost host: String) throws {
        try policy.evaluate(trust, forHost: host)
    }
}

// MARK: - TrustManagerEvaluator

/// A Netti evaluator that runs a 1.x Alamofire `ServerTrustManager`, so WebSockets opened by a
/// legacy-configured ``AFNetworkService`` get the same pinning as its HTTP requests.
struct TrustManagerEvaluator: ServerTrustEvaluating {
    let manager: ServerTrustManager

    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        do {
            guard let evaluator = try manager.serverTrustEvaluator(forHost: host) else {
                try ServerTrustEvaluator.default.evaluate(trust, forHost: host)
                return
            }
            try evaluator.evaluate(trust, forHost: host)
        } catch let error as HTTPRequestError {
            throw error
        } catch {
            throw .serverTrustEvaluationFailed(host: host, reason: error.localizedDescription)
        }
    }
}
