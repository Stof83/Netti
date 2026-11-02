import Foundation
import Testing

@testable import Netti

@Suite("HTTPMethod")
struct HTTPMethodTests {
    @Test(
        "given a method, when isIdempotent is read, then it follows RFC 9110",
        arguments: [
            (HTTPMethod.get, true), (.head, true), (.put, true), (.delete, true), (.options, true), (.trace, true),
            (.post, false), (.patch, false), (.connect, false),
        ]
    )
    func isIdempotent(method: HTTPMethod, expected: Bool) {
        #expect(method.isIdempotent == expected)
    }

    @Test(
        "given a method, when the default destination is read, then GET, HEAD and DELETE use the query",
        arguments: HTTPMethod.allCases
    )
    func defaultParameterDestination(method: HTTPMethod) {
        let expected: ParameterDestination = [.get, .head, .delete].contains(method) ? .queryString : .httpBody

        #expect(method.defaultParameterDestination == expected)
    }

    @Test("given every method, when the raw value is read, then it is the uppercase verb", arguments: HTTPMethod.allCases)
    func rawValue_isUppercaseVerb(method: HTTPMethod) {
        #expect(method.rawValue == "\(method)".uppercased())
    }
}
