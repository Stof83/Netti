# Test fixtures

Fixtures used by `NettiTests`. Only public certificates are committed; no private keys.

## Certificates/

DER certificates for the server-trust suites (`CertificateHelpersTests`, `TrustEvaluatorTests`, `ServerTrustPolicyTests`), generated with OpenSSL 3.4+ by [`generate-fixtures.sh`](generate-fixtures.sh). Tests evaluate at a fixed date, 2026-06-01, with network fetch disabled.

| File | Key | Host (SAN) | Validity | Issuer |
|---|---|---|---|---|
| `ca.cer` | P-256 | — (CA) | 2020-01-01 → 2040-01-01 | self-signed |
| `leaf-rsa2048.cer` | RSA-2048 | `api.example.com` | 2026-01-01 → 2028-03-01 | test CA |
| `leaf-rsa4096.cer` | RSA-4096 | `api.example.com` | 2026-01-01 → 2028-03-01 | test CA |
| `leaf-p256.cer` | P-256 | `api.example.com` | 2026-01-01 → 2028-03-01 | test CA |
| `leaf-p384.cer` | P-384 | `api.example.com` | 2026-01-01 → 2028-03-01 | test CA |
| `leaf-expired.cer` | P-256 | `api.example.com` | 2024-01-01 → 2025-01-01 | test CA |
| `leaf-other-host.cer` | P-256 | `other.example.net` | 2026-01-01 → 2028-03-01 | test CA |
| `unrelated.der` | P-256 | — | 2026-01-01 → 2028-03-01 | self-signed |
| `leaf-forged-issuer.cer` | P-256 | `api.example.com` | 2026-01-01 → 2028-03-01 | a second key named `Netti Test Root CA` (forgery) |

Leaves carry EKU `serverAuth` and a validity under Apple's 825-day TLS limit.

Regenerating replaces every key, so update the expected SPKI hashes in `Tests/NettiTests/TrustFixtures.swift` with the values the script prints (`openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`).
