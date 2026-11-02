import Foundation
import Testing

@testable import Netti
import NettiTesting

@Suite("Netti typed responses", .timeLimit(.minutes(1)))
struct NettiTypedVerbTests {

    private let widget = Widget(id: 9, name: "typed")

    private func makeClient() -> (Netti, StubNetworkService) {
        let service = StubNetworkService { [widget] in try .json(for: $0, widget) }
        return (makeNetti(service: service), service)
    }

    @Test("given a POST with a typed response, when sent, then the body is decoded and sent as JSON")
    func post_decodesResponse() async throws {
        let (netti, service) = makeClient()

        let response: HTTPResponse<Widget> = try await netti.post(TestEndpoint(), body: Widget(id: 1, name: "in"))

        #expect(response.data == widget)
        #expect(service.requests.first?.httpMethod == "POST")
        #expect(service.requests.first?.httpBody != nil)
    }

    @Test("given a PUT with a typed response, when sent, then the body is decoded")
    func put_decodesResponse() async throws {
        let (netti, service) = makeClient()

        let response: HTTPResponse<Widget> = try await netti.put(TestEndpoint(), body: Widget(id: 1, name: "in"))

        #expect(response.data == widget)
        #expect(service.requests.first?.httpMethod == "PUT")
    }

    @Test("given a PATCH with a typed response, when sent, then the body is decoded")
    func patch_decodesResponse() async throws {
        let (netti, service) = makeClient()

        let response: HTTPResponse<Widget> = try await netti.patch(TestEndpoint(), body: Widget(id: 1, name: "in"))

        #expect(response.data == widget)
        #expect(service.requests.first?.httpMethod == "PATCH")
    }

    @Test("given a DELETE with a typed response, when sent, then the body is decoded")
    func delete_decodesResponse() async throws {
        let (netti, service) = makeClient()

        let response: HTTPResponse<Widget> = try await netti.delete(TestEndpoint())

        #expect(response.data == widget)
        #expect(service.requests.first?.httpMethod == "DELETE")
    }

    @Test("given an OPTIONS with a typed response, when sent, then the body is decoded")
    func options_decodesResponse() async throws {
        let (netti, service) = makeClient()

        let response: HTTPResponse<Widget> = try await netti.options(TestEndpoint())

        #expect(response.data == widget)
        #expect(service.requests.first?.httpMethod == "OPTIONS")
    }
}
