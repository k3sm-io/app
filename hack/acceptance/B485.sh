#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# B485.sh -- the gate for the status item's menu actions, the login-time
# stopped notification and the tolerant status decoder.
#
#   1. swift test, and the suites and tests this build owns must have run and
#      passed: the lifecycle root script (its literal verbs, a byte-for-byte
#      golden, its refusals run for real, and the cross-check of every verb
#      and flag against the k3sm CLI source, required, never skipped), the
#      preconditions and the driver (a live re-read that refuses a changed
#      state, the Stop warning from the live workers list), feature detection
#      of `k3sm stop`, the installed CLI trust checks, the stopped notice, the
#      tolerant decoder over its unknown-enum fixture, and the bug report
#      collector with its redaction pass
#   2. the unknown-enum fixture is the app's own (not a vendored status_
#      golden) and its words really are unknown to the k3sm source
#   3. the menu's log and bug report actions never start a shell or a process
#   4. the window's model runs the installed CLI only through the
#      trust-checked runner, which checks again before every run
#
# K3SM_DIR names the k3sm checkout whose cmd/k3sm/lifecycle.go and main.go the
# verbs and flags are checked against (default: the sibling ../k3sm). The gate
# fails when it cannot be found. Runs under macOS /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"

K3SM_DIR="${K3SM_DIR:-../k3sm}"
for f in cmd/k3sm/lifecycle.go cmd/k3sm/main.go; do
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
	"lifecycle root script" \
	"lifecycle preconditions" \
	"stop warning" \
	"lifecycle driver" \
	"lifecycle outcome" \
	"installed CLI trust" \
	"trust-checked CLI runs" \
	"lifecycle feature detection" \
	"lifecycle state" \
	"stopped notice" \
	"tolerant enums" \
	"log paths" \
	"bug report collector" \
	"live status commands" \
	"command files"; do
	grep -q "Suite \"$suite\" passed" "$tmp/test.log" || { echo "FAIL: suite \"$suite\" did not run and pass"; exit 1; }
	echo "    passed: $suite"
done

for name in \
	"the verb set is closed: stop, start, restart" \
	"the argv the shell passes" \
	"the stop script, byte for byte" \
	"the command line is a scrubbed environment and the script, with no staging lock" \
	"the lifecycle script never reuses the copy-out" \
	"each refusal stops before the CLI runs" \
	"a user-owned CLI is refused and never executed" \
	"an ACL refuses, with or without the mode's + marker" \
	"a trust verdict going bad after the first check stops the next CLI run" \
	"the driver's re-read goes through the check: trust lost mid-flow runs nothing as root" \
	"a CLI that failed its trust check is left out, never run" \
	"every lifecycle verb and flag passed is one the CLI declares" \
	"stop: live read, confirm with the warning, re-read, then the stop script" \
	"a state changed while the question was open refuses before the prompt" \
	"the warning comes from the live read, not the state the menu showed" \
	"a server with joined workers warns and names them" \
	"an unknown workers list warns" \
	"an older CLI degrades to the window with a note naming its version" \
	"an untrusted CLI is never support, whatever its version" \
	"a report full of unknown enum values decodes" \
	"unknown words land on defined fallbacks" \
	"the title names who stopped k3sm" \
	"it reads only the allowlist" \
	"the redaction pass"; do
	if ! grep -F "Test \"$name\"" "$tmp/test.log" | grep -q "passed"; then
		echo "FAIL: test \"$name\" did not run and pass (CLI source: $K3SM_DIR)"
		exit 1
	fi
	echo "    passed: $name"
done

echo "==> the unknown-enum fixture"
fx="Tests/K3smStatusTests/Fixtures/tolerant-unknown-enums.json"
[ -f "$fx" ] || { echo "FAIL: $fx is missing"; exit 1; }
[ ! -e "$K3SM_DIR/pkg/status/testdata/$(basename "$fx")" ] \
	|| { echo "FAIL: $(basename "$fx") shadows a k3sm golden; it must be the app's own"; exit 1; }
for word in hibernating witness paused scheduler mothballed; do
	grep -q "\"$word\"" "$fx" || { echo "FAIL: $fx lost the unknown word $word"; exit 1; }
	if grep -rqF "\"$word\"" "$K3SM_DIR/pkg/status" "$K3SM_DIR/pkg/install" "$K3SM_DIR/cmd/k3sm"; then
		echo "FAIL: \"$word\" is a word the k3sm source knows, so the fixture no longer proves tolerance"; exit 1
	fi
done
echo "    ok (the app's own, and every enum word in it is unknown to $K3SM_DIR)"

echo "==> the menu's unprivileged actions start no shell"
if grep -nE 'Process\(|/bin/sh|NSAppleScript|do shell script' Sources/K3smApp/MenuActions.swift; then
	echo "FAIL: MenuActions starts a process or a shell; logs open through NSWorkspace and the reports through a .command"
	exit 1
fi
echo "    ok"

echo "==> the window's CLI runs are trust-checked"
n="$(grep -c 'CLIProcess.run(' Sources/K3smApp/AppModel.swift || true)"
[ "$n" = 1 ] || { echo "FAIL: AppModel calls CLIProcess.run $n times; want exactly one, inside the TrustedCLI"; exit 1; }
grep -q 'TrustedCLI(' Sources/K3smApp/AppModel.swift || { echo "FAIL: AppModel does not build a TrustedCLI"; exit 1; }
echo "    ok"

echo "B485: green"
