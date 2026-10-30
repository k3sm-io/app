#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# B739.sh -- the gate for Quit and the "Stop k3sm when I quit the app"
# preference. Quit leaves k3sm running by default, as k3s keeps running; the
# preference, off by default, runs the app's Stop action before quitting.
#
#   1. swift test, focused on the quit policy, the preferences and the help
#      catalog, and the tests this build owns must have run and passed: the
#      preference defaults off, and the decision's cases (off: plain quit; on
#      and running: stop then quit; on and already stopped: plain quit; on
#      and the stop fails or is declined: no quit)
#   2. the Quit wiring stays thin: the delegate answers terminateLater, takes
#      its decisions from QuitPolicy, and stops k3sm only through the app's
#      own Stop action (AppModel.perform), never a second path to root
#   3. the toggle is in the General pane with its catalog help tag
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

echo "==> swift test (quit policy, preferences, help catalog)"
# One run of the suite: the stream hack/ci.sh hands every gate, or a run
# here when this gate runs on its own.
app_test_results "$tmp" --filter 'QuitPolicyTests|AppPreferencesTests|HelpCatalogTests' || exit 1

for suite in "quit policy" "the app's preferences"; do
	suite_passed "$tmp/results.tsv" "$suite" || { echo "FAIL: suite \"$suite\" did not run and pass"; exit 1; }
	echo "    passed: $suite"
done

for name in \
	"stop on quit is off by default, kept when set, and reset turns it off" \
	"off: Quit quits whatever k3sm is doing" \
	"on and running: Quit stops k3sm, then quits" \
	"on and already stopped: Quit quits" \
	"on and the status unreadable: the app stays open and says why" \
	"on and the session ending: Quit quits without asking" \
	"the stop succeeded: quit" \
	"the stop failed or was cancelled: no quit, and the message says so" \
	"the stop question answered no: no quit" \
	"the toggle's help tag is in the General catalog" \
	"every preference has its default, a change is kept, and reset puts the defaults back"; do
	if ! test_passed "$tmp/results.tsv" "$name"; then
		echo "FAIL: test \"$name\" did not run and pass"
		exit 1
	fi
	echo "    passed: $name"
done

echo "==> the Quit wiring is thin and goes through the Stop action"
d=Sources/K3smApp/AppDelegate.swift
grep -q 'func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply' "$d" \
	|| { echo "FAIL: the delegate does not answer applicationShouldTerminate"; exit 1; }
grep -q 'return .terminateLater' "$d" || { echo "FAIL: Quit does not wait for the stop (terminateLater)"; exit 1; }
grep -q 'QuitPolicy.decide(' "$d" || { echo "FAIL: the delegate does not decide through QuitPolicy.decide"; exit 1; }
grep -q 'QuitPolicy.afterStop(' "$d" || { echo "FAIL: the delegate does not decide after the stop through QuitPolicy.afterStop"; exit 1; }
grep -q 'model.perform(.stop, expected: .running)' "$d" \
	|| { echo "FAIL: Quit does not stop k3sm through the app's Stop action"; exit 1; }
if grep -qE 'runAsRoot|LifecycleScriptBuilder|RootScript' "$d"; then
	echo "FAIL: the delegate reaches root itself; the Stop action is the only path"
	exit 1
fi
echo "    ok"

echo "==> the toggle is in the General pane with its help tag"
# shellcheck disable=SC2016 # the dollar sign is part of the Swift binding being matched
grep -qF 'Toggle(QuitPolicy.toggleLabel, isOn: $preferences.stopOnQuit)' Sources/K3smApp/GeneralPane.swift \
	|| { echo "FAIL: the General pane has no stop-on-quit toggle"; exit 1; }
grep -q '.help(Help.General.stopOnQuit)' Sources/K3smApp/GeneralPane.swift \
	|| { echo "FAIL: the toggle has no catalog help tag"; exit 1; }
echo "    ok"

echo "B739: green"
