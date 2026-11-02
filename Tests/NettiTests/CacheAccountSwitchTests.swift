import Foundation
import os
import Testing

@testable import Netti
import NettiTesting

/// TM-11: the response cache key is computed before interceptors add credentials, so it does not
/// separate users. This suite documents current behaviour: after an account switch, user B is
/// served user A's offline entry until `clearCache()` runs, which is why the docs require calling
/// `clearCache()` on logout. It is an expected-pass test; if the key ever includes credentials, update it.
@Suite("Cache account switch", .timeLimit(.minutes(1)))
struct CacheAccountSwitchTests {

    @Test("given user A's response cached, when user B requests the same URL offline without clearCache, then A's entry is served; after clearCache it is not")
    func accountSwitch_servesPreviousUserUntilCleared() async throws {
        let token = OSAllocatedUnfairLock(initialState: "user-a")
        let connectivity = StubConnectivity(.connected)
        let service = StubNetworkService { request in
            if connectivity.currentStatus == .disconnected {
                throw URLError(.notConnectedToInternet)
            }
            let user = request.value(forHTTPHeaderField: "Authorization") ?? "anonymous"
            return try .json(for: request, Widget(id: 1, name: user))
        }
        let authenticate = ClosureAdapter { request in
            var request = request
            request.setValue(token.withLock { $0 }, forHTTPHeaderField: "Authorization")
            return request
        }
        let netti = makeNetti(service: service, interceptors: [authenticate], connectivity: connectivity)
        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cache(maxAge: .seconds(600))

        let userA: HTTPResponse<Widget> = try await netti.get(endpoint)
        token.withLock { $0 = "user-b" }
        connectivity.set(.disconnected)
        let servedToB: HTTPResponse<Widget> = try await netti.get(endpoint)

        #expect(userA.data?.name == "user-a")
        #expect(servedToB.data?.name == "user-a", "TM-11: user B is served user A's entry until clearCache()")

        try await netti.clearCache()
        let error = await expectRequestError { () async throws(HTTPRequestError) -> HTTPResponse<Widget> in
            try await netti.get(endpoint)
        }

        #expect(error != nil)
    }
}
