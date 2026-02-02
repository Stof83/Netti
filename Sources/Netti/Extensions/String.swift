//
//  String.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/01/26.
//

import CryptoKit
import Foundation

extension String {
    var sha256: String {
        let data = Data(utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
