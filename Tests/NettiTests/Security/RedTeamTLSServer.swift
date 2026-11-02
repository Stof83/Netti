//
//  RedTeamTLSServer.swift
//  Netti
//

import Foundation
import Network
import os
import Security
import Testing

@testable import Netti

// MARK: - TLS Server

/// A minimal HTTPS/1.1 server on 127.0.0.1, so trust tests run against a real TLS handshake.
///
/// Its identity is a self-signed RSA-2048 certificate for `localhost` and `127.0.0.1`, generated
/// once per test process with `/usr/bin/openssl` and imported in memory only
/// (`kSecImportToMemoryOnly`): no private key is committed and nothing touches a keychain.
///
/// Every connection serves one request and is closed. ``requestCount`` counts requests that were
/// read after a completed handshake, so it stays at zero when the client rejects the server's trust.
final class RedTeamTLSServer: @unchecked Sendable {

    // MARK: - Types

    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data("ok".utf8)
    }

    /// Answers a request; receives its target (`/path?query`).
    typealias Handler = @Sendable (String) -> Response

    enum ServerError: Error {
        case identityUnavailable(String)
        case listenerFailed
    }

    // MARK: - Properties

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "netti.tests.redteam-tls")
    private let state = OSAllocatedUnfairLock(initialState: (port: UInt16(0), connections: 0, requests: 0))

    var port: UInt16 {
        state.withLock { $0.port }
    }

    /// TCP connections accepted, whether or not their handshake completed.
    var connectionCount: Int {
        state.withLock { $0.connections }
    }

    /// Requests read over a completed handshake.
    var requestCount: Int {
        state.withLock { $0.requests }
    }

    // MARK: - Initialization

    private init(identity: SecIdentity, maximumTLSVersion: tls_protocol_version_t?, handler: @escaping Handler) throws {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            throw ServerError.identityUnavailable("sec_identity_create failed")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        if let maximumTLSVersion {
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv10)
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, maximumTLSVersion)
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
        self.handler = handler
    }

    /// Starts a server on a free loopback port.
    ///
    /// - Parameters:
    ///   - maximumTLSVersion: Caps the TLS version the server accepts; `nil` keeps the system range.
    ///   - handler: Answers each request. Defaults to `200 ok`.
    static func start(
        maximumTLSVersion: tls_protocol_version_t? = nil,
        handler: @escaping Handler = { _ in Response() }
    ) async throws -> RedTeamTLSServer {
        let server = try RedTeamTLSServer(identity: try identity.get(), maximumTLSVersion: maximumTLSVersion, handler: handler)
        try await server.run()
        return server
    }

    func stop() {
        listener.cancel()
    }

    func url(_ path: String, scheme: String = "https", host: String = "localhost") -> URL {
        URL(string: "\(scheme)://\(host):\(port)\(path)")!
    }

    // MARK: - Identity

    /// The base64 SPKI SHA-256 of the server certificate, as a `publicKeys` pin.
    static var pin: String {
        get throws {
            try #require(Certificates.publicKeyPin(ofCertificate: certificateDER.get()))
        }
    }

    /// Whether the identity could be generated; suites that need the server are enabled on it.
    static var isAvailable: Bool {
        (try? identity.get()) != nil
    }

    // `SecIdentity` is an immutable Core Foundation object.
    nonisolated(unsafe) private static let identity: Result<SecIdentity, ServerError> = makeIdentity()

    private static let certificateDER: Result<Data, ServerError> = identity.flatMap { identity in
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            return .failure(.identityUnavailable("the certificate could not be read from the identity"))
        }
        return .success(SecCertificateCopyData(certificate) as Data)
    }

    private static func makeIdentity() -> Result<SecIdentity, ServerError> {
        #if os(macOS)
        guard #available(macOS 15, *) else {
            return .failure(.identityUnavailable("in-memory PKCS#12 import needs macOS 15"))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-redteam-tls-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem").path
        let certificate = directory.appendingPathComponent("cert.pem").path
        let bundle = directory.appendingPathComponent("identity.p12").path
        let passphrase = "netti-redteam"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try openssl([
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", certificate, "-days", "30",
                "-subj", "/CN=localhost",
                "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                "-addext", "extendedKeyUsage=serverAuth",
            ])
            // 3DES/SHA-1 is the PKCS#12 profile `SecPKCS12Import` reads in memory-only mode.
            try openssl([
                "pkcs12", "-export", "-inkey", key, "-in", certificate, "-out", bundle, "-passout", "pass:\(passphrase)",
                "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
            ])
            let data = try Data(contentsOf: URL(fileURLWithPath: bundle))
            var items: CFArray?
            let options: [String: Any] = [kSecImportExportPassphrase as String: passphrase, kSecImportToMemoryOnly as String: true]
            let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
            guard status == errSecSuccess,
                  let first = (items as? [[String: Any]])?.first,
                  let identity = first[kSecImportItemIdentity as String]
            else {
                return .failure(.identityUnavailable("SecPKCS12Import failed with OSStatus \(status)"))
            }
            // Core Foundation type: the cast always succeeds once the key is present.
            return .success(identity as! SecIdentity)
        } catch let error as ServerError {
            return .failure(error)
        } catch {
            return .failure(.identityUnavailable(String(describing: error)))
        }
        #else
        return .failure(.identityUnavailable("the identity is generated with /usr/bin/openssl, on macOS only"))
        #endif
    }

    #if os(macOS)
    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ServerError.identityUnavailable("openssl \(arguments.first ?? "") exited with \(process.terminationStatus)")
        }
    }
    #endif
}

// MARK: - Private Methods

private extension RedTeamTLSServer {
    func run() async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let listener = listener
            let state = state
            listener.stateUpdateHandler = { listenerState in
                let outcome: Result<Void, any Error>?
                switch listenerState {
                    case .ready:
                        let port = listener.port?.rawValue ?? 0
                        state.withLock { $0.port = port }
                        outcome = .success(())
                    case .failed, .cancelled:
                        outcome = .failure(ServerError.listenerFailed)
                    default:
                        outcome = nil
                }
                guard let outcome, resumed.withLock({ wasResumed in
                    defer { wasResumed = true }
                    return wasResumed == false
                }) else {
                    return
                }
                continuation.resume(with: outcome)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func accept(_ connection: NWConnection) {
        state.withLock { $0.connections += 1 }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    receive(on: connection, buffer: buffer)
                }
                return
            }
            state.withLock { $0.requests += 1 }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            respond(handler(target), on: connection)
        }
    }

    func respond(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) Status\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Shared Helpers

/// Accepts every host without evaluation: stands in for a mis-issued certificate the system trusts.
struct RedTeamAcceptingEvaluator: ServerTrustEvaluating {
    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {}
}

/// Counts how many times trust is evaluated, then accepts.
struct RedTeamCountingEvaluator: ServerTrustEvaluating {
    let counter: Counter

    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        counter.increment()
    }
}

/// Records every failure a client reports.
final class RedTeamFailureMonitor: EventMonitor {
    let failures = Recorder<HTTPRequestError>()
    let sent = Recorder<URLRequest>()

    func requestDidSend(_ request: URLRequest) {
        sent.append(request)
    }

    func requestDidFail(_ request: URLRequest, error: HTTPRequestError) {
        failures.append(error)
    }
}

/// SplitMix64, local to the red-team suites, so every run draws the same values.
struct RedTeamRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func bytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &self) })
    }
}

extension HTTPRequestError {
    /// The host of a `serverTrustEvaluationFailed` error.
    var trustFailureHost: String? {
        guard case .serverTrustEvaluationFailed(let host, _) = self else {
            return nil
        }
        return host
    }

    var isEncodingFailure: Bool {
        if case .encodingFailed = self {
            return true
        }
        return false
    }

    var isDecodingFailure: Bool {
        if case .decodingFailed = self {
            return true
        }
        return false
    }
}
