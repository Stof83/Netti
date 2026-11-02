//
//  Data.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 27/10/26.
//

import CryptoKit
import Foundation

extension Data {
    /// The lowercase hexadecimal SHA-256 digest.
    var sha256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
