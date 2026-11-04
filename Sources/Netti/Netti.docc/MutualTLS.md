# Mutual TLS

Prove your app's identity to a server that requires a client certificate, without weakening how the server itself is checked.

## Overview

Some servers, such as internal APIs and payment gateways, accept a connection only from a client that presents a certificate. Load that certificate and its private key from a PKCS#12 file into a ``ClientIdentity``, and give it to the engine:

```swift
let p12 = try Data(contentsOf: p12URL)
let identity = try ClientIdentity(pkcs12: p12, passphrase: passphrase)
let netti = Netti(service: URLSessionNetworkService(clientIdentity: identity))
```

From then on, whenever a server asks for a client certificate, the engine presents the identity. This holds for data, upload, download, byte-stream and WebSocket requests alike. The engine offers the identity for client-certificate requests only; a server that asks for HTTP Basic credentials, for example, never receives it.

### Load the identity

``ClientIdentity/init(pkcs12:passphrase:)`` throws ``HTTPRequestError/encodingFailed(_:)`` when the data is not valid PKCS#12, when the passphrase is wrong, or when the file holds no private key with a certificate. The error text is fixed: it never contains the passphrase, the file's bytes or key material.

```swift
do {
    let identity = try ClientIdentity(pkcs12: p12, passphrase: passphrase)
    netti = Netti(service: URLSessionNetworkService(clientIdentity: identity))
} catch {
    report("The client certificate could not be loaded: \(error)")
}
```

Netti uses the passphrase and the bytes for the import and then drops them. The identity keeps only the references Security.framework returns, and the private key never leaves the framework. Printing or dumping an identity shows only its type.

### Keep the server check

An identity does not change how the server is evaluated. Combine it with a ``ServerTrustPolicy`` to pin the server, as described in <doc:CertificatePinning>:

```swift
let service = URLSessionNetworkService(
    trustPolicy: ServerTrustPolicy(["api.example.com": .publicKeys(["PRIMARY_SPKI_SHA256=", "BACKUP_SPKI_SHA256="])]),
    clientIdentity: identity
)
```

The server's certificate is evaluated first. A server that fails the policy is rejected with ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)`` before your certificate is sent, so the identity never reaches a server you do not trust.

### Rejection fails closed

When an identity is configured and the server rejects it, for example because a different authority issued it, the request fails with ``HTTPRequestError/requestFailed(_:)`` carrying `URLError.clientCertificateRejected`. Netti never retries the connection without the identity and never falls back to an anonymous request:

```swift
do {
    _ = try await netti.send(URLRequest(url: url))
} catch HTTPRequestError.requestFailed(let error) where error.code == .clientCertificateRejected {
    report("The server does not accept this client certificate")
}
```

With TLS 1.3 a server judges the certificate after the client has finished its side of the handshake, so a rejection often arrives as a closed connection. Netti reports a connection that closes or fails its handshake after the identity was presented, and before any response, as `clientCertificateRejected`; the original error is kept as the underlying error.

A service created without a `clientIdentity` handles client-certificate requests as before: the system decides.

### Where to keep the file

Ship the PKCS#12 file as little as possible. Fetch it from your backend or an MDM payload after sign-in, and keep the passphrase out of the app bundle, ideally in the Keychain:

```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccount as String: "client-certificate-passphrase",
    kSecReturnData as String: true,
]
var item: CFTypeRef?
if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
    passphrase = String(decoding: data, as: UTF8.self)
}
```

### Platform notes

On macOS 15, iOS 18 and later, the import is memory-only: nothing is written to a keychain. On iOS 17 the system already imports in memory. On macOS 14 the system adds the identity to the default keychain when it imports it, because the memory-only option does not exist there. Create the identity once and reuse it, rather than once per request, so that import happens once.

The engine takes the identity when it is created, so it applies to every request that engine sends.
