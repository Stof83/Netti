# Certificate Pinning

Pin your servers' public keys or certificates per host, with wildcards, a backup-pin check and a certificate expiry check.

## Overview

A ``ServerTrustPolicy`` maps hosts to a ``ServerTrustEvaluator``. Give it to the engine, and it decides every TLS challenge for every request and WebSocket that engine opens:

```swift
let pinning = ServerTrustPolicy([
    "api.example.com": .publicKeys(["PRIMARY_SPKI_SHA256=", "BACKUP_SPKI_SHA256="]),
])
let netti = Netti(service: URLSessionNetworkService(trustPolicy: pinning))
```

A rejected host fails with ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)``. Without a policy, the engine leaves trust to the system.

### Prefer public-key pins

``ServerTrustEvaluator/publicKeys(_:performDefaultValidation:)`` accepts a host only when a certificate in its chain has one of the pinned keys. A pin is the base64 SHA-256 of the certificate's SubjectPublicKeyInfo (SPKI), for RSA and EC keys alike. Compute it from a certificate with:

```shell
openssl x509 -in api.example.com.pem -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | base64
```

To compute the same pin in code, for a release script or a launch check that never depends on `openssl`, pass the certificate's DER bytes to ``ServerTrustPolicy/publicKeyPin(ofCertificate:)``, or a `SecCertificate`, for example one from a `SecTrust` chain, to ``ServerTrustPolicy/publicKeyPin(of:)``:

```swift
let der = try Data(contentsOf: certificateURL)
if let pin = ServerTrustPolicy.publicKeyPin(ofCertificate: der) {
    report("pin: \(pin)")
} else {
    report("not a DER certificate")
}
```

Both return the same string as the `openssl` pipeline. They return `nil` when the bytes are not a well-formed DER certificate, never a wrong pin; PEM is not accepted, so convert it with `openssl x509 -outform der` first.

A key pin survives certificate renewal as long as the server keeps its key. Always configure at least two pins, the current key and a backup. Otherwise, rotating the key locks every installed app out. ``ServerTrustPolicy`` logs a warning for each host with fewer than two pins when it is created.

### Pin certificates

``ServerTrustEvaluator/pinnedCertificates(in:subdirectory:performDefaultValidation:)`` loads every DER certificate (`.cer`, `.der`, `.crt`) from a bundle once, and accepts a host only when its chain contains one of them. ``ServerTrustEvaluator/pinnedCertificates(_:performDefaultValidation:)`` takes the DER data directly. PEM files are skipped with a logged warning; convert them with `openssl x509 -outform der`.

```swift
let pinning = ServerTrustPolicy([
    "api.example.com": .pinnedCertificates(in: .main, subdirectory: "Certificates"),
])
```

A pinned certificate must be replaced in the app before it expires, so certificate pins need more care than key pins; see <doc:#Certificate-expiry-and-rotation>.

### Certificate expiry and rotation

A pinned certificate rejects its host from the moment it expires, so every installed app that pins it stops working until users update. ``ServerTrustPolicy/pinnedCertificatesExpiring(within:asOf:)`` lists the pinned certificates that are expired or expire within an interval, soonest first. Call it once at launch and report what it returns, while there is still time to ship a release:

```swift
for expiry in pinning.pinnedCertificatesExpiring(within: .seconds(60 * 24 * 60 * 60)) {
    report("\(expiry.host) pins \(expiry.subject ?? "a certificate") that expires \(expiry.notAfter)")
}
```

Each ``PinnedCertificateExpiry`` holds the ``PinnedCertificateExpiry/host`` or wildcard it is pinned for, the certificate's ``PinnedCertificateExpiry/subject`` and its ``PinnedCertificateExpiry/notAfter`` date. ``PinnedCertificateExpiry/isExpired(at:)`` tells an expired certificate from one about to expire. A certificate that has already expired is always listed, whatever the interval.

- Only certificate pins are checked, including those inside ``ServerTrustEvaluator/composite(_:)`` and under a wildcard host. A public-key pin has no expiry of its own, and survives the renewal of its certificate.
- Creating a ``ServerTrustPolicy`` also logs one warning to the unified log (subsystem `Netti`, category `security`) for each pinned certificate that is expired or expires within 30 days, next to the warning for a host with fewer than two pins.
- The date is read from the certificate's DER encoding, so the check works on every supported platform, including iOS 17, where `SecCertificateCopyNotValidAfterDate` isn't available.

To rotate a key or a certificate without locking anyone out:

1. Ship the new pin in an app release while the old one is still pinned, at least one release cycle before the server switches, plus a margin for users who update slowly.
2. Switch the server only once that release is out. The app accepts both pins meanwhile.
3. Remove the old pin in a later release.

Prefer key pins, which survive a renewal that keeps the key, and always keep at least two pins per host. For a backup key pin, hash the public key of a key pair you have generated but not deployed:

```shell
openssl pkey -in backup.key -pubout -outform der | openssl dgst -sha256 -binary | base64
```

`Examples/CertificatePinning.swift` builds every policy in this article, computes the pin of an embedded certificate in code and checks it against the `openssl` value, and runs the expiry check. Run it with `swift run NettiExamples`; `EXAMPLES.md` at the root of the repository has the full rotation playbook.

### Match hosts

- Hosts match case-insensitively and ignore a trailing dot.
- `*.example.com` matches exactly one leftmost label, as RFC 6125 requires: `api.example.com`, but neither `example.com` nor `a.api.example.com`. A wildcard never matches an IP address.
- An exact host beats a wildcard.
- ``ServerTrustPolicy/allHostsMustBeEvaluated`` is `true` by default, so a host without an entry is **rejected**. That fails closed when a host is misspelled or forgotten. If the same engine also talks to hosts you do not pin, such as a CDN or an analytics endpoint, either list them with ``ServerTrustEvaluator/default`` or pass `false`, so unlisted hosts get default validation:

```swift
let pinning = ServerTrustPolicy(
    [
        "api.example.com": .publicKeys(["PRIMARY_SPKI_SHA256=", "BACKUP_SPKI_SHA256="]),
        "*.cdn.example.com": .default,
    ],
    allHostsMustBeEvaluated: false
)
```

### Combine evaluators

| Evaluator | Accepts the host when |
|---|---|
| ``ServerTrustEvaluator/default`` | The chain and host name pass the system SSL policy |
| ``ServerTrustEvaluator/revocation`` | Default validation passes and no certificate is revoked (soft-fail; use ``ServerTrustEvaluator/revocation(requirePositiveResponse:)`` for hard-fail) |
| ``ServerTrustEvaluator/publicKeys(_:performDefaultValidation:)`` | A chain certificate has a pinned key |
| `pinnedCertificates` | The chain contains a pinned certificate |
| ``ServerTrustEvaluator/composite(_:)`` | Every evaluator accepts it, in order |
| ``ServerTrustEvaluator/custom(_:)`` | Your ``ServerTrustEvaluating`` type accepts it |
| ``ServerTrustEvaluator/disabled`` | Always; compiled in DEBUG builds only |

Pinning evaluators also run default validation unless `performDefaultValidation` is `false`; see <doc:#Pin-without-default-validation>.

```swift
let pinning = ServerTrustPolicy([
    "api.example.com": .composite([.revocation, .publicKeys(["PRIMARY_SPKI_SHA256=", "BACKUP_SPKI_SHA256="])]),
])
```

### Pin without default validation

Keep default validation on for public servers. Turn it off only for a server whose chain the system doesn't trust, such as one issued by your own private CA:

```swift
let pinning = ServerTrustPolicy([
    "internal.example.com": .pinnedCertificates(in: .main, subdirectory: "Certificates", performDefaultValidation: false),
])
```

With `performDefaultValidation: false`, the pins become the only trust anchors, and the chain is still evaluated with the SSL policy for the host: signatures, validity dates, CA constraints, the host name and the server-authentication key usage. Only the system roots are not checked. Pin membership alone is never enough, so a forged leaf sent next to your genuine pinned certificate is rejected, and so is a leaf your pinned CA issued for another host.

- With ``ServerTrustEvaluator/pinnedCertificates(_:performDefaultValidation:)``, the pinned certificates are the anchors. The server may leave a pinned root out of the chain it sends.
- With ``ServerTrustEvaluator/publicKeys(_:performDefaultValidation:)``, the anchors are the certificates in the chain that carry a pinned key. The server must send the certificate that carries the pinned key; pinning the key of a root the server doesn't send fails.
- An expired or not-yet-valid certificate in the chain fails, as it does with default validation.
- The leaf must name the host in its subject alternative names. A private-CA certificate without a SAN for the host fails; reissue it with one.
- The evaluation runs on a copy of the server's trust, so in ``ServerTrustEvaluator/composite(_:)`` a later ``ServerTrustEvaluator/default`` still checks the chain against the system roots.

Alamofire's evaluators, which 1.x used, only check in this mode that a pinned certificate or key appears somewhere in the chain. A chain that passed only because of that, such as an expired one, now fails with ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)``.

### Write a custom evaluator

Conform to ``ServerTrustEvaluating`` and reuse the built-in evaluators inside it. Evaluation is synchronous and may block while the system validates the chain; engines call it off the main actor.

```swift
struct IntermediateRequiredEvaluator: ServerTrustEvaluating {
    func evaluate(_ trust: SecTrust, forHost host: String) throws(HTTPRequestError) {
        try ServerTrustEvaluator.default.evaluate(trust, forHost: host)
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        guard chain.count > 1 else {
            throw .serverTrustEvaluationFailed(host: host, reason: "the server sent no intermediate certificate")
        }
    }
}

let pinning = ServerTrustPolicy(["api.example.com": .custom(IntermediateRequiredEvaluator())])
```

### Turn pinning off in debug builds

To inspect traffic with a proxy during development, ``ServerTrustEvaluator/disabled`` accepts every host. It only exists in DEBUG builds, so code that uses it must be conditional too. It never ships by accident:

```swift
#if DEBUG
let evaluator = ServerTrustEvaluator.disabled
#else
let evaluator = ServerTrustEvaluator.publicKeys(["PRIMARY_SPKI_SHA256=", "BACKUP_SPKI_SHA256="])
#endif
let netti = Netti(service: URLSessionNetworkService(trustPolicy: ServerTrustPolicy(["api.example.com": evaluator])))
```

### Handle a rejection

```swift
do {
    let user: User? = try await netti.get(UserAPI.me).data
    show(user)
} catch .serverTrustEvaluationFailed(let host, let reason) {
    report("Untrusted \(host): \(reason)")
} catch {
    report(error)
}
```

A pinning failure is not retried by ``RetryPolicy``, since it is not a transient error.
