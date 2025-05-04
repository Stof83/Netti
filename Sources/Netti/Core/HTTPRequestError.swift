//
//  NetworkError.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 03/05/25.
//

import Foundation

/// Errors that can occur during a network request lifecycle.
public enum HTTPRequestError: Error {
    case invalidURL
    case requestFailed(Error)
    case invalidResponse
    case decodingFailed(Error)
    case statusCode(Int)
}
