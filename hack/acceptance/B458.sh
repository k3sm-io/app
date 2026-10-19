#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# B458.sh -- the gate for the disk-image install path of k3sm.app.
#
#   1. swift test, and the suites this build owns must have run and passed:
#      the root step argv goldens, including the cross-check of every flag
#      against the k3sm CLI source (required, never skipped), the compiled
#      Team ID pin, the update policy, the stoppedBy decode, the join target,
#      the console user and the uninstall request
#   2. hack/build-app.sh (a developer build): the bundle verifies with
#      codesign --verify --strict --deep and pins no Team ID
#   3. hack/build-app.sh --team-id ABCDE12345: the bundle verifies, the
#      executable carries the pin, Info.plist carries no Team ID, and the
#      checkout's stamp file is untouched; a malformed --team-id is refused
#   4. hack/check-team-pin.sh accepts exactly one exact stamp and refuses a
#      longer suffix, two stamps, two bare markers, the wrong team and none
#
# K3SM_DIR names the k3sm checkout whose cmd/k3sm/install.go the argv is
# checked against (default: the sibling ../k3sm). The gate fails when it
# cannot be found. Runs under macOS /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"
# shellcheck source=hack/acceptance/lib/test-passed.sh
. hack/acceptance/lib/test-passed.sh

K3SM_DIR="${K3SM_DIR:-../k3sm}"
if [ ! -f "$K3SM_DIR/cmd/k3sm/install.go" ]; then
	echo "FAIL: no k3sm CLI source at $K3SM_DIR/cmd/k3sm/install.go; set K3SM_DIR to a k3sm checkout"
	exit 1
fi
K3SM_DIR="$(cd "$K3SM_DIR" && pwd)"
export K3SM_DIR

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

echo "==> swift test"
status=0
swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} \
	--experimental-event-stream-output "$tmp/events.jsonl" > "$tmp/test.log" 2>&1 || status=$?
if [ "$status" != 0 ]; then
	tail -n 60 "$tmp/test.log"
	echo "FAIL: swift test exited $status"
	exit 1
fi
# The verdicts come from the event stream, not from test.log, whose lines
# interleave when tests run in parallel.
test_results "$tmp/events.jsonl" > "$tmp/results.tsv" || exit 1
for suite in "root step argv goldens" "compiled Team ID pin" "update policy" "decode stoppedBy" "worker join target" "console user" "uninstall request"; do
	suite_passed "$tmp/results.tsv" "$suite" || { echo "FAIL: suite \"$suite\" did not run and pass"; exit 1; }
	echo "    passed: $suite"
done
test_passed "$tmp/results.tsv" "every flag passed is one the CLI declares" \
	|| { echo "FAIL: the CLI flag cross-check did not run and pass against $K3SM_DIR"; exit 1; }
echo "    passed: the argv flags are declared by $K3SM_DIR/cmd/k3sm/install.go"

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

echo "==> hack/check-team-pin.sh"
bash hack/check-team-pin.sh "$pinned/Contents/MacOS/k3sm-app" ABCDE12345 > /dev/null \
	|| { echo "FAIL: the pinned executable did not pass the exact pin check"; exit 1; }
echo "    accepted: the --team-id build"
# Fixtures shaped like a binary's string table: NUL-terminated literals,
# written with '|' standing for NUL.
fixture() { printf '%s' "$2" | tr '|' '\000' > "$tmp/pin-$1"; }
fixture exact 'junk|k3sm-team-id-pin:|k3sm-team-id-pin:ABCDE12345|more'
fixture longer 'k3sm-team-id-pin:|k3sm-team-id-pin:ABCDE123456|'
fixture two 'k3sm-team-id-pin:ABCDE12345|k3sm-team-id-pin:ABCDE12345|'
fixture two-teams 'k3sm-team-id-pin:ABCDE12345|k3sm-team-id-pin:ZZZZZ99999|'
fixture two-bare 'k3sm-team-id-pin:|k3sm-team-id-pin:|k3sm-team-id-pin:ABCDE12345|'
fixture wrong 'k3sm-team-id-pin:|k3sm-team-id-pin:ZZZZZ99999|'
fixture punct 'k3sm-team-id-pin:ABCDE12345-x|'
fixture none 'k3sm-team-id-pin:|'
[ "$(LC_ALL=C tr -cd '\000' < "$tmp/pin-exact" | wc -c | tr -d ' ')" = 3 ] \
	|| { echo "FAIL: the pin fixtures are not NUL-separated"; exit 1; }
bash hack/check-team-pin.sh "$tmp/pin-exact" ABCDE12345 > /dev/null \
	|| { echo "FAIL: the pin check refused one exact stamp beside the bare marker"; exit 1; }
echo "    accepted: one exact stamp beside the bare marker"
for case in longer two two-teams two-bare wrong punct none; do
	status=0
	bash hack/check-team-pin.sh "$tmp/pin-$case" ABCDE12345 > "$tmp/pin.log" 2>&1 || status=$?
	[ "$status" = 1 ] || { echo "FAIL: the pin check did not refuse $case (exit $status)"; cat "$tmp/pin.log"; exit 1; }
	echo "    refused: $case"
done
if LC_ALL=C /usr/bin/grep -aqF 'k3sm-team-id-pin:ABCDE12345' "$tmp/pin-longer"; then
	echo "    (an unanchored grep would have accepted the longer suffix)"
fi

echo "B458: green"
