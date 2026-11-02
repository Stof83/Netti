//
//  ServerTrustEvaluating.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import Foundation
import Security

/// Decides whether a server's TLS trust is accepted for a host.
///
/// Conform to it to plug a custom check into a ``ServerTrustPolicy`` through
/// ``ServerTrustEvaluator/custom(_:)``. Built-in evaluators are the static members of
/// ``ServerTrustEvaluator``, which a custom evaluator can also call to reuse default validation:
///
/// ```swift
/// struct TeamIdentifierEvaluator: ServerTrustEvaluating {
///     func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
///         try ServerTrustEvaluator.default.evaluate(trust, forHost: host)
///         // extra checks…
///     }
/// }
/// ```
///
/// Evaluation is synchronous and may block while the system validates the chain, so engines call it
/// off the main actor.
public protocol ServerTrustEvaluating: Sendable {
    /// Evaluates `trust` for `host`, returning normally only when the host is trusted.
    ///
    /// - Parameters:
    ///   - trust: The server trust from the TLS challenge. Evaluators may replace its policies.
    ///   - host: The host being connected to.
    /// - Throws: ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)`` when the host is rejected.
    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError)
}
