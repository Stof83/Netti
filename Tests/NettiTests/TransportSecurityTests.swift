import Foundation
import Testing

@testable import Netti

/// TM-06: both engines negotiate TLS 1.2 or later. The URLSession engine leaves the caller's resource
/// timeout untouched and bounds data and upload requests with `maximumRequestDuration` instead
/// (slow-loris).
@Suite("Transport security")
struct TransportSecurityTests {

    @Test("given the default configuration, when the URLSession engine is created, then its TLS minimum is 1.2")
    func urlSession_default_tls12() {
        let service = URLSessionNetworkService()

        #expect(service.sessionConfiguration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    @Test("given a configuration below TLS 1.2, when the URLSession engine is created, then it is raised without touching the caller's copy")
    func urlSession_lowerFloor_raised() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv10

        let service = URLSessionNetworkService(configuration: configuration)

        #expect(service.sessionConfiguration.tlsMinimumSupportedProtocolVersion == .TLSv12)
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv10)
    }

    @Test("given a configuration requiring TLS 1.3, when the URLSession engine is created, then TLS 1.3 is kept")
    func urlSession_tls13_kept() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13

        let service = URLSessionNetworkService(configuration: configuration)

        #expect(service.sessionConfiguration.tlsMinimumSupportedProtocolVersion == .TLSv13)
    }

    @Test("given the default configuration, when the Alamofire engine is created, then its TLS minimum is 1.2")
    func alamofire_default_tls12() {
        let service = AFNetworkService()

        #expect(service.sessionConfiguration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    @Test("given a configuration requiring TLS 1.3, when the Alamofire engine is created, then TLS 1.3 is kept")
    func alamofire_tls13_kept() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13

        let service = AFNetworkService(configuration: configuration)

        #expect(service.sessionConfiguration.tlsMinimumSupportedProtocolVersion == .TLSv13)
    }

    @Test("given the deprecated 1.x configuration, when the Alamofire engine is created, then its TLS minimum is 1.2")
    @available(*, deprecated)
    func alamofire_legacy_tls12() {
        let service = AFNetworkService(configuration: AFConfiguration())

        #expect(service.sessionConfiguration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    // MARK: - Resource Timeout

    @Test("given the default configuration, when the URLSession engine is created, then its resource timeout is left at URLSession's default")
    func urlSession_default_resourceTimeoutUntouched() {
        let service = URLSessionNetworkService()

        #expect(service.sessionConfiguration.timeoutIntervalForResource == 604_800)
        #expect(service.sessionConfiguration.timeoutIntervalForResource == URLSessionConfiguration.default.timeoutIntervalForResource)
    }

    @Test("given the public initializer, when no duration is given, then data and upload requests are bounded at 300 seconds")
    func urlSession_default_maximumRequestDuration300() {
        #expect(URLSessionNetworkService().maximumRequestDuration == .seconds(300))
        #expect(URLSessionNetworkService(maximumRequestDuration: nil).maximumRequestDuration == nil)
    }

    @Test("given a caller-set resource timeout, when the URLSession engine is created, then it is kept")
    func urlSession_callerResourceTimeout_kept() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 3_600

        let service = URLSessionNetworkService(configuration: configuration)

        #expect(service.sessionConfiguration.timeoutIntervalForResource == 3_600)
    }

    @Test("given a caller-set timeoutIntervalForResource and a server that drips a body faster than the request timeout, when the resource timeout passes, then the request fails with timedOut")
    func urlSession_callerResourceTimeout_slowLoris_timesOut() async throws {
        let body = LocalHTTPServer.Response.chaosBody
        let head = LocalHTTPServer.Response.rawHead([("Content-Length", "\(body.count)"), ("Connection", "close")])
        let server = try await LocalHTTPServer.start { _ in
            .script(.send(head), .drip(body, count: 1, interval: .milliseconds(50)))
        }
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 1
        let service = URLSessionNetworkService(configuration: configuration)
        let request = URLRequest(url: server.url("/drip"))

        let code = try #require(await withinBound(.seconds(5)) { () -> URLError.Code? in
            do throws(HTTPRequestError) {
                let response = try await service.data(for: request)
                return (response.error as? HTTPRequestError)?.urlErrorCode ?? (response.error as? URLError)?.code
            } catch {
                return error.urlErrorCode
            }
        })

        #expect(code == .timedOut)
    }
}
