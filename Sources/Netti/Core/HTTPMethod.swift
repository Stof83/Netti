//
//  HTTPMethod.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation

/// Represents HTTP methods for network requests.
public enum HTTPMethod: String, CaseIterable, Sendable {
    /// `GET`: retrieves a resource. Idempotent; parameters go in the query string.
    case get = "GET"
    /// `POST`: submits data to a resource. Not idempotent; parameters go in the body.
    case post = "POST"
    /// `PUT`: replaces a resource. Idempotent; parameters go in the body.
    case put = "PUT"
    /// `DELETE`: removes a resource. Idempotent; parameters go in the query string.
    case delete = "DELETE"
    /// `PATCH`: partially modifies a resource. Not idempotent; parameters go in the body.
    case patch = "PATCH"
    /// `HEAD`: retrieves only the headers of a resource. Idempotent; parameters go in the query string.
    case head = "HEAD"
    /// `OPTIONS`: asks which methods a resource supports. Idempotent.
    case options = "OPTIONS"
    /// `TRACE`: echoes the request back, for diagnostics. Idempotent.
    case trace = "TRACE"
    /// `CONNECT`: opens a tunnel through a proxy. Not idempotent.
    case connect = "CONNECT"
}

/// Where request parameters are placed by default for a given ``HTTPMethod``.
public enum ParameterDestination: Sendable {
    /// Parameters are percent-encoded into the URL query string.
    case queryString
    /// Parameters are encoded into the HTTP body.
    case httpBody
}

extension HTTPMethod {
    /// Whether repeating the request has the same effect as sending it once (RFC 9110 §9.2.2).
    ///
    /// Only idempotent requests are retried automatically.
    public var isIdempotent: Bool {
        switch self {
            case .get, .head, .put, .delete, .options, .trace:
                true
            case .post, .patch, .connect:
                false
        }
    }

    /// Where parameters go when no explicit destination is given.
    ///
    /// `GET`, `HEAD` and `DELETE` carry parameters in the query string; every other method in the body.
    public var defaultParameterDestination: ParameterDestination {
        switch self {
            case .get, .head, .delete:
                .queryString
            case .post, .put, .patch, .options, .trace, .connect:
                .httpBody
        }
    }
}
