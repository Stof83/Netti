//
//  ClientCertificateTests.swift
//  Netti
//

import Foundation
import Network
import os
import Security
import Testing

@testable import Netti
import NettiTesting

// MARK: - Creation

/// `ClientIdentity` creation and the secrecy of what it holds (client-certificate-auth spec).
@Suite("Client identity", .enabled(if: ClientCertificateFixtures.isAvailable, "needs openssl"))
struct ClientIdentityTests {

    @Test("given a valid PKCS#12 file and its passphrase, when an identity is created, then creation succeeds")
    func validIdentity_created() throws {
        let fixtures = try ClientCertificateFixtures.shared.get()

        _ = try ClientIdentity(pkcs12: fixtures.trusted.pkcs12, passphrase: ClientCertificateFixtures.passphrase)
    }

    @Test("given the wrong passphrase, when an identity is created, then it throws encodingFailed and no description holds the passphrase")
    func wrongPassphrase_throwsWithoutLeaking() throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let passphrase = "hunter2-wrong-passphrase"

        let error = Self.creationError(pkcs12: fixtures.trusted.pkcs12, passphrase: passphrase)

        #expect(error?.isEncodingFailure == true, "\(String(describing: error))")
        for text in Self.descriptions(of: error) {
            #expect(text.contains(passphrase) == false, "\(text)")
            #expect(text.contains(fixtures.trusted.pkcs12.base64EncodedString().prefix(32)) == false, "\(text)")
        }
    }

    @Test("given bytes that are not PKCS#12, when an identity is created, then it throws encodingFailed")
    func notPKCS12_throws() {
        let passphrase = "hunter2-garbage-passphrase"

        let error = Self.creationError(pkcs12: Data("not a pkcs12 file".utf8), passphrase: passphrase)

        #expect(error?.isEncodingFailure == true, "\(String(describing: error))")
        for text in Self.descriptions(of: error) {
            #expect(text.contains(passphrase) == false, "\(text)")
        }
    }

    @Test("given empty data, when an identity is created, then it throws encodingFailed")
    func emptyData_throws() {
        #expect(Self.creationError(pkcs12: Data(), passphrase: "x")?.isEncodingFailure == true)
    }

    @Test("given an identity, when it is converted to a string or dumped, then the output holds no passphrase and no key material")
    func printing_neverExposesSecrets() throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let identity = try ClientIdentity(pkcs12: fixtures.trusted.pkcs12, passphrase: ClientCertificateFixtures.passphrase)
        var dumped = ""
        dump(identity, to: &dumped)

        let outputs = [String(describing: identity), String(reflecting: identity), "\(identity)", dumped]

        for output in outputs {
            #expect(output.contains(ClientCertificateFixtures.passphrase) == false, "\(output)")
            #expect(output.contains(fixtures.trusted.pkcs12.base64EncodedString().prefix(32)) == false, "\(output)")
            #expect(output.contains("SecIdentity") == false, "\(output)")
            #expect(output.contains("SecKey") == false, "\(output)")
        }
        #expect(String(describing: identity) == "ClientIdentity(redacted)")
    }

    // MARK: - Helpers

    private static func creationError(pkcs12: Data, passphrase: String) -> HTTPRequestError? {
        do {
            _ = try ClientIdentity(pkcs12: pkcs12, passphrase: passphrase)
            return nil
        } catch {
            return error
        }
    }

    /// Every way an error can be turned into text.
    private static func descriptions(of error: HTTPRequestError?) -> [String] {
        guard let error else {
            return []
        }
        var dumped = ""
        dump(error, to: &dumped)
        return [String(describing: error), String(reflecting: error), error.localizedDescription, dumped]
    }
}

// MARK: - Challenges

/// How `SessionDelegate` answers a client-certificate challenge, without a network.
@Suite("Client certificate challenges", .enabled(if: ClientCertificateFixtures.isAvailable, "needs openssl"))
struct ClientCertificateChallengeTests {

    @Test("given an identity, when the server asks for a client certificate, then the delegate answers with that identity and no persistence")
    func clientCertificateChallenge_usesIdentity() throws {
        let delegate = SessionDelegate(trustEvaluator: nil, clientIdentity: try Self.identity())

        let (disposition, credential) = Self.answer(delegate, method: NSURLAuthenticationMethodClientCertificate)

        #expect(disposition == .useCredential)
        #expect(credential?.identity != nil)
        #expect(credential?.persistence == URLCredential.Persistence.none)
    }

    @Test(
        "given an identity, when the server asks for anything but a client certificate, then the identity is not offered",
        arguments: [
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate,
            NSURLAuthenticationMethodDefault,
        ]
    )
    func otherChallenge_identityNotOffered(method: String) throws {
        let delegate = SessionDelegate(trustEvaluator: nil, clientIdentity: try Self.identity())

        let (disposition, credential) = Self.answer(delegate, method: method)

        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test("given an identity the server already refused, when the server asks again, then the challenge is cancelled and the identity is not offered twice")
    func repeatedChallenge_failsClosed() throws {
        let delegate = SessionDelegate(trustEvaluator: nil, clientIdentity: try Self.identity())

        let (disposition, credential) = Self.answer(delegate, method: NSURLAuthenticationMethodClientCertificate, previousFailureCount: 1)

        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
    }

    @Test("given no identity, when the server asks for a client certificate, then the delegate performs default handling as in Netti 3.0")
    func noIdentity_defaultHandling() {
        let delegate = SessionDelegate(trustEvaluator: nil)

        let (disposition, credential) = Self.answer(delegate, method: NSURLAuthenticationMethodClientCertificate)

        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    // MARK: - Helpers

    private static func identity() throws -> ClientIdentity {
        let fixtures = try ClientCertificateFixtures.shared.get()
        return try ClientIdentity(pkcs12: fixtures.trusted.pkcs12, passphrase: ClientCertificateFixtures.passphrase)
    }

    private static func answer(
        _ delegate: SessionDelegate,
        method: String,
        previousFailureCount: Int = 0
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let challenge = URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(host: "api.example.com", port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil, authenticationMethod: method),
            proposedCredential: nil,
            previousFailureCount: previousFailureCount,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender()
        )
        let session = URLSession(configuration: .ephemeral)
        let answer = OSAllocatedUnfairLock<(URLSession.AuthChallengeDisposition, URLCredential?)?>(initialState: nil)
        delegate.urlSession(session, task: session.dataTask(with: URLRequest(url: URL(filePath: "/"))), didReceive: challenge) { disposition, credential in
            answer.withLock { $0 = (disposition, credential) }
        }
        return answer.withLock { $0 } ?? (.rejectProtectionSpace, nil)
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

// MARK: - Mutual TLS

/// Mutual TLS against `RedTeamTLSServer`, a real TLS listener that requires a client certificate.
@Suite(
    "Client certificate authentication",
    .timeLimit(.minutes(1)),
    .enabled(if: RedTeamTLSServer.isAvailable && ClientCertificateFixtures.isAvailable, "needs a loopback TLS identity and openssl")
)
struct ClientCertificateAuthTests {
    typealias Fixture = TrustFixtures.Certificate

    // MARK: - Types

    enum Operation: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case data
        case upload
        case download
        case stream
        case webSocket

        var testDescription: String {
            rawValue
        }

        func run(_ netti: Netti, url: URL) async throws(HTTPRequestError) {
            switch self {
                case .data:
                    let response = try await netti.send(URLRequest(url: url))
                    #expect(response.statusCode == 200)
                case .upload:
                    try await netti.upload(URLEndpoint(url), data: Data("payload".utf8))
                case .download:
                    _ = try await netti.download(URLEndpoint(url))
                case .stream:
                    _ = try await netti.stream(URLRequest(url: url))
                case .webSocket:
                    _ = try await netti.webSocket(URLEndpoint(url))
            }
        }
    }

    /// The handshake order differs between TLS versions, so the trust and rejection rules run under both.
    enum TLSLimit: CaseIterable, CustomTestStringConvertible, Sendable {
        case systemDefault
        case tls12

        var maximumVersion: tls_protocol_version_t? {
            switch self {
                case .systemDefault: nil
                case .tls12: .TLSv12
            }
        }

        var testDescription: String {
            switch self {
                case .systemDefault: "default TLS"
                case .tls12: "TLS 1.2"
            }
        }
    }

    // MARK: - Presented

    @Test(
        "given a server that requires a client certificate, when a request runs with an accepted identity, then the server sees the identity's certificate",
        arguments: Operation.allCases
    )
    func acceptedIdentity_serverSeesCertificate(operation: Operation) async throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let server = try await RedTeamTLSServer.start(clientAuthentication: .require(authority: fixtures.trusted.authority))
        defer { server.stop() }
        let netti = makeNetti(service: try Self.service(fixtures.trusted, policy: Self.trustingPolicy))

        if operation == .webSocket {
            // The server speaks plain HTTP, so the upgrade fails after the handshake that is under test.
            _ = try? await netti.webSocket(URLEndpoint(server.url("/socket")))
        } else {
            try await operation.run(netti, url: server.url("/\(operation.rawValue)"))
            #expect(server.requestCount == 1)
        }

        #expect(server.clientCertificates == [fixtures.trusted.certificate])
    }

    // MARK: - Server trust

    @Test(
        "given an identity and a pin the server does not match, when a request runs, then it throws serverTrustEvaluationFailed and the server never receives the certificate",
        arguments: TLSLimit.allCases
    )
    func pinMismatch_identityNeverSent(limit: TLSLimit) async throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let server = try await RedTeamTLSServer.start(maximumTLSVersion: limit.maximumVersion, clientAuthentication: .require(authority: fixtures.trusted.authority))
        defer { server.stop() }
        let policy = ServerTrustPolicy([
            "localhost": .publicKeys([Fixture.unrelated.expectedPin, Fixture.otherHost.expectedPin], performDefaultValidation: false),
        ])
        let netti = makeNetti(service: try Self.service(fixtures.trusted, policy: policy))

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await netti.send(URLRequest(url: server.url("/data")))
        }

        #expect(error?.trustFailureHost == "localhost", "\(String(describing: error))")
        #expect(server.clientCertificates.isEmpty)
        #expect(server.requestCount == 0)
    }

    // MARK: - Fail closed

    @Test(
        "given an identity from an authority the server does not trust, when a request runs, then it throws clientCertificateRejected and the server sees no anonymous request",
        arguments: TLSLimit.allCases
    )
    func untrustedIdentity_failsClosed(limit: TLSLimit) async throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let server = try await RedTeamTLSServer.start(maximumTLSVersion: limit.maximumVersion, clientAuthentication: .require(authority: fixtures.trusted.authority))
        defer { server.stop() }
        let netti = makeNetti(service: try Self.service(fixtures.untrusted, policy: Self.trustingPolicy))

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await netti.send(URLRequest(url: server.url("/data")))
        }

        guard case .requestFailed(let underlying)? = error else {
            Issue.record("expected requestFailed, got \(String(describing: error))")
            return
        }
        #expect(underlying.code == .clientCertificateRejected, "\(underlying)")
        #expect(server.requestCount == 0)
        // Every connection the server accepted carried the identity: none fell back to anonymous.
        #expect(server.connectionCount > 0)
        #expect(server.clientCertificates.count == server.connectionCount)
        #expect(Set(server.clientCertificates) == [fixtures.untrusted.certificate])
    }

    @Test("given an identity the server rejects, when the request fails, then the error and the logs hold no passphrase")
    func rejectedIdentity_errorHoldsNoSecrets() async throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let server = try await RedTeamTLSServer.start(clientAuthentication: .require(authority: fixtures.trusted.authority))
        defer { server.stop() }
        let messages = Recorder<String>()
        let monitor = RedTeamFailureMonitor()
        let netti = makeNetti(
            service: try Self.service(fixtures.untrusted, policy: Self.trustingPolicy),
            monitors: [monitor],
            logger: NetworkLogger { _, message in messages.append(message) }
        )

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await netti.send(URLRequest(url: server.url("/data")))
        }

        let texts = [String(describing: error), error?.localizedDescription ?? ""]
            + monitor.failures.values.map { String(describing: $0) }
            + messages.values
        try Self.expectNoSecrets(in: texts, credential: fixtures.untrusted)
    }

    // MARK: - Without an identity

    @Test("given no identity, when a request goes to a server that requires a client certificate, then it fails and the server sees no certificate")
    func noIdentity_serverRequiresCertificate_fails() async throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let server = try await RedTeamTLSServer.start(clientAuthentication: .require(authority: fixtures.trusted.authority))
        defer { server.stop() }
        let netti = makeNetti(service: URLSessionNetworkService(configuration: .ephemeral, trustPolicy: try Self.trustingPolicy))

        let error = await expectRequestError { () async throws(HTTPRequestError) in
            try await netti.send(URLRequest(url: server.url("/data")))
        }

        #expect(error != nil)
        #expect(server.clientCertificates.isEmpty)
        #expect(server.requestCount == 0)
    }

    @Test("given an identity, when the server does not ask for a client certificate, then the request succeeds and no certificate is sent")
    func identityConfigured_serverDoesNotAsk_succeeds() async throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let server = try await RedTeamTLSServer.start()
        defer { server.stop() }
        let netti = makeNetti(service: try Self.service(fixtures.trusted, policy: Self.trustingPolicy))

        let response = try await netti.send(URLRequest(url: server.url("/data")))

        #expect(response.statusCode == 200)
        #expect(server.clientCertificates.isEmpty)
    }

    // MARK: - Logging

    @Test("given logging is enabled, when a request authenticates with an identity, then no log line holds the passphrase or the PKCS#12 data")
    func logging_neverHoldsSecrets() async throws {
        let fixtures = try ClientCertificateFixtures.shared.get()
        let server = try await RedTeamTLSServer.start(clientAuthentication: .require(authority: fixtures.trusted.authority))
        defer { server.stop() }
        let messages = Recorder<String>()
        let netti = makeNetti(
            service: try Self.service(fixtures.trusted, policy: Self.trustingPolicy),
            logger: NetworkLogger { _, message in messages.append(message) }
        )

        let response = try await netti.send(URLRequest(url: server.url("/data")))

        #expect(response.statusCode == 200)
        #expect(messages.values.isEmpty == false)
        try Self.expectNoSecrets(in: messages.values, credential: fixtures.trusted)
    }
}

// MARK: - Helpers

private extension ClientCertificateAuthTests {
    /// Trusts the loopback server's own key; no default validation, so only the pin decides.
    static var trustingPolicy: ServerTrustPolicy {
        get throws {
            ServerTrustPolicy(["localhost": .publicKeys([try RedTeamTLSServer.pin], performDefaultValidation: false)])
        }
    }

    static func service(_ credential: ClientCertificateFixtures.Credential, policy: @autoclosure () throws -> ServerTrustPolicy) throws -> URLSessionNetworkService {
        let identity = try ClientIdentity(pkcs12: credential.pkcs12, passphrase: ClientCertificateFixtures.passphrase)
        return URLSessionNetworkService(configuration: .ephemeral, trustPolicy: try policy(), clientIdentity: identity)
    }

    /// Fails when any text holds the passphrase or any slice of the PKCS#12 data.
    static func expectNoSecrets(in texts: [String], credential: ClientCertificateFixtures.Credential) throws {
        let encoded = credential.pkcs12.base64EncodedString()
        let slices = [encoded.prefix(48), encoded.suffix(48)].map(String.init)
        let hex = credential.pkcs12.prefix(24).map { String(format: "%02x", $0) }.joined()
        for text in texts {
            #expect(text.contains(ClientCertificateFixtures.passphrase) == false, "\(text)")
            for slice in slices {
                #expect(text.contains(slice) == false, "\(text)")
            }
            #expect(text.contains(hex) == false, "\(text)")
        }
    }
}
