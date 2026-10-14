#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# B563.sh -- the gate for the app's use of the CLI's purge --user, the status
# workers list and the status join target.
#
# swift test must pass, and the suites and tests this build owns must have run
# and passed:
#   - the argv goldens, with the purge argv carrying --user, and the
#     cross-check of every flag against the k3sm CLI source (required)
#   - the update policy over workers (unknown never satisfies the minimum)
#   - the status decode of workers and joinTarget, against the vendored
#     server-with-workers and agent-join-target fixtures
#   - the worker join target resolution (status field first, plist fallback)
#   - the uninstall request, with no purge gate left in the sources
#
# K3SM_DIR names the k3sm checkout whose cmd/k3sm/install.go the argv is
# checked against (default: the sibling ../k3sm). The gate fails when it
# cannot be found. Runs under macOS /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"

K3SM_DIR="${K3SM_DIR:-../k3sm}"
if [ ! -f "$K3SM_DIR/cmd/k3sm/install.go" ]; then
	echo "FAIL: no k3sm CLI source at $K3SM_DIR/cmd/k3sm/install.go; set K3SM_DIR to a k3sm checkout"
	exit 1
fi
K3SM_DIR="$(cd "$K3SM_DIR" && pwd)"
export K3SM_DIR

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

for suite in "root step argv goldens" "update policy" "decode workers and join target" "worker join target" "uninstall request"; do
	grep -q "Suite \"$suite\" passed" "$tmp/test.log" || { echo "FAIL: suite \"$suite\" did not run and pass"; exit 1; }
	echo "    passed: $suite"
done

for name in \
	"a purge names the console user, because env -i strips SUDO_USER" \
	"no purge-unavailable gate remains anywhere in the sources" \
	"a server with workers carries their names, roles and versions" \
	"an agent carries the join target" \
	"the status joinTarget wins and drops the port" \
	"the plist is read only when the field is absent" \
	"the k3sm release is the +k3sm. build metadata, never the Kubernetes version" \
	"decide" \
	"every flag passed is one the CLI declares"; do
	if ! grep -F "Test \"$name\"" "$tmp/test.log" | grep -q "passed"; then
		echo "FAIL: test \"$name\" did not run and pass (CLI source: $K3SM_DIR)"
		exit 1
	fi
	echo "    passed: $name"
done

# The vendored fixtures must still match the CLI's own goldens.
for f in status_json_server-with-workers.json status_json_agent-join-target.json; do
	src="$K3SM_DIR/pkg/status/testdata/$f"
	[ -f "$src" ] || { echo "FAIL: $src is missing from the k3sm checkout"; exit 1; }
	cmp -s "$src" "Tests/K3smStatusTests/Fixtures/$f" \
		|| { echo "FAIL: Tests/K3smStatusTests/Fixtures/$f differs from the CLI golden $src"; exit 1; }
	echo "    matches the CLI golden: $f"
done

echo "B563: green"
