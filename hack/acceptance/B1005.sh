#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# B1005.sh -- the gate for the versioned /Library/k3sm/k3sm layout. The root
# step's preamble and the app's own check on the installed CLI accept the
# flat root-owned binary, or exactly the chain k3sm -> current/k3sm,
# current -> versions/<version>, and refuse everything else.
#
#   1. swift test, focused on the three chain suites: the root preamble run
#      for real against a layout in a temporary directory, the app-side check
#      over a fake filesystem, and the app-side check on a real layout; each
#      suite and each named test must have run and passed: the flat file
#      still accepted, the full chain accepted, a component not root-owned
#      refused, a component group- or other-writable refused, a chain leaving
#      /Library/k3sm refused, a final target failing the requirement refused,
#      an extra link hop refused, and one version grammar for Swift and shell
#
# No root, no prompt, no installed k3sm is involved. Runs under macOS
# /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"
# shellcheck source=hack/acceptance/lib/test-passed.sh
. hack/acceptance/lib/test-passed.sh

# The Command Line Tools keep the swift-testing macro plugin where SwiftPM
# does not look; ci.sh does the same.
# K3SM_SWIFTPM_DISABLE_SANDBOX=1 adds --disable-sandbox, for a caller already
# inside a sandbox: SwiftPM's own sandbox cannot nest inside another one.
SWIFT_FLAGS=()
if [ "${K3SM_SWIFTPM_DISABLE_SANDBOX:-}" = 1 ]; then
	SWIFT_FLAGS=(--disable-sandbox)
fi
TEST_FLAGS=()
devdir="$(xcode-select -p 2>/dev/null || true)"
plugdir="$devdir/usr/lib/swift/host/plugins/testing"
if [ -n "$devdir" ] && [ -f "$plugdir/libTestingMacros.dylib" ]; then
	TEST_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$plugdir")
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> swift test (the installed CLI's versioned chain)"
# One run of the suite: the stream hack/ci.sh hands every gate, or a run
# here, focused on the three chain suites, when this gate runs on its own.
app_test_results "$tmp" --filter 'InstalledCLIChainTests|InstalledCLITrustChainTests|InstalledCLIChainHostTests' || exit 1

for suite in "installed CLI symlink chain" "installed CLI trust symlink chain" "installed CLI trust on a real chain"; do
	suite_passed "$tmp/results.tsv" "$suite" || { echo "FAIL: suite \"$suite\" did not run and pass"; exit 1; }
	echo "    passed: $suite"
done

for name in \
	"the flat regular file is still accepted" \
	"the full chain is accepted, and the CLI path is the resolved target" \
	"the full chain is accepted, and the signature is checked on the resolved target" \
	"a component not root-owned is refused" \
	"a component group- or other-writable is refused" \
	"a chain leaving /Library/k3sm is refused" \
	"a final target that fails the requirement is refused" \
	"an extra link hop is refused" \
	"a dangling link or an invalid version name is refused" \
	"the Swift and shell version grammars accept and refuse the same names" \
	"production renders root alone and the Developer ID requirement"; do
	if ! test_passed "$tmp/results.tsv" "$name"; then
		echo "FAIL: test \"$name\" did not run and pass"
		exit 1
	fi
	echo "    passed: $name"
done

echo "B1005: green"
