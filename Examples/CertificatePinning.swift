//
//  CertificatePinning.swift
//  Netti
//

import Foundation
import Netti
import Security

// MARK: - Pins

// Compute a public-key pin (base64 SHA-256 of the SubjectPublicKeyInfo) from a certificate, in
// code with `ServerTrustPolicy.publicKeyPin(ofCertificate:)` (see `pinFromCertificateExample`), or
// from a shell:
//
//     openssl x509 -in api.example.com.pem -pubkey -noout \
//       | openssl pkey -pubin -outform der \
//       | openssl dgst -sha256 -binary \
//       | base64
//
// These two are placeholders in the right format (base64 of 32 bytes), not real keys.
private let primaryPin = "ERERERERERERERERERERERERERERERERERERERERERE="
private let backupPin = "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI="

private let sixtyDays = Duration.seconds(60 * 24 * 60 * 60)

// MARK: - Entry point

/// Builds every kind of trust policy, wires one into an engine, and runs the certificate expiry
/// check against an embedded certificate.
///
/// Runs offline: nothing here opens a connection. The policies are only built, and the expiry
/// check reads a certificate embedded in this file. Sending a request through a pinned engine
/// needs a real TLS handshake, so `pinnedRequestExample(netti:)` only compiles; main.swift does
/// not call it.
func certificatePinningExample() async throws {
    let der = try expectValue(Data(base64Encoded: embeddedCertificate, options: .ignoreUnknownCharacters), "the embedded certificate is not base64")
    try pinFromCertificateExample(certificate: der)
    let policy = apiPolicy()
    report("policy   -> built; every unlisted host is rejected: \(policy.allHostsMustBeEvaluated)")

    // The policy belongs to the engine, so it covers every request and WebSocket the client opens.
    let netti = Netti(service: URLSessionNetworkService(trustPolicy: policy))
    netti.isLoggingEnabled = false

    _ = certificatePolicy(certificate: der)
    _ = cdnPolicy()
    _ = compositePolicy()
    _ = privateCAPolicy()
    _ = developmentPolicy()
    report("policies -> certificate, CDN, composite, private CA and debug-only variants built")

    try expiryExample(certificate: der)
}

// MARK: - Policies

/// Pins two public keys. Key pins survive a certificate renewal, as long as the server keeps its
/// key; always keep at least two, the current one and a backup, or a key rotation locks every
/// installed app out. The policy logs a warning for a host with fewer than two.
private func apiPolicy() -> ServerTrustPolicy {
    ServerTrustPolicy([
        "api.example.com": .publicKeys([primaryPin, backupPin]),
        // One leftmost label only: `eu.example.com`, not `example.com` or `a.eu.example.com`.
        "*.example.com": .publicKeys([primaryPin, backupPin]),
    ])
}

/// Certificates instead of keys. They need more care: a pinned certificate must be replaced in
/// the app before it expires (see `expiryExample(certificate:)`).
private func certificatePolicy(certificate: Data) -> ServerTrustPolicy {
    ServerTrustPolicy([
        // Every DER `.cer`, `.der` and `.crt` in the app bundle's "Certificates" folder.
        "api.example.com": .pinnedCertificates(in: .main, subdirectory: "Certificates"),
        // Or the DER bytes directly.
        "files.example.com": .pinnedCertificates([certificate]),
    ])
}

/// A CDN or analytics host you do not pin gets default validation instead of being rejected.
private func cdnPolicy() -> ServerTrustPolicy {
    ServerTrustPolicy(
        [
            "api.example.com": .publicKeys([primaryPin, backupPin]),
            "*.cdn.example.com": .default,
        ],
        allHostsMustBeEvaluated: false
    )
}

/// Both evaluators must accept the host, in order: a soft-fail revocation check, then the pins.
private func compositePolicy() -> ServerTrustPolicy {
    ServerTrustPolicy([
        "api.example.com": .composite([.revocation, .publicKeys([primaryPin, backupPin])]),
    ])
}

/// A server whose chain the system does not trust, issued by your own CA. The pinned certificates
/// become the only trust anchors; the chain is still checked for validity dates, host name and key
/// usage. Keep default validation on for public servers.
private func privateCAPolicy() -> ServerTrustPolicy {
    ServerTrustPolicy([
        "internal.example.com": .pinnedCertificates(in: .main, subdirectory: "Certificates", performDefaultValidation: false),
    ])
}

/// `.disabled` exists in DEBUG builds only, so code that names it must be conditional too and it
/// can never ship by accident. Use it to inspect traffic through a proxy.
private func developmentPolicy() -> ServerTrustPolicy {
    let evaluator: ServerTrustEvaluator
    #if DEBUG
    evaluator = .disabled
    #else
    evaluator = .publicKeys([primaryPin, backupPin])
    #endif
    return ServerTrustPolicy(["api.example.com": evaluator])
}

// MARK: - Computing a pin

/// Computes a pin from a certificate, so a release script or a launch check never depends on `openssl`.
///
/// The embedded certificate's pin is `vFzo9rMWlmH3bW6NPQM8oFmsF0J8fXVBGCP5gRmRwdQ=`, the value the
/// `openssl` pipeline above prints for it. Pin the certificate you ship now plus a backup key you
/// keep offline, and the helper gives you the string for both.
private func pinFromCertificateExample(certificate der: Data) throws {
    let pin = try expectValue(ServerTrustPolicy.publicKeyPin(ofCertificate: der), "the embedded certificate has no readable public key")
    report("pin      -> \(pin)")
    try expect(pin == "vFzo9rMWlmH3bW6NPQM8oFmsF0J8fXVBGCP5gRmRwdQ=", "the pin differs from the openssl value")

    // A `SecCertificate`, for example one taken from a `SecTrust` chain, works the same way.
    let secCertificate = try expectValue(SecCertificateCreateWithData(nil, der as CFData), "the embedded certificate is not DER")
    try expect(ServerTrustPolicy.publicKeyPin(of: secCertificate) == pin, "the SecCertificate overload must agree")

    // Bytes that are not a certificate give nil, never a wrong pin.
    try expect(ServerTrustPolicy.publicKeyPin(ofCertificate: Data("not a certificate".utf8)) == nil, "garbage must not produce a pin")
}

// MARK: - Handling a rejection

/// Sends a request through a client whose engine pins `api.example.com` and reports a rejection.
///
/// Compiles only: it needs a real TLS handshake with a server whose key matches the pins, so
/// main.swift does not call it. A pinning failure is not retried by `RetryPolicy`, since it is not
/// a transient error.
func pinnedRequestExample(netti: Netti) async {
    do {
        let user: User? = try await netti.get(UserAPI.user(1)).data
        report("pinned   -> \(user?.name ?? "nil")")
    } catch .serverTrustEvaluationFailed(let host, let reason) {
        report("pinned   -> untrusted \(host): \(reason)")
    } catch {
        report("pinned   -> \(error)")
    }
}

// MARK: - Certificate expiry

// Rotation playbook for pinned certificates:
//  1. Ship the NEW certificate in the app while the OLD one is still pinned, at least one
//     release cycle (and a margin for slow updaters) before the old one expires.
//  2. Only then switch the server to the new certificate; both are accepted meanwhile.
//  3. Drop the old certificate in a later release.
//  Prefer key pins: they survive a renewal that keeps the key. Always keep >= 2 pins (current +
//  backup) so a compromised or lost key never locks users out.

/// Reports certificate pins that expire within 60 days, as an app would at launch.
///
/// - Parameters:
///   - policy: The policy the engine uses.
///   - now: The moment to check. Defaults to the current date.
/// - Returns: The expiring pins, soonest first.
@discardableResult
private func reportExpiringPins(of policy: ServerTrustPolicy, asOf now: Date = Date()) -> [PinnedCertificateExpiry] {
    let expiring = policy.pinnedCertificatesExpiring(within: sixtyDays, asOf: now)
    if expiring.isEmpty {
        report("expiry   -> no pinned certificate expires within 60 days")
    }
    for pin in expiring {
        let state = pin.isExpired(at: now) ? "EXPIRED" : "expires"
        report("expiry   -> \(pin.host) (\(pin.subject ?? "no subject")) \(state) \(pin.notAfter.formatted(.iso8601))")
    }
    return expiring
}

/// A startup check: warn (log, analytics, a dashboard) while there is still time to ship a release.
private func expiryExample(certificate der: Data) throws {
    let policy = ServerTrustPolicy(["api.example.com": .pinnedCertificates([der])], allHostsMustBeEvaluated: false)

    // Today: this certificate is good until 2028, so nothing is reported.
    reportExpiringPins(of: policy)

    // Two weeks before its notAfter date of 2028-03-01: reported, not yet expired.
    let nearExpiry = Date(timeIntervalSince1970: 1_834_185_600)
    let expiring = reportExpiringPins(of: policy, asOf: nearExpiry)
    try expect(expiring.count == 1, "expected 1 expiring certificate, got \(expiring.count)")
    try expect(expiring.first?.host == "api.example.com", "unexpected host")
    try expect(expiring.first?.isExpired(at: nearExpiry) == false, "should not be expired yet")

    // A day after: still reported, now as expired.
    let afterExpiry = Date(timeIntervalSince1970: 1_835_568_000)
    let expired = reportExpiringPins(of: policy, asOf: afterExpiry)
    try expect(expired.first?.isExpired(at: afterExpiry) == true, "should be expired")
}

// MARK: - Embedded certificate

/// A test leaf certificate for `api.example.com`, valid until 2028-03-01 (a copy of
/// `Tests/NettiTests/Resources/Certificates/leaf-p256.cer`, produced with `base64 -i leaf-p256.cer`).
/// Public by nature, and signed by a throwaway test CA; it protects nothing.
private let embeddedCertificate = """
MIIBwDCCAWegAwIBAgIJAPIsZqNUmsVvMAoGCCqGSM49BAMCMB0xGzAZBgNVBAMMEk5ldHRpIFRlc3Qg
Um9vdCBDQTAeFw0yNjAxMDEwMDAwMDBaFw0yODAzMDEwMDAwMDBaMBoxGDAWBgNVBAMMD2FwaS5leGFt
cGxlLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABK1JbxM+Xv6mnvTZGMN6m+eibJcsfv7FWvCn
AJOgMEKY8LwuZmmzLJZfUh3RINd6H+ICAoIMBnm2pwfCyCKy1dKjgZIwgY8wDAYDVR0TAQH/BAIwADAO
BgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwGgYDVR0RBBMwEYIPYXBpLmV4YW1wbGUu
Y29tMB0GA1UdDgQWBBRWb/BUQrLmseAkHhOwv4na6wAkVjAfBgNVHSMEGDAWgBSmnEfkNxX5A6VJIhxZ
+3VfP67rRjAKBggqhkjOPQQDAgNHADBEAiBpR/DQXvP24l3ixGHJNpL5SGqQESwO00wjs4pMS4/+YAIg
CuBZjCgIEgt4mI6iWYXBRNYrD62sNm2sr0+pLqZoMqU=
"""
