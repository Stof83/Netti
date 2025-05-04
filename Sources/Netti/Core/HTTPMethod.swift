//
//  HTTPMethod.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation

/// Represents HTTP methods for network requests.
public enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
    case head = "HEAD"
    case options = "OPTIONS"
    case trace = "TRACE"
    case connect = "CONNECT"
}
