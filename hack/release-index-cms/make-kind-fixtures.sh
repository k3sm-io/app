#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# make-kind-fixtures.sh -- writes the TEST ONLY signed documents behind
# signedDocumentsAcceptedOnlyUnderTheirKind: one candidate and one stable index,
# each signed by a throwaway chain shaped like a Developer ID one and timestamped
# by Apple's public timestamp service.
#
#   hack/release-index-cms/make-kind-fixtures.sh [out-dir]
#
# Why Apple's service: the macOS CMS decoder trusts a timestamp only from an
# authority the system trusts, and a test cannot add one
# (releaseIndexTimestampAPIBehaviour), so a document only passes
# ReleaseIndexVerifier.verified(p7m:expected:) with a real token. The token is
# RFC 3161 and unauthenticated: the request carries a hash of the throwaway
# signature and no credential, and the token vouches for a time and nothing about
# the signer.
#
# The private keys live in a temporary directory and are removed on exit. No
# keychain item and no real signing identity is used. The shipped verifier does
# not accept these files: its chain must end at an Apple root, and this chain ends
# at test-only-root.cer, which only the verifier's test initializer can be given.
#
# Not in ci.sh: it needs the network, and every run changes every file. It uses
# /usr/bin/openssl (LibreSSL: cms and ts), curl, and der.swift beside it.
set -euo pipefail
cd "$(dirname "$0")/../.."

out="${1:-Tests/K3smInstallTests/Fixtures/test-only-signed-kinds}"
stable=Tests/K3smStatusTests/Fixtures/release-index/index.json
candidate=Tests/K3smStatusTests/Fixtures/release-index-rc/index.json
openssl=/usr/bin/openssl
der=hack/release-index-cms/der.swift
team=ABCDE12345
tsa=http://timestamp.apple.com/ts01

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
empty_config() { printf '[req]\ndistinguished_name=dn\n[dn]\n'; }

"$openssl" req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 7300 \
	-subj "/CN=k3sm TEST ONLY Root CA/O=k3sm Test/C=US" -keyout "$work/root.key" -out "$work/root.pem" \
	-extensions v3 -config <(empty_config; printf '[v3]\nbasicConstraints = critical, CA:true\nkeyUsage = critical, keyCertSign, cRLSign\nsubjectKeyIdentifier = hash\n') 2>/dev/null

# issue <name> <issuer> <subject> <extensions>
issue() {
	printf '%s\nauthorityKeyIdentifier = keyid\nsubjectKeyIdentifier = hash\n' "$4" > "$work/$1.ext"
	"$openssl" req -new -newkey rsa:2048 -nodes -sha256 -subj "$3" -keyout "$work/$1.key" -out "$work/$1.csr" \
		-config <(empty_config) 2>/dev/null
	"$openssl" x509 -req -sha256 -days 3650 -in "$work/$1.csr" -CA "$work/$2.pem" -CAkey "$work/$2.key" \
		-set_serial "0x$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')" -extfile "$work/$1.ext" -out "$work/$1.pem" 2>/dev/null
}
issue intermediate root "/CN=k3sm TEST ONLY Developer ID CA/OU=k3sm Test/O=k3sm Test/C=US" \
	'basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
1.2.840.113635.100.6.2.6 = ASN1:NULL'
issue leaf intermediate "/UID=$team/CN=Developer ID Application: k3sm TEST ONLY ($team)/OU=$team/O=k3sm Test/C=US" \
	'basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
1.2.840.113635.100.6.1.13 = ASN1:NULL'
cat "$work/intermediate.pem" "$work/root.pem" > "$work/chain.pem"

# stamped <content> <out.p7m>: signed by the leaf, with Apple's token over the
# signature value added as an unsigned attribute.
stamped() {
	"$openssl" cms -sign -binary -nodetach -md sha256 -outform DER -signer "$work/leaf.pem" -inkey "$work/leaf.key" \
		-certfile "$work/chain.pem" -in "$1" -out "$work/signed.p7m"
	swift "$der" signature "$work/signed.p7m" "$work/signature.bin"
	"$openssl" ts -query -data "$work/signature.bin" -sha256 -cert -out "$work/query.tsq" 2>/dev/null
	curl -fsS --max-time 30 -H 'Content-Type: application/timestamp-query' --data-binary @"$work/query.tsq" \
		-o "$work/reply.tsr" "$tsa"
	"$openssl" ts -reply -in "$work/reply.tsr" -token_out -out "$work/token.der" 2>/dev/null
	swift "$der" add-token "$work/signed.p7m" "$work/token.der" "$2"
}

rm -rf "$out"
mkdir -p "$out"
stamped "$candidate" "$out/test-only-candidate.p7m"
stamped "$stable" "$out/test-only-stable.p7m"
"$openssl" x509 -in "$work/root.pem" -outform DER -out "$out/test-only-root.cer"
(cd "$out" && shasum -a 256 -- *.p7m *.cer > SHA256SUMS)
ls "$out"
