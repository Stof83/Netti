//
//  URLRequest.Swift
//  Netti
//
//  Created by El Mostafa El Ouatri on 06/05/25.
//

import Foundation

extension URLRequest {
    public func asCurl() -> String {
        guard let url else { return "" }
        
        var components = ["curl -v"]
        components.append("-X \(httpMethod ?? "GET")")

        for (header, value) in allHTTPHeaderFields ?? [:] {
            components.append("-H \"\(header): \(value)\"")
        }

        if let body = httpBody,
           let bodyString = String(data: body, encoding: .utf8) {
            components.append("-d '\(bodyString)'")
        }

        components.append("\"\(url.absoluteString)\"")
        return components.joined(separator: " \\\n\t")
    }
}
