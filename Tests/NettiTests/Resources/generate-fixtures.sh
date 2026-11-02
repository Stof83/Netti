#!/usr/bin/env bash
#
# Regenerates the server-trust fixtures in Certificates/ (DER, public certificates only).
# Requires OpenSSL 3.4+ for -not_before / -not_after. Private keys live in a temporary
# directory that is deleted on exit; nothing secret is committed.
#
# After regenerating, update the expected hashes in Tests/NettiTests/TrustFixtures.swift
# with the values printed at the end.

set -euo pipefail

OUTPUT_DIR="$(cd "$(dirname "$0")" && pwd)/Certificates"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR"/*.cer "$OUTPUT_DIR"/*.der

# Leaves are valid 2026-01-01 → 2028-03-01 (790 days, under Apple's 825-day TLS limit).
# Tests evaluate at a fixed date (2026-06-01), so the fixtures never expire for the suite.
LEAF_NOT_BEFORE="20260101000000Z"
LEAF_NOT_AFTER="20280301000000Z"

cat > "$WORK_DIR/ca.ext" <<'EOF'
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

leaf_ext() {
    local host="$1" usage="$2"
    cat > "$WORK_DIR/leaf.ext" <<EOF
basicConstraints = critical, CA:FALSE
keyUsage = critical, $usage
extendedKeyUsage = serverAuth
subjectAltName = DNS:$host
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
}

# Test root CA (P-256), valid 2020-01-01 → 2040-01-01.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORK_DIR/ca.key" 2>/dev/null
openssl req -new -key "$WORK_DIR/ca.key" -subj "/CN=Netti Test Root CA" -out "$WORK_DIR/ca.csr"
openssl x509 -req -in "$WORK_DIR/ca.csr" -key "$WORK_DIR/ca.key" \
    -not_before 20200101000000Z -not_after 20400101000000Z \
    -extfile "$WORK_DIR/ca.ext" -sha256 -outform DER -out "$OUTPUT_DIR/ca.cer"
openssl x509 -inform DER -in "$OUTPUT_DIR/ca.cer" -out "$WORK_DIR/ca.pem"

# make_leaf <name> <genpkey args> <host> <keyUsage> <notBefore> <notAfter> [extension]
make_leaf() {
    local name="$1" keyargs="$2" host="$3" usage="$4" not_before="$5" not_after="$6" extension="${7:-cer}"
    # shellcheck disable=SC2086
    openssl genpkey $keyargs -out "$WORK_DIR/$name.key" 2>/dev/null
    openssl req -new -key "$WORK_DIR/$name.key" -subj "/CN=$host" -out "$WORK_DIR/$name.csr"
    leaf_ext "$host" "$usage"
    openssl x509 -req -in "$WORK_DIR/$name.csr" -CA "$WORK_DIR/ca.pem" -CAkey "$WORK_DIR/ca.key" \
        -set_serial "0x$(openssl rand -hex 8)" -not_before "$not_before" -not_after "$not_after" \
        -extfile "$WORK_DIR/leaf.ext" -sha256 -outform DER -out "$OUTPUT_DIR/$name.$extension"
}

RSA_USAGE="digitalSignature, keyEncipherment"
EC_USAGE="digitalSignature"

make_leaf leaf-rsa2048 "-algorithm RSA -pkeyopt rsa_keygen_bits:2048" api.example.com "$RSA_USAGE" "$LEAF_NOT_BEFORE" "$LEAF_NOT_AFTER"
make_leaf leaf-rsa4096 "-algorithm RSA -pkeyopt rsa_keygen_bits:4096" api.example.com "$RSA_USAGE" "$LEAF_NOT_BEFORE" "$LEAF_NOT_AFTER"
make_leaf leaf-p256 "-algorithm EC -pkeyopt ec_paramgen_curve:P-256" api.example.com "$EC_USAGE" "$LEAF_NOT_BEFORE" "$LEAF_NOT_AFTER"
make_leaf leaf-p384 "-algorithm EC -pkeyopt ec_paramgen_curve:P-384" api.example.com "$EC_USAGE" "$LEAF_NOT_BEFORE" "$LEAF_NOT_AFTER"
make_leaf leaf-expired "-algorithm EC -pkeyopt ec_paramgen_curve:P-256" api.example.com "$EC_USAGE" 20240101000000Z 20250101000000Z
make_leaf leaf-other-host "-algorithm EC -pkeyopt ec_paramgen_curve:P-256" other.example.net "$EC_USAGE" "$LEAF_NOT_BEFORE" "$LEAF_NOT_AFTER"

# An unrelated self-signed certificate (own key, not issued by the test CA), saved as .der
# so bundle loading covers both extensions.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORK_DIR/unrelated.key" 2>/dev/null
openssl req -x509 -new -key "$WORK_DIR/unrelated.key" -subj "/CN=Unrelated" \
    -not_before "$LEAF_NOT_BEFORE" -not_after "$LEAF_NOT_AFTER" -sha256 -outform DER -out "$OUTPUT_DIR/unrelated.der"

# A forged leaf: same issuer name as the test CA, signed by an impostor CA's own key. The
# impostor certificate itself is not kept; pinning the genuine CA must reject this leaf.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORK_DIR/impostor.key" 2>/dev/null
openssl req -new -key "$WORK_DIR/impostor.key" -subj "/CN=Netti Test Root CA" -out "$WORK_DIR/impostor.csr"
openssl x509 -req -in "$WORK_DIR/impostor.csr" -key "$WORK_DIR/impostor.key" \
    -not_before 20200101000000Z -not_after 20400101000000Z \
    -extfile "$WORK_DIR/ca.ext" -sha256 -out "$WORK_DIR/impostor.pem"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORK_DIR/leaf-forged-issuer.key" 2>/dev/null
openssl req -new -key "$WORK_DIR/leaf-forged-issuer.key" -subj "/CN=api.example.com" -out "$WORK_DIR/leaf-forged-issuer.csr"
leaf_ext api.example.com "$EC_USAGE"
openssl x509 -req -in "$WORK_DIR/leaf-forged-issuer.csr" -CA "$WORK_DIR/impostor.pem" -CAkey "$WORK_DIR/impostor.key" \
    -set_serial "0x$(openssl rand -hex 8)" -not_before "$LEAF_NOT_BEFORE" -not_after "$LEAF_NOT_AFTER" \
    -extfile "$WORK_DIR/leaf.ext" -sha256 -outform DER -out "$OUTPUT_DIR/leaf-forged-issuer.cer"

echo "SPKI SHA-256 (base64):"
for file in "$OUTPUT_DIR"/*.cer "$OUTPUT_DIR"/*.der; do
    hash="$(openssl x509 -inform DER -in "$file" -pubkey -noout \
        | openssl pkey -pubin -outform DER \
        | openssl dgst -sha256 -binary \
        | base64)"
    echo "  $(basename "$file"): $hash"
done
