//
//  PendingRequest.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/01/26.
//

/// A value object representing a request deferred due to offline state.
struct PendingRequest {
    let request: HTTPRequest
    let parameters: [String: any Any & Sendable]?
    let method: HTTPMethod
}

