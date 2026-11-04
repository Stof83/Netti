//
//  ClientCertificateFixtureSmokeTests.swift
//  Netti
//

import Foundation
import Security
import Testing

/// Checks the mutual-TLS fixtures with a bare `URLSession`, before any Netti code is involved:
/// the server accepts the identity of its own authority and rejects the unrelated one.
@Suite(
    "Client certificate fixtures",
    .timeLimit(.minutes(1)),
    .enabled(if: RedTeamTLSServer.isAvailable && ClientCertificateFixtures.isAvailable, "needs a loopback TLS identity and openssl")
)
struct ClientCertificateFixtureSmokeTests {

    @Test("given the valid identity, when a client presents it, then the server completes the request and records its certificate")
    func validIdentity_accepted() async throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let server = try await RedTeamTLSServer.start(clientAuthentication: .require(authority: fixtures.trusted.authority))
        defer { server.stop() }

        let status = try await Self.statusCode(of: server.url("/"), identity: fixtures.trusted)

        #expect(status == 200)
        #expect(server.requestCount == 1)
        #expect(server.clientCertificates == [fixtures.trusted.certificate])
    }

    @Test("given an identity from an unrelated authority, when a client presents it, then the server rejects it before any request")
    func unrelatedIdentity_rejected() async throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let server = try await RedTeamTLSServer.start(clientAuthentication: .require(authority: fixtures.trusted.authority))
        defer { server.stop() }

        let status = try? await Self.statusCode(of: server.url("/"), identity: fixtures.untrusted)

        #expect(status == nil)
        #expect(server.requestCount == 0)
        // URLSession reconnects after a rejected handshake, so the certificate can arrive more than once.
        #expect(server.clientCertificates.isEmpty == false)
        #expect(Set(server.clientCertificates) == [fixtures.untrusted.certificate])
    }

    @Test("given no identity, when a client connects to a server that requires one, then the server rejects it before any request")
    func noIdentity_rejected() async throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let server = try await RedTeamTLSServer.start(clientAuthentication: .require(authority: fixtures.trusted.authority))
        defer { server.stop() }

        let status = try? await Self.statusCode(of: server.url("/"), identity: nil)

        #expect(status == nil)
        #expect(server.requestCount == 0)
        #expect(server.clientCertificates.isEmpty)
    }
}

// MARK: - Helpers

private extension ClientCertificateFixtureSmokeTests {
    static func statusCode(of url: URL, identity credential: ClientCertificateFixtures.Credential?) async throws -> Int {
        let delegate = BareDelegate(identity: try credential.map(importIdentity))
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    static func importIdentity(_ credential: ClientCertificateFixtures.Credential) throws -> SecIdentity {
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: ClientCertificateFixtures.passphrase]
        if #available(macOS 15, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        let status = SecPKCS12Import(credential.pkcs12 as CFData, options as CFDictionary, &items)
        let entry = (items as? [[String: Any]])?.first
        guard status == errSecSuccess, let identity = entry?[kSecImportItemIdentity as String] else {
            throw ClientCertificateFixtures.FixtureError.unavailable("SecPKCS12Import failed with OSStatus \(status)")
        }
        // Core Foundation type: the cast always succeeds once the key is present.
        return identity as! SecIdentity
    }

    /// Trusts the self-signed server and answers a client-certificate challenge with `identity`.
    final class BareDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        private let identity: SecIdentity?

        init(identity: SecIdentity?) {
            self.identity = identity
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            switch challenge.protectionSpace.authenticationMethod {
                case NSURLAuthenticationMethodServerTrust:
                    completionHandler(.useCredential, challenge.protectionSpace.serverTrust.map(URLCredential.init(trust:)))
                case NSURLAuthenticationMethodClientCertificate:
                    guard let identity else {
                        completionHandler(.performDefaultHandling, nil)
                        return
                    }
                    completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .none))
                default:
                    completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}
