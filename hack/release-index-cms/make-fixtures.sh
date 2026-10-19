#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# make-fixtures.sh -- writes the signed release index fixtures the
# ReleaseIndexVerifier tests read, all under throwaway test roots made here.
# Nothing in them is an Apple certificate or a real Developer ID: a test
# chain shaped like one (the Developer ID intermediate and leaf marker
# extensions, a code signing leaf whose subject OU is the test Team ID) and a
# test timestamp authority. The tests inject these roots through the
# verifier's test initializer; the shipped verifier never trusts them.
#
#   hack/release-index-cms/make-fixtures.sh [out-dir]
#
# out-dir defaults to Tests/K3smInstallTests/Fixtures/release-index-cms. The
# signed documents are the vendored release index corpus
# (Tests/K3smStatusTests/Fixtures/release-index). It uses /usr/bin/openssl
# (LibreSSL: cms and ts) and der.swift beside it for the two CMS edits
# openssl has no command for. Every run makes new keys, so every file
# changes; commit them together.
#
# One fixture, the expired leaf, is valid for EXPIRED_LEAF_SECONDS from the
# moment it is made: it is signed and timestamped inside that window and has
# expired by the time the tests run. The helpers below (make_root, make_cert,
# sign, timestamp) are kept separate so another fake signer can reuse them.
set -euo pipefail
cd "$(dirname "$0")/../.."

out="${1:-Tests/K3smInstallTests/Fixtures/release-index-cms}"
corpus=Tests/K3smStatusTests/Fixtures/release-index
openssl=/usr/bin/openssl
der="hack/release-index-cms/der.swift"
team=ABCDE12345
EXPIRED_LEAF_SECONDS=120

[ -f "$corpus/index.json" ] || { echo "make-fixtures: no $corpus/index.json" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# make_root <name> <subject>: a self-signed CA certificate and key.
make_root() {
	cat > "$work/$1.ext" <<EXT
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EXT
	"$openssl" req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 7300 \
		-subj "$2" -keyout "$work/$1.key" -out "$work/$1.pem" \
		-extensions v3 -config <(printf '[req]\ndistinguished_name=dn\n[dn]\n[v3]\n'; cat "$work/$1.ext") 2>/dev/null
}

# make_cert <name> <issuer> <subject> <extensions> [startdate enddate]: a
# certificate for a new key, issued by <issuer>, with the extensions given as
# config lines. With dates (YYMMDDHHMMSSZ), it is valid exactly then.
make_cert() {
	local name="$1" issuer="$2" subject="$3" ext="$4"
	printf '%s\nauthorityKeyIdentifier = keyid\nsubjectKeyIdentifier = hash\n' "$ext" > "$work/$name.ext"
	"$openssl" req -new -newkey rsa:2048 -nodes -sha256 -subj "$subject" \
		-keyout "$work/$name.key" -out "$work/$name.csr" \
		-config <(printf '[req]\ndistinguished_name=dn\n[dn]\n') 2>/dev/null
	if [ $# -ge 6 ]; then
		local ca="$work/ca-$name"
		mkdir -p "$ca/new"
		: > "$ca/index.txt"
		echo 1000 > "$ca/serial"
		cat > "$ca/ca.cnf" <<CNF
[ca]
default_ca = test
[test]
dir = $ca
database = $ca/index.txt
new_certs_dir = $ca/new
serial = $ca/serial
certificate = $work/$issuer.pem
private_key = $work/$issuer.key
default_md = sha256
policy = any
email_in_dn = no
preserve = yes
unique_subject = no
[any]
commonName = supplied
CNF
		"$openssl" ca -batch -config "$ca/ca.cnf" -notext -preserveDN \
			-startdate "$5" -enddate "$6" -extfile "$work/$name.ext" \
			-in "$work/$name.csr" -out "$work/$name.pem" 2>/dev/null
	else
		"$openssl" x509 -req -sha256 -days 3650 -in "$work/$name.csr" \
			-CA "$work/$issuer.pem" -CAkey "$work/$issuer.key" -set_serial "0x$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')" \
			-extfile "$work/$name.ext" -out "$work/$name.pem" 2>/dev/null
	fi
}

# sign <content> <leaf> <chain-pem> <out.p7m> [detached]: CMS SignedData,
# sha256, with the signer's certificates; attached content unless detached.
sign() {
	local attach=-nodetach
	[ "${5:-}" = detached ] && attach=
	# shellcheck disable=SC2086 # $attach is one flag or none
	"$openssl" cms -sign -binary $attach -md sha256 -outform DER \
		-signer "$work/$2.pem" -inkey "$work/$2.key" -certfile "$3" \
		-in "$1" -out "$4"
}

# timestamp <in.p7m> <tsa> <tsa-chain-pem> <out.p7m>: asks the test timestamp
# authority <tsa> for an RFC 3161 token over signer 0's signature value and
# adds it to signer 0 as an unsigned attribute.
timestamp() {
	token "$1" "$2" "$3" "$work/token.der"
	swift "$der" add-token "$1" "$work/token.der" "$4"
}

# token <in.p7m> <tsa> <tsa-chain-pem> <out.der>: the token alone.
token() {
	swift "$der" signature "$1" "$work/signature.bin"
	"$openssl" ts -query -data "$work/signature.bin" -sha256 -cert -out "$work/query.tsq" 2>/dev/null
	echo 01 > "$work/tsa-serial"
	cat > "$work/tsa.cnf" <<CNF
[tsa]
default_tsa = test
[test]
serial = $work/tsa-serial
signer_cert = $work/$2.pem
signer_key = $work/$2.key
certs = $3
default_policy = 1.3.6.1.4.1.99999.1
digests = sha256
accuracy = secs:1
ordering = no
tsa_name = no
ess_cert_id_chain = no
CNF
	"$openssl" ts -reply -config "$work/tsa.cnf" -queryfile "$work/query.tsq" -token_out -out "$4" 2>/dev/null
}

leaf_ext() {
	# $1: extended key usage; $2: the leaf marker line or nothing.
	printf 'basicConstraints = critical, CA:false\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = critical, %s\n%s' "$1" "$2"
}
leaf_marker='1.2.840.113635.100.6.1.13 = ASN1:NULL'
intermediate_ext='basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign'
leaf_subject() {
	echo "/UID=$1/CN=Developer ID Application: k3sm Test ($1)/OU=$1/O=k3sm Test/C=US"
}

echo "==> test roots and chains"
make_root root "/CN=k3sm Test Root CA/O=k3sm Test/C=US"
make_root other-root "/CN=k3sm Other Test Root CA/O=k3sm Test/C=US"
make_root tsa-root "/CN=k3sm Test Timestamp Root/O=k3sm Test/C=US"
make_root tsa-other-root "/CN=k3sm Untrusted Timestamp Root/O=k3sm Test/C=US"
make_cert intermediate root "/CN=k3sm Test Developer ID CA/OU=k3sm Test/O=k3sm Test/C=US" \
	"$intermediate_ext
1.2.840.113635.100.6.2.6 = ASN1:NULL"
make_cert intermediate-unmarked root "/CN=k3sm Test Unmarked CA/OU=k3sm Test/O=k3sm Test/C=US" "$intermediate_ext"
# A chain of four: the marked intermediate under one more CA.
make_cert middle root "/CN=k3sm Test Middle CA/OU=k3sm Test/O=k3sm Test/C=US" \
	'basicConstraints = critical, CA:true, pathlen:1
keyUsage = critical, keyCertSign, cRLSign'
make_cert intermediate-long middle "/CN=k3sm Test Developer ID CA 2/OU=k3sm Test/O=k3sm Test/C=US" \
	"$intermediate_ext
1.2.840.113635.100.6.2.6 = ASN1:NULL"
make_cert leaf-long intermediate-long "$(leaf_subject $team)" "$(leaf_ext codeSigning "$leaf_marker")"
make_cert leaf intermediate "$(leaf_subject $team)" "$(leaf_ext codeSigning "$leaf_marker")"
make_cert leaf-other-ou intermediate "$(leaf_subject ZYXWV98765)" "$(leaf_ext codeSigning "$leaf_marker")"
make_cert leaf-two-ou intermediate "/UID=$team/CN=Developer ID Application: k3sm Test ($team)/OU=$team/OU=$team/O=k3sm Test/C=US" \
	"$(leaf_ext codeSigning "$leaf_marker")"
make_cert leaf-unmarked intermediate "$(leaf_subject $team)" "$(leaf_ext codeSigning "")"
make_cert leaf-email intermediate "$(leaf_subject $team)" "$(leaf_ext emailProtection "$leaf_marker")"
make_cert leaf-under-unmarked intermediate-unmarked "$(leaf_subject $team)" "$(leaf_ext codeSigning "$leaf_marker")"
now=$(date -u +%s)
make_cert leaf-expired intermediate "$(leaf_subject $team)" "$(leaf_ext codeSigning "$leaf_marker")" \
	"$(date -u -r $((now - 86400)) +%y%m%d%H%M%SZ)" "$(date -u -r $((now + EXPIRED_LEAF_SECONDS)) +%y%m%d%H%M%SZ)"
make_cert tsa tsa-root "/CN=k3sm Test Timestamp Authority/O=k3sm Test/C=US" \
	'basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, timeStamping'
make_cert tsa-other tsa-other-root "/CN=k3sm Untrusted Timestamp Authority/O=k3sm Test/C=US" \
	'basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, timeStamping'

cat "$work/intermediate.pem" "$work/root.pem" > "$work/chain.pem"
cat "$work/intermediate-unmarked.pem" "$work/root.pem" > "$work/chain-unmarked.pem"
cat "$work/intermediate-long.pem" "$work/middle.pem" "$work/root.pem" > "$work/chain-long.pem"
cat "$work/tsa.pem" "$work/tsa-root.pem" > "$work/tsa-chain.pem"
cat "$work/tsa-other.pem" "$work/tsa-other-root.pem" > "$work/tsa-other-chain.pem"
printf 'This is not a release index.\n' > "$work/not-an-index.txt"

rm -rf "$out"
mkdir -p "$out"

# stamped <name> <content> <leaf> <chain>: signed and timestamped by the
# test authority.
stamped() {
	sign "$2" "$3" "$4" "$work/$1.unstamped.p7m"
	timestamp "$work/$1.unstamped.p7m" tsa "$work/tsa-chain.pem" "$out/$1.p7m"
}

# The macOS CMS decoder trusts a timestamp only from an authority the system
# trusts, and a test cannot add one, so every test-authority timestamp reads
# as not trusted and turns the signer status invalid. The timestamped files
# below pin that behaviour and the refusals it allows. The chain and content
# variants are signed without a timestamp: their signer status is valid, so
# the tests can run the chain and content checks on them at a chosen time.
echo "==> signed documents"
stamped index-timestamped "$corpus/index.json" leaf "$work/chain.pem"
sign "$corpus/index.json" leaf "$work/chain.pem" "$out/index-untimestamped.p7m"
sign "$corpus/index.json" leaf "$work/chain.pem" "$work/u.p7m"
timestamp "$work/u.p7m" tsa-other "$work/tsa-other-chain.pem" "$out/index-untrusted-timestamp.p7m"
# A genuine token from the trusted test authority, issued over another
# signature (the same identity signing another document), moved onto this one.
sign "$work/not-an-index.txt" leaf "$work/chain.pem" "$work/donor.p7m"
token "$work/donor.p7m" tsa "$work/tsa-chain.pem" "$work/donor-token.der"
swift "$der" add-token "$out/index-untimestamped.p7m" "$work/donor-token.der" "$out/index-moved-timestamp.p7m"
sign "$corpus/index.json" leaf "$work/chain.pem" "$work/d.p7m" detached
timestamp "$work/d.p7m" tsa "$work/tsa-chain.pem" "$out/index-detached.p7m"
"$openssl" cms -sign -binary -nodetach -md sha256 -outform DER \
	-signer "$work/leaf.pem" -inkey "$work/leaf.key" \
	-signer "$work/leaf-other-ou.pem" -inkey "$work/leaf-other-ou.key" \
	-certfile "$work/chain.pem" -in "$corpus/index.json" -out "$out/index-two-signers.p7m"
swift "$der" drop-signers "$out/index-untimestamped.p7m" "$out/index-no-signers.p7m"
stamped index-expired-leaf-timestamped "$corpus/index.json" leaf-expired "$work/chain.pem"
sign "$corpus/index.json" leaf-expired "$work/chain.pem" "$out/index-expired-leaf-untimestamped.p7m"
sign "$corpus/index.json" leaf-other-ou "$work/chain.pem" "$out/index-other-ou.p7m"
sign "$corpus/index.json" leaf-two-ou "$work/chain.pem" "$out/index-two-ou.p7m"
sign "$corpus/index.json" leaf-unmarked "$work/chain.pem" "$out/index-no-leaf-marker.p7m"
sign "$corpus/index.json" leaf-under-unmarked "$work/chain-unmarked.pem" "$out/index-no-intermediate-marker.p7m"
sign "$corpus/index.json" leaf-email "$work/chain.pem" "$out/index-no-codesigning-usage.p7m"
sign "$corpus/index.json" leaf-long "$work/chain-long.pem" "$out/index-long-chain.p7m"
sign "$corpus/red-no-context.json" leaf "$work/chain.pem" "$out/no-context.p7m"
sign "$corpus/red-other-context.json" leaf "$work/chain.pem" "$out/other-context.p7m"
sign "$work/not-an-index.txt" leaf "$work/chain.pem" "$out/not-an-index.p7m"

echo "==> roots and the expired leaf"
for c in root other-root tsa-root tsa-other-root leaf-expired; do
	"$openssl" x509 -in "$work/$c.pem" -outform DER -out "$out/$c.cer"
done
(cd "$out" && shasum -a 256 -- *.p7m *.cer > SHA256SUMS)
ls "$out"
