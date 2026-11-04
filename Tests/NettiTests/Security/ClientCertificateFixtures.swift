//
//  ClientCertificateFixtures.swift
//  Netti
//

import Foundation
import Security

/// Client-certificate material for mutual-TLS tests, generated once per test process with
/// `/usr/bin/openssl` so no private key is ever committed.
///
/// Two unrelated authorities each issue one client certificate:
/// - ``trusted``: issued by the authority a `RedTeamTLSServer` is told to require;
/// - ``untrusted``: issued by an authority the server has never heard of.
///
/// Each is exported as a PKCS#12 file protected by ``passphrase``. The PKCS#12 profile is
/// 3DES/SHA-1 because that is what the system `openssl` (LibreSSL) writes on every macOS.
struct ClientCertificateFixtures: Sendable {

    // MARK: - Types

    /// One client certificate and the authority that issued it.
    struct Credential: Sendable {
        /// The PKCS#12 file: the client's private key and certificate.
        let pkcs12: Data
        /// The client's certificate, DER.
        let certificate: Data
        /// The issuing authority's certificate, DER.
        let authority: Data
    }

    enum FixtureError: Error {
        case unavailable(String)
    }

    // MARK: - Properties

    /// The passphrase of every PKCS#12 file here.
    static let passphrase = "netti-client-fixture"

    let trusted: Credential
    let untrusted: Credential

    /// The generated fixtures, or the reason they could not be made; suites are enabled on it.
    static let shared: Result<ClientCertificateFixtures, FixtureError> = make()

    /// Whether the fixtures could be generated.
    static var isAvailable: Bool {
        (try? shared.get()) != nil
    }

    // MARK: - Generation

    private static func make() -> Result<ClientCertificateFixtures, FixtureError> {
        #if os(macOS)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-client-fixtures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return .success(ClientCertificateFixtures(
                trusted: try issue(name: "trusted", in: directory),
                untrusted: try issue(name: "untrusted", in: directory)
            ))
        } catch let error as FixtureError {
            return .failure(error)
        } catch {
            return .failure(.unavailable(String(describing: error)))
        }
        #else
        return .failure(.unavailable("the fixtures are generated with /usr/bin/openssl, on macOS only"))
        #endif
    }

    #if os(macOS)
    /// Creates an authority and a client certificate it signs, named after `name`.
    private static func issue(name: String, in directory: URL) throws -> Credential {
        func path(_ file: String) -> String {
            directory.appendingPathComponent("\(name)-\(file)").path
        }
        let extensions = path("client.ext")
        try Data("basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n".utf8)
            .write(to: URL(fileURLWithPath: extensions))

        try openssl([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", path("ca.key"), "-out", path("ca.pem"), "-days", "30",
            "-subj", "/CN=Netti \(name) client authority",
            "-addext", "basicConstraints=critical,CA:TRUE",
        ])
        try openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", path("client.key"), "-out", path("client.csr"), "-subj", "/CN=netti-\(name)-client"])
        try openssl([
            "x509", "-req", "-in", path("client.csr"), "-CA", path("ca.pem"), "-CAkey", path("ca.key"), "-CAcreateserial",
            "-out", path("client.pem"), "-days", "30", "-extfile", extensions,
        ])
        try openssl([
            "pkcs12", "-export", "-inkey", path("client.key"), "-in", path("client.pem"), "-out", path("client.p12"),
            "-passout", "pass:\(passphrase)",
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
        ])
        try openssl(["x509", "-in", path("client.pem"), "-outform", "DER", "-out", path("client.der")])
        try openssl(["x509", "-in", path("ca.pem"), "-outform", "DER", "-out", path("ca.der")])

        return Credential(
            pkcs12: try Data(contentsOf: URL(fileURLWithPath: path("client.p12"))),
            certificate: try Data(contentsOf: URL(fileURLWithPath: path("client.der"))),
            authority: try Data(contentsOf: URL(fileURLWithPath: path("ca.der")))
        )
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.unavailable("openssl \(arguments.first ?? "") exited with \(process.terminationStatus)")
        }
    }
    #endif
}
