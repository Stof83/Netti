//
//  String.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 29/01/26.
//

import Foundation

extension String {
    var sha256: String {
        Data(utf8).sha256
    }
}
