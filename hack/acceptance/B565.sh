#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# B565.sh -- the gate for the LAN record markers and the daemons probe's
# network object.
#
#   1. swift test, and the suites and tests this build owns must have run and
#      passed: the decoder of recordState and appliedReadable (an unknown
#      recordState is unknown, never ok), the daemons probe goldens, the
#      checkbox for an unreadable record (off, with the note naming the lan
#      command), the probe as the freshest source at the poll rate, an absent
#      network object still reading as on with no setting recorded, and the
#      cross-check of the status fields against the k3sm CLI source (required,
#      never skipped)
#   2. the new k3sm goldens are vendored byte for byte
#   3. the poller's result reaches the model through one call, and the model
#      chooses its source through LANSource
#   4. the B553 rules still stand: the closed verb set and the confirmation
#      tests are asserted by B553.sh, which this gate runs
#
# K3SM_DIR names the k3sm checkout whose pkg/status and testdata the fields
# and fixtures are checked against (default: the sibling ../k3sm). The gate
# fails when it cannot be found. Runs under macOS /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"

K3SM_DIR="${K3SM_DIR:-../k3sm}"
for f in cmd/k3sm/main.go cmd/k3sm/lifecycle.go cmd/k3sm/network.go pkg/install/networklan.go pkg/status/network.go pkg/status/daemons.go pkg/status/report.go; do
	if [ ! -f "$K3SM_DIR/$f" ]; then
		echo "FAIL: no k3sm CLI source at $K3SM_DIR/$f; set K3SM_DIR to a k3sm checkout"
		exit 1
	fi
done
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
swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} > "$tmp/test.log" 2>&1 || status=$?
if [ "$status" != 0 ]; then
	tail -n 60 "$tmp/test.log"
	echo "FAIL: swift test exited $status"
	exit 1
fi

for suite in \
	"LAN access decoder" \
	"LAN record and probe" \
	"LAN checkbox" \
	"LAN root script"; do
	grep -q "Suite \"$suite\" passed" "$tmp/test.log" || { echo "FAIL: suite \"$suite\" did not run and pass"; exit 1; }
	echo "    passed: $suite"
done

for name in \
	"an unreadable record decodes as off, recorded, with the record state" \
	"an unknown or mistyped recordState is unknown, never ok" \
	"appliedReadable false decodes, and an absent or mistyped value is not said" \
	"the daemons probe goldens carry the network object" \
	"an unreadable record shows off with a note naming the lan command" \
	"an unknown record state disables the checkbox and drives nothing" \
	"an applied state only an administrator can read is noted" \
	"a status with no network object still reads as on, no setting recorded" \
	"the unreadable record golden shows off with the note, from the full report and from the probe" \
	"the newer read drives the checkbox, whichever kind it is" \
	"a probe keeps the checkbox fresh past the full read's age limit" \
	"a change made in Terminal reaches the checkbox and the dot at the probe's rate" \
	"the full read's applied state rides a newer probe only while they agree" \
	"an unknown record state in the live status refuses before the prompt" \
	"every LAN verb and status field the app uses is one the CLI declares"; do
	if ! grep -F "Test \"$name\"" "$tmp/test.log" | grep -q "passed"; then
		echo "FAIL: test \"$name\" did not run and pass (CLI source: $K3SM_DIR)"
		exit 1
	fi
	echo "    passed: $name"
done

echo "==> the new k3sm goldens are vendored byte for byte"
golden="$K3SM_DIR/pkg/status/testdata"
n=0
for g in "$golden"/status_json_network-*.json "$golden"/status_daemons_json_network-*.json; do
	[ -f "$g" ] || { echo "FAIL: no k3sm network golden matches in $golden"; exit 1; }
	copy="Tests/K3smStatusTests/Fixtures/$(basename "$g")"
	[ -f "$copy" ] || { echo "FAIL: $copy is not vendored"; exit 1; }
	cmp -s "$g" "$copy" || { echo "FAIL: $copy differs from $g"; exit 1; }
	n=$((n + 1))
done
[ "$n" -ge 8 ] || { echo "FAIL: only $n network goldens found in $golden; want at least 8"; exit 1; }
echo "    ok ($n goldens)"

echo "==> the poller's result feeds the checkbox through the model"
grep -q 'model.noteProbe(report)' Sources/K3smApp/StatusItemController.swift \
	|| { echo "FAIL: the status item does not pass the probe result to the model"; exit 1; }
grep -q 'LANSource.choose(' Sources/K3smApp/AppModel.swift \
	|| { echo "FAIL: the model does not choose its LAN source through LANSource"; exit 1; }
echo "    ok"

echo "==> B553 still holds"
bash hack/acceptance/B553.sh > "$tmp/b553.log" 2>&1 || { tail -n 30 "$tmp/b553.log"; echo "FAIL: B553.sh"; exit 1; }
echo "    ok"

echo "B565: green"
