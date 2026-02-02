//
//  HTTPCachePolicy.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/01/26.
//

import Foundation

/// A policy describing how an API request should be cached.
public enum HTTPCachePolicy: Sendable {
    /// The request is never cached and has no offline fallback.
    case none
    /// The response is persisted and used only when the device is offline.
    case cache
}
