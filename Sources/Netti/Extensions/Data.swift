//
//  Data.swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 06/05/25.
//

import Foundation

extension Data {
    public func prettyPrinted() -> String {
        do {
            let jsonObject = try JSONSerialization.jsonObject(with: self, options: [])
            let prettyData = try JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted)
            return String(data: prettyData, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
