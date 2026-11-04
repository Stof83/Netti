//
//  ClientIdentity.swift
//  Netti
//

import Foundation
import Security

/// A client's identity for mutual TLS: a private key and its certificate chain, loaded from PKCS#12.
///
/// Pass it to ``URLSessionNetworkService/init(configuration:trustPolicy:redirectHandler:maxConnectionsPerHost:maximumResponseSize:maximumRequestDuration:clientIdentity:)``
/// and the engine presents it when a server asks for a client certificate:
///
/// ```swift
/// let identity = try ClientIdentity(pkcs12: try Data(contentsOf: p12URL), passphrase: passphrase)
/// let netti = Netti(service: URLSessionNetworkService(clientIdentity: identity))
/// ```
///
/// The identity is offered for client-certificate challenges only, and only after the server's
/// certificate passed the engine's ``ServerTrustPolicy``. Once an identity is configured the
/// engine never falls back to an anonymous connection: a server that rejects it fails the request
/// with ``HTTPRequestError/requestFailed(_:)`` carrying `URLError.clientCertificateRejected`.
///
/// The passphrase and the PKCS#12 bytes are used for the import and then dropped; the identity
/// keeps only the references Security.framework returns, and the private key never leaves it.
/// Printing or dumping an identity shows nothing but its type.
///
/// On macOS 15, iOS 18 and later the import is memory-only, so nothing reaches a keychain. On iOS 17
/// the system already imports in memory. On macOS 14 the system adds the identity to the default
/// keychain, which is why an app there should create the identity once and reuse it.
public struct ClientIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    // MARK: - Properties

    /// The private key and leaf certificate.
    private let identity: SendableBox<SecIdentity>
    /// The intermediate certificates, leaf excluded.
    private let intermediates: [SendableBox<SecCertificate>]

    // MARK: - Initialization

    /// Creates an identity from PKCS#12 data.
    ///
    /// - Parameters:
    ///   - pkcs12: The contents of a `.p12` or `.pfx` file.
    ///   - passphrase: The passphrase protecting it. It is never stored, logged or put in an error.
    /// - Throws: ``HTTPRequestError/encodingFailed(_:)`` when the data is not valid PKCS#12, the
    ///   passphrase is wrong, or the file holds no private key with a certificate. The error text is
    ///   fixed and holds neither the passphrase nor any key material.
    public init(pkcs12: Data, passphrase: String) throws(HTTPRequestError) {
        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        // Added in macOS 15 and iOS 18; earlier iOS imports in memory already, macOS 14 cannot.
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            throw .encodingFailed(ClientIdentityError(status == errSecAuthFailed ? .wrongPassphrase : .notPKCS12))
        }
        guard let entry = (items as? [[String: Any]])?.first,
              let imported = entry[kSecImportItemIdentity as String] as AnyObject?,
              CFGetTypeID(imported) == SecIdentityGetTypeID()
        else {
            throw .encodingFailed(ClientIdentityError(.noIdentity))
        }
        self.identity = SendableBox(unsafeDowncast(imported, to: SecIdentity.self))
        let chain = (entry[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        // The chain starts with the leaf, which the identity already carries.
        self.intermediates = chain.dropFirst().map { SendableBox($0) }
    }

    // MARK: - Credential

    /// The credential that answers a client-certificate challenge; never persisted.
    var credential: URLCredential {
        // An empty array crashes `URLCredential` when it bridges the chain, so no chain is `nil`.
        URLCredential(
            identity: identity.value,
            certificates: intermediates.isEmpty ? nil : intermediates.map(\.value),
            persistence: .none
        )
    }

    // MARK: - Descriptions

    public var description: String {
        "ClientIdentity(redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}

// MARK: - Private Types

/// Carries an immutable Core Foundation object across concurrency domains.
private struct SendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Why an import failed, as fixed text: it never includes the passphrase, the data or an `OSStatus`
/// that came with key material.
private struct ClientIdentityError: Error, CustomStringConvertible {
    enum Reason {
        case wrongPassphrase
        case notPKCS12
        case noIdentity
    }

    let reason: Reason

    init(_ reason: Reason) {
        self.reason = reason
    }

    var description: String {
        switch reason {
            case .wrongPassphrase: "The client identity could not be opened: the passphrase is wrong"
            case .notPKCS12: "The client identity could not be read: the data is not valid PKCS#12"
            case .noIdentity: "The client identity could not be used: the PKCS#12 file holds no private key with a certificate"
        }
    }
}
