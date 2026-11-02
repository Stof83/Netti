//
//  AFConfiguration.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Alamofire
import Foundation

/// A configuration structure for the `AFNetworkService` class.
///
/// - Important: Deprecated since 2.0. Only `serverTrustManager` is still read; ``Netti`` now owns
///   parameter encoding and caching. Replace it with a ``ServerTrustPolicy`` passed to
///   ``URLSessionNetworkService/init(configuration:trustPolicy:redirectHandler:maxConnectionsPerHost:maximumResponseSize:maximumRequestDuration:)``,
///   and opt endpoints into caching with ``HTTPRequest/cachePolicy``.
@available(*, deprecated, message: "Use AFNetworkService(configuration:trustPolicy:) with a ServerTrustPolicy; encoding and caching moved to Netti.")
public struct AFConfiguration {
    /// The server trust manager responsible for handling server trust evaluations.
    let serverTrustManager: ServerTrustManager?
    
    /// The response caching mechanism used by the network service.
    let cacheResponse: ResponseCacher
    
    /// The encoding used for URL-based requests (e.g., GET).
    let urlEncoding: URLEncoding
    
    /// The encoding used for JSON-based requests (e.g., POST, PUT).
    let jsonEncoding: JSONEncoding
    
    /// Initializes a new instance of `AFConfiguration`.
    ///
    /// - Parameters:
    ///   - serverTrustManager: The `ServerTrustManager` used for SSL pinning and server trust evaluations.
    ///   - cacheResponse: The `ResponseCacher` used for caching responses. Defaults to `.doNotCache`. Ignored.
    ///   - urlEncoding: The parameter encoding used for URL-based requests. Defaults to `URLEncoding.init(arrayEncoding: .noBrackets, boolEncoding: .literal)`. Ignored.
    ///   - jsonEncoding: The parameter encoding used for JSON-based requests. Defaults to `JSONEncoding.default`. Ignored.
    public init(
        serverTrustManager: ServerTrustManager? = nil,
        cacheResponse: ResponseCacher = .doNotCache,
        urlEncoding: URLEncoding = URLEncoding.init(arrayEncoding: .noBrackets, boolEncoding: .literal),
        jsonEncoding: JSONEncoding = JSONEncoding.default
    ) {
        self.serverTrustManager = serverTrustManager
        self.cacheResponse = cacheResponse
        self.urlEncoding = urlEncoding
        self.jsonEncoding = jsonEncoding
    }
}
