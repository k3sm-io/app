#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# B486.sh -- the gate for the server menu's Copy Join Command.
#
#   1. swift test, and the suites and tests this build owns must have run and
#      passed: the mint (a 15-minute TTL from one constant, `token create
#      --ttl 15m` and never --server, a byte-for-byte golden, the same
#      installed-CLI checks as the lifecycle script, a failed mint printing
#      nothing, and the cross-check against cmd/k3sm/token.go, required, never
#      skipped); the token grammar and its redaction; the copied text (a
#      golden, read back through a shell, and cross-checked against
#      cmd/k3sm/install.go and docs/user/multi-node.md); the join address
#      table; the gating table; the pasteboard flags and clear semantics; and
#      the sentinel token, which reaches the pasteboard and nothing else
#   2. the new files never start a process, a shell, osascript or pbcopy;
#      the mint goes through the one PrivilegedRunner implementation
#   3. the mint argv carries no --server; the TTL is defined once
#   4. the pasteboard adapter declares the concealed type and prepares the
#      write for this Mac only; the app clears an unchanged item at quit
#
# K3SM_DIR names the k3sm checkout the CLI contract is checked against
# (default: the sibling ../k3sm). The gate fails when it cannot be found.
# Runs under macOS /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"

K3SM_DIR="${K3SM_DIR:-../k3sm}"
for f in cmd/k3sm/token.go cmd/k3sm/main.go cmd/k3sm/install.go cmd/k3sm/lifecycle.go \
	pkg/bootstrap/token.go docs/user/multi-node.md; do
	if [ ! -f "$K3SM_DIR/$f" ]; then
		echo "FAIL: no k3sm source at $K3SM_DIR/$f; set K3SM_DIR to a k3sm checkout"
		exit 1
	fi
done
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

for suite in \
	"join token mint" \
	"join token grammar" \
	"join command text" \
	"join address" \
	"copy join gating" \
	"concealed clipboard" \
	"copy join driver" \
	"leftover sweep" \
	"lifecycle root script"; do
	grep -q "Suite \"$suite\" passed" "$tmp/test.log" || { echo "FAIL: suite \"$suite\" did not run and pass"; exit 1; }
	echo "    passed: $suite"
done

for name in \
	"the TTL is 15 minutes, one constant" \
	"the argv is token create --ttl 15m, never --server" \
	"the mint script, byte for byte" \
	"the mint script carries the same checks as the lifecycle script" \
	"the mint script refuses a user-owned CLI and never runs it" \
	"a failed mint prints nothing on standard output" \
	"the mint's verb and flag are ones the CLI declares" \
	"the join command's flags and file are the documented ones" \
	"a minted token passes" \
	"anything else is refused" \
	"the token never prints through description or reflection" \
	"redaction removes anything token-shaped" \
	"the copied text, byte for byte" \
	"the shell reads the token from stdin and runs the documented install" \
	"the underlay address choice" \
	"the gating table" \
	"the menu and result notes name the lifetime, the concealment and the history" \
	"one write declares the string and concealed types, this Mac only" \
	"the baseline is the count the write returned, never a later read" \
	"59 s present, 60 s cleared when unchanged" \
	"a sleep past the deadline clears on the first fire after it" \
	"a foreign copy is left alone" \
	"a second use cancels the first timer and re-baselines" \
	"quit clears an unchanged item, and only that" \
	"the token reaches the pasteboard and nothing else" \
	"a failed mint's error text never carries the token, and nothing is copied" \
	"output that is not a token copies nothing" \
	"a role changed to worker refuses before any prompt" \
	"a stopped server, an unreadable status or no address refuses before any prompt" \
	"each click reads, prompts and mints anew" \
	"two rapid invocations mint exactly once" \
	"only this app's own concealed join command is swept" \
	"the line this app writes is recognised, byte for byte" \
	"the stop script, byte for byte"; do
	if ! grep -F "Test \"$name\"" "$tmp/test.log" | grep -q "passed"; then
		echo "FAIL: test \"$name\" did not run and pass (CLI source: $K3SM_DIR)"
		exit 1
	fi
	echo "    passed: $name"
done

new_install="Sources/K3smInstall/JoinTokenMint.swift Sources/K3smInstall/JoinAddress.swift Sources/K3smInstall/ConcealedClipboard.swift Sources/K3smInstall/CopyJoinCommand.swift"
new_app="Sources/K3smApp/GeneralPasteboard.swift Sources/K3smApp/WallClockClearScheduler.swift Sources/K3smApp/InterfaceAddressSource.swift"

echo "==> the new files start no process, shell, osascript or pbcopy"
# shellcheck disable=SC2086
if grep -nE 'pbcopy|osascript|Process\(|NSAppleScript|do shell script|posix_spawn|system\(' $new_install $new_app; then
	echo "FAIL: Copy Join Command spawns something; the token goes through the one runner and NSPasteboard only"
	exit 1
fi
if grep -nE 'pbcopy|osascript' Sources/K3smApp/AppModel.swift Sources/K3smApp/StatusItemController.swift Sources/K3smApp/AppleScriptRunner.swift; then
	echo "FAIL: the app mentions pbcopy or osascript"
	exit 1
fi
echo "    ok"

echo "==> exactly one PrivilegedRunner implementation"
n="$(grep -rlE '(struct|class|actor) [A-Za-z]+: *([A-Za-z.]+, *)*PrivilegedRunner' Sources | wc -l | tr -d ' ')"
[ "$n" = 1 ] || { echo "FAIL: $n PrivilegedRunner implementations in Sources; want 1"; exit 1; }
grep -q 'func runAsRootCapturingOutput' Sources/K3smApp/AppleScriptRunner.swift \
	|| { echo "FAIL: the AppleScript runner has no capturing method"; exit 1; }
grep -q 'capturedOutputLimit' Sources/K3smApp/AppleScriptRunner.swift \
	|| { echo "FAIL: the capturing method is not bounded"; exit 1; }
echo "    ok"

echo "==> the mint argv and TTL"
if grep -nE '"--server"' Sources/K3smInstall/JoinTokenMint.swift; then
	echo "FAIL: the mint names --server"
	exit 1
fi
n="$(grep -c 'static let ttl' Sources/K3smInstall/JoinTokenMint.swift || true)"
[ "$n" = 1 ] || { echo "FAIL: the TTL is defined $n times; want one constant"; exit 1; }
if grep -rnE '15 ?m(in|"|\b)' Sources --include='*.swift' | grep -v 'JoinTokenMint.swift'; then
	echo "FAIL: a 15-minute literal outside JoinTokenMint; derive it from JoinTokenMint.ttl"
	exit 1
fi
echo "    ok"

echo "==> the pasteboard adapter"
grep -q 'org.nspasteboard.ConcealedType' Sources/K3smInstall/ConcealedClipboard.swift \
	|| { echo "FAIL: no concealed type"; exit 1; }
grep -q 'prepareForNewContents(with: prepare)' Sources/K3smApp/GeneralPasteboard.swift || { echo "FAIL: the write is not prepared"; exit 1; }
grep -q 'prepare.insert(.currentHostOnly)' Sources/K3smApp/GeneralPasteboard.swift || { echo "FAIL: the write is not this-Mac-only"; exit 1; }
grep -q 'asyncAfter(wallDeadline:' Sources/K3smApp/WallClockClearScheduler.swift || { echo "FAIL: the clear does not use a wall-clock deadline"; exit 1; }
grep -q 'ConcealedClipboard.sweepLeftover(GeneralPasteboard())' Sources/K3smApp/AppDelegate.swift \
	|| { echo "FAIL: the app does not sweep a leftover join command at launch"; exit 1; }
grep -q 'running = true' <(sed -n '/func copyJoinCommand()/,/Task {/p' Sources/K3smApp/AppModel.swift) \
	|| { echo "FAIL: copyJoinCommand does not claim running before its Task"; exit 1; }
grep -q 'joinClipboard.clearIfUnchanged()' Sources/K3smApp/AppDelegate.swift \
	|| { echo "FAIL: the app does not clear the item at quit"; exit 1; }
echo "    ok"

echo "B486: green"
