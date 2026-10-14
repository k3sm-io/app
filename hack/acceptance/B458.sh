#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# B458.sh -- the gate for the disk-image install path of k3sm.app.
#
#   1. swift test, and the four suites this build owns must have run and
#      passed: the root step argv goldens (pinned against the k3sm CLI's
#      install and uninstall flags), the compiled Team ID pin, the update
#      policy, and the stoppedBy decode
#   2. hack/build-app.sh (a developer build): the bundle verifies with
#      codesign --verify --strict --deep and pins no Team ID
#   3. hack/build-app.sh --team-id ABCDE12345: the bundle verifies, the
#      executable carries the pin, Info.plist carries no Team ID, and the
#      checkout's stamp file is untouched; a malformed --team-id is refused
#
# K3SM_DIR names a k3sm checkout for the argv golden's flag cross-check
# (default: a sibling ../k3sm when present). Runs under macOS /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"

if [ -z "${K3SM_DIR:-}" ] && [ -f ../k3sm/cmd/k3sm/install.go ]; then
	K3SM_DIR="$(cd ../k3sm && pwd)"
	export K3SM_DIR
fi

# The Command Line Tools keep the swift-testing macro plugin where SwiftPM
# does not look; ci.sh does the same.
TEST_FLAGS=()
devdir="$(xcode-select -p 2>/dev/null || true)"
plugdir="$devdir/usr/lib/swift/host/plugins/testing"
if [ -n "$devdir" ] && [ -f "$plugdir/libTestingMacros.dylib" ]; then
	TEST_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$plugdir")
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> swift test"
status=0
swift test ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} > "$tmp/test.log" 2>&1 || status=$?
if [ "$status" != 0 ]; then
	tail -n 60 "$tmp/test.log"
	echo "FAIL: swift test exited $status"
	exit 1
fi
for suite in "root step argv goldens" "compiled Team ID pin" "update policy" "decode stoppedBy" "worker join target" "console user"; do
	grep -q "Suite \"$suite\" passed" "$tmp/test.log" || { echo "FAIL: suite \"$suite\" did not run and pass"; exit 1; }
	echo "    passed: $suite"
done
if [ -n "${K3SM_DIR:-}" ]; then
	grep -q 'Test "every flag passed is one the CLI declares" passed' "$tmp/test.log" \
		|| { echo "FAIL: the CLI flag cross-check did not run against $K3SM_DIR"; exit 1; }
	echo "    passed: the argv flags are declared by $K3SM_DIR/cmd/k3sm/install.go"
else
	echo "    skipped: the CLI flag cross-check (no k3sm checkout; set K3SM_DIR)"
fi

pin_re='k3sm-team-id-pin:[A-Z0-9]{10}'

echo "==> hack/build-app.sh (developer build)"
bash hack/build-app.sh "$tmp/dev" > "$tmp/dev.log" 2>&1 || { tail -n 40 "$tmp/dev.log"; echo "FAIL: build-app.sh"; exit 1; }
dev="$tmp/dev/k3sm.app"
codesign --verify --strict --deep "$dev" || { echo "FAIL: the developer bundle does not verify"; exit 1; }
if LC_ALL=C grep -aqE "$pin_re" "$dev/Contents/MacOS/k3sm-app"; then
	echo "FAIL: a developer build carries a Team ID pin"; exit 1
fi
if plutil -extract K3smTeamID raw "$dev/Contents/Info.plist" > /dev/null 2>&1; then
	echo "FAIL: Info.plist carries K3smTeamID"; exit 1
fi
echo "    ok (verifies, no Team ID pin, no Info.plist Team ID)"

echo "==> hack/build-app.sh --team-id ABCDE12345"
stamp_before="$(cat Sources/K3smInstall/TeamIDStamp.swift)"
bash hack/build-app.sh --team-id ABCDE12345 "$tmp/pinned" > "$tmp/pinned.log" 2>&1 \
	|| { tail -n 40 "$tmp/pinned.log"; echo "FAIL: build-app.sh --team-id"; exit 1; }
pinned="$tmp/pinned/k3sm.app"
codesign --verify --strict --deep "$pinned" || { echo "FAIL: the pinned bundle does not verify"; exit 1; }
LC_ALL=C grep -aqF 'k3sm-team-id-pin:ABCDE12345' "$pinned/Contents/MacOS/k3sm-app" \
	|| { echo "FAIL: the pinned executable does not carry k3sm-team-id-pin:ABCDE12345"; exit 1; }
if plutil -extract K3smTeamID raw "$pinned/Contents/Info.plist" > /dev/null 2>&1; then
	echo "FAIL: Info.plist carries K3smTeamID"; exit 1
fi
[ "$(cat Sources/K3smInstall/TeamIDStamp.swift)" = "$stamp_before" ] \
	|| { echo "FAIL: build-app.sh --team-id modified the checkout's stamp file"; exit 1; }
echo "    ok (verifies, pin compiled in, checkout untouched)"

status=0
bash hack/build-app.sh --team-id 'abcde12345' "$tmp/bad" > "$tmp/bad.log" 2>&1 || status=$?
[ "$status" = 2 ] && grep -q 'refused' "$tmp/bad.log" && [ ! -e "$tmp/bad/k3sm.app" ] \
	|| { echo "FAIL: a malformed --team-id was not refused (exit $status)"; cat "$tmp/bad.log"; exit 1; }
echo "    refused: a malformed --team-id"

echo "B458: green"
