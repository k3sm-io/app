#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# B571.sh -- the gate for the app's Start action under the CLI's own start
# time bound and its still-cordoned exit.
#
#   1. the Start flow end to end against a fake `k3sm` placed first on PATH:
#      it answers `start --print-time-bound` with 1, sleeps 3 s on its first
#      `start` (past the bound it printed, so a wait of the bound alone would
#      have given up) and exits 1 with the marker, then exits 0. The gate
#      asserts the bound the app read, the retrying text, the final text, and
#      that start was invoked exactly twice. It fails when the re-run does not
#      happen.
#      This run needs the fake in its environment, so it is the one swift
#      test a gate runs beside the shared stream.
#   2. swift test (the stream hack/ci.sh hands every gate, or a run here when
#      the gate runs on its own), and the suites and tests this build owns
#      must have run and passed: the bound parser (a whole number in range, else the fallback
#      of at least 600 s with a reason), the timeout (bound plus 30 s), the
#      marker match on standard error, the one-retry policy and the driver
#      over it, and the deadline race
#
# The fake stands in for what the root step runs once its checks pass; no
# root, no prompt, no installed k3sm is involved. Runs under macOS /bin/bash 3.2.
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

# The fake CLI. Each `start` appends its argv to $K3SM_B571_CALLS; the first
# sleeps and exits still cordoned, every later one succeeds.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/k3sm" <<'FAKE'
#!/bin/sh
case "$*" in
"start --print-time-bound")
	echo 1
	exit 0
	;;
start\ *)
	echo "$*" >> "$K3SM_B571_CALLS"
	n=$(/usr/bin/wc -l < "$K3SM_B571_CALLS" | /usr/bin/tr -d ' ')
	if [ "$n" = 1 ]; then
		/bin/sleep 3
		echo 'k3sm: started the node daemon and netd' >&2
		echo "k3sm: node is still cordoned (re-run 'sudo k3sm start' to uncordon it)" >&2
		exit 1
	fi
	exit 0
	;;
esac
echo "fake k3sm: unexpected arguments: $*" >&2
exit 2
FAKE
chmod 755 "$tmp/bin/k3sm"
: > "$tmp/calls"
export PATH="$tmp/bin:$PATH"
# The app never searches PATH; the gate resolves the fake once and hands the
# test its absolute path, as the app holds K3smCLI.path.
K3SM_B571_FAKE_K3SM="$(command -v k3sm)"
[ "$K3SM_B571_FAKE_K3SM" = "$tmp/bin/k3sm" ] || { echo "FAIL: the fake k3sm is not first on PATH"; exit 1; }
export K3SM_B571_FAKE_K3SM
export K3SM_B571_CALLS="$tmp/calls"
export K3SM_B571_STATE="$tmp/state"

echo "==> the Start flow against the fake k3sm"
status=0
swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} --filter StartFakeCLITests \
	--experimental-event-stream-output "$tmp/flow-events.jsonl" > "$tmp/flow.log" 2>&1 || status=$?
if [ "$status" != 0 ]; then
	failure_names "$tmp/flow-events.jsonl" "$tmp/flow.log" "$tmp/flow-results.tsv"
	tail -n 60 "$tmp/flow.log"
	echo "FAIL: swift test --filter StartFakeCLITests exited $status"
	exit 1
fi
test_results "$tmp/flow-events.jsonl" > "$tmp/flow-results.tsv" || exit 1
suite_passed "$tmp/flow-results.tsv" "start against a fake CLI" \
	|| { echo "FAIL: the Start flow did not run (is the suite still enabled by K3SM_B571_FAKE_K3SM?)"; exit 1; }
flow="Start reads the bound, waits past it, re-runs a cordoned start once, and reports"
test_passed "$tmp/flow-results.tsv" "$flow" || { echo "FAIL: test \"$flow\" did not run and pass"; exit 1; }
[ -s "$tmp/state" ] || { echo "FAIL: the Start flow wrote no state"; exit 1; }
sed 's/^/    | /' "$tmp/state"
calls=$(wc -l < "$tmp/calls" | tr -d ' ')
want_argv="start --actor user --reason from the k3sm app"
grep -qx "bound: 1" "$tmp/state" || { echo "FAIL: the app did not use the bound the CLI printed (1 s)"; exit 1; }
if [ "$calls" != 2 ]; then
	echo "FAIL: start was invoked $calls time(s), want 2 (the automatic re-run did not happen, or happened twice)"
	exit 1
fi
grep -qxF "progress: k3sm started, node not schedulable yet; retrying." "$tmp/state" \
	|| { echo "FAIL: the window never showed the retrying state"; exit 1; }
bad=$(grep -cvxF "$want_argv" "$tmp/calls" || true)
[ "$bad" = 0 ] || { echo "FAIL: a start ran with another argv:"; cat "$tmp/calls"; exit 1; }
grep -qxF "result: k3sm is starting." "$tmp/state" \
	|| { echo "FAIL: the final state is not the started text"; exit 1; }
echo "    ok (start invoked $calls times, first one past the printed bound)"

echo "==> swift test"
# The fake CLI belongs to the flow run above, whose stream already proved the
# fake suite; the whole-suite run reads no fake, standalone or shared.
unset K3SM_B571_FAKE_K3SM K3SM_B571_CALLS K3SM_B571_STATE
# One run of the suite: the stream hack/ci.sh hands every gate, or a run
# here when this gate runs on its own.
app_test_results "$tmp" || exit 1

for suite in "start time bound" "start retry" "lifecycle driver"; do
	suite_passed "$tmp/results.tsv" "$suite" || { echo "FAIL: suite \"$suite\" did not run and pass"; exit 1; }
	echo "    passed: $suite"
done

for name in \
	"parse: a printed whole number in range, else the fallback with a reason" \
	"the fallback is at least ten minutes and the margin is 30 s" \
	"the timeout is the bound plus the margin" \
	"the bound is read with a fixed argument list" \
	"the step after one start run" \
	"a cordoned start is re-run once and then succeeds" \
	"a second cordoned exit shows that state and runs nothing further" \
	"any other exit 1 stays a failed start, not re-run" \
	"stop and restart never read the start bound and never re-run" \
	"the deadline returns nil when the operation runs past it"; do
	if ! test_passed "$tmp/results.tsv" "$name"; then
		echo "FAIL: test \"$name\" did not run and pass"
		exit 1
	fi
	echo "    passed: $name"
done

echo "==> the start argv for the bound is a fixed list in K3smCLI"
grep -qF 'startTimeBoundArguments = ["start", "--print-time-bound"]' Sources/K3smStatus/CLI.swift \
	|| { echo "FAIL: K3smCLI.startTimeBoundArguments is not the fixed list"; exit 1; }
grep -qF 'runCLI(K3smCLI.startTimeBoundArguments)' Sources/K3smApp/AppModel.swift \
	|| { echo "FAIL: the window does not read the bound through the trust-checked runner"; exit 1; }
echo "    ok"

echo "B571: green"
