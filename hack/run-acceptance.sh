#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# run-acceptance.sh -- runs every hack/acceptance/B<n>.sh gate and reports
# each one's verdict by name. hack/ci.sh calls it (ci.sh --acceptance runs
# only this stage).
#
#   pass         the script exited 0
#   lab-pending  the script exited 3 AND printed LAB-PENDING: it cannot run
#                here (it needs an installed node, a GUI session or root) and
#                says so. It is named in the summary and is never a pass.
#   fail         anything else, including exit 3 without LAB-PENDING and
#                LAB-PENDING with any other exit code, so a gate cannot
#                drift into pending by accident
#
# A gate that cannot run hermetically declares it itself, before doing any
# work:
#
#   echo "B<n> gate: LAB-PENDING: not a pass (<what it needs>)" >&2
#   exit 3
#
# The runner exits 1 on any failure and when it finds no gate at all (a run
# over nothing proves nothing), and 0 otherwise. Each gate's output goes to a
# log. For a failing gate the runner prints the FAILED TEST: lines its log
# carries (hack/acceptance/lib/test-passed.sh writes one per failing suite or
# test) and then the log's tail.
#
# hack/ci.sh runs swift test once and names its event stream in
# K3SM_APP_TEST_EVENTS; each gate then reads that stream instead of running
# the suite again (app_test_results in the same library). Without it, a gate
# runs swift test itself. The assertion is the same either way.
#
# Usage:
#   hack/run-acceptance.sh [--dir <dir>]   run every B*.sh in <dir>
#                                          (default hack/acceptance)
#   hack/run-acceptance.sh --self-test     prove the verdicts with fixtures,
#                                          a planted failing gate among them
#
# The gates read K3SM_DIR, K3SM_SWIFTPM_DISABLE_SANDBOX and
# K3SM_APP_TEST_EVENTS from the environment; the runner passes them through
# untouched. Runs under macOS
# /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
	echo "usage: hack/run-acceptance.sh [--dir <dir>] | --self-test" >&2
	exit 2
}

# run_gates <dir>: runs every B*.sh in <dir>, prints one line per gate and a
# summary naming every lab-pending and failed gate, and returns 1 on any
# failure or an empty directory.
run_gates() {
	local dir="$1" logs f name rc verdict n=0
	local passed="" pending="" failed=""
	[ -d "$dir" ] || { echo "FAIL: no acceptance directory at $dir"; return 1; }
	logs="$(mktemp -d)"
	for f in "$dir"/B*.sh; do
		[ -f "$f" ] || continue
		n=$((n + 1))
		name="$(basename "$f" .sh)"
		rc=0
		bash "$f" > "$logs/$name.log" 2>&1 || rc=$?
		if [ "$rc" = 0 ] && ! grep -q 'LAB-PENDING' "$logs/$name.log"; then
			verdict=pass
			passed="$passed $name"
		elif [ "$rc" = 3 ] && grep -q 'LAB-PENDING' "$logs/$name.log"; then
			verdict=lab-pending
			pending="$pending $name"
		else
			verdict="FAIL (exit $rc)"
			failed="$failed $name"
		fi
		echo "    $name: $verdict"
		case "$verdict" in
		lab-pending) grep -m 1 'LAB-PENDING' "$logs/$name.log" | sed 's/^/        /' ;;
		FAIL*)
			# The failing tests first, by name: the tail below can miss them.
			grep '^FAILED TEST: ' "$logs/$name.log" | sed 's/^/        /' || true
			tail -n 40 "$logs/$name.log" | sed 's/^/        | /'
			;;
		esac
	done
	rm -rf "$logs"
	if [ "$n" = 0 ]; then
		echo "FAIL: no acceptance gate (B*.sh) in $dir"
		return 1
	fi
	echo "    passed:${passed:- none}"
	echo "    lab-pending (not a pass):${pending:- none}"
	if [ -n "$failed" ]; then
		echo "FAIL: acceptance gates failed:$failed"
		return 1
	fi
	return 0
}

# expect <case> <want-rc> <want-text> <dir>: the self-test's one assertion.
expect() {
	local name="$1" want_rc="$2" want_text="$3" dir="$4" rc=0
	run_gates "$dir" > "$st/$name.out" 2>&1 || rc=$?
	if [ "$rc" != "$want_rc" ]; then
		echo "SELF-TEST FAIL: $name: runner exit $rc, want $want_rc"; cat "$st/$name.out"; exit 1
	fi
	if ! grep -qF -- "$want_text" "$st/$name.out"; then
		echo "SELF-TEST FAIL: $name: output lacks '$want_text'"; cat "$st/$name.out"; exit 1
	fi
	echo "    ok: $name"
}

self_test() {
	st="$(mktemp -d)"
	trap 'rm -rf "$st"' EXIT
	gate() { # gate <dir> <name> <body>
		mkdir -p "$1"
		printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/$2.sh"
	}
	gate "$st/green" B1 'echo ok; exit 0'
	gate "$st/green" B2 'echo "B2 gate: LAB-PENDING: not a pass (needs a GUI session)" >&2; exit 3'
	expect "a pass and a lab-pending gate are green" 0 "lab-pending (not a pass): B2" "$st/green"
	grep -qF "passed: B1" "$st/a pass and a lab-pending gate are green.out" \
		|| { echo "SELF-TEST FAIL: B1 not listed as passed"; exit 1; }

	gate "$st/planted" B1 'echo ok; exit 0'
	gate "$st/planted" B9 'echo "planted failure"; exit 1'
	expect "a planted failing gate reds the runner" 1 "acceptance gates failed: B9" "$st/planted"
	grep -qF "| planted failure" "$st/a planted failing gate reds the runner.out" \
		|| { echo "SELF-TEST FAIL: the failing gate's output was not shown"; exit 1; }

	gate "$st/exit3" B3 'echo "cannot run"; exit 3'
	expect "exit 3 without LAB-PENDING is a failure" 1 "B3: FAIL (exit 3)" "$st/exit3"

	gate "$st/text0" B4 'echo "LAB-PENDING"; exit 0'
	expect "LAB-PENDING with exit 0 is a failure" 1 "B4: FAIL (exit 0)" "$st/text0"

	gate "$st/text1" B5 'echo "LAB-PENDING"; exit 1'
	expect "LAB-PENDING with exit 1 is a failure" 1 "B5: FAIL (exit 1)" "$st/text1"

	gate "$st/later" B6 'exit 1'
	gate "$st/later" B7 'exit 0'
	expect "a failure does not stop the later gates" 1 "B7: pass" "$st/later"

	# A gate that reads a shared event stream: it runs no swift test (a swift
	# first on PATH records any call and fails), and when a suite it owns
	# failed there, the runner names the failing tests ahead of a tail that
	# 60 lines of later output push them out of.
	lib="$PWD/hack/acceptance/lib/test-passed.sh"
	fixture="$PWD/hack/testdata/test-passed/events.jsonl"
	mkdir -p "$st/bin"
	printf '#!/bin/sh\necho "$*" >> "%s/swift-calls"\nexit 1\n' "$st" > "$st/bin/swift"
	chmod 755 "$st/bin/swift"
	: > "$st/swift-calls"
	stream_gate() { # stream_gate <dir> <name> <suite>
		gate "$1" "$2" "set -euo pipefail
. '$lib'
SWIFT_FLAGS=(); TEST_FLAGS=()
tmp=\"\$(mktemp -d)\"; trap 'rm -rf \"\$tmp\"' EXIT
app_test_results \"\$tmp\" || exit 1
for i in \$(seq 60); do echo \"later line \$i\"; done
suite_passed \"\$tmp/results.tsv\" '$3' || { echo 'FAIL: suite $3 did not run and pass'; exit 1; }
echo ok"
	}
	stream_gate "$st/stream" B1 "good suite"
	stream_gate "$st/stream" B8 "bad suite"
	PATH="$st/bin:$PATH" K3SM_APP_TEST_EVENTS="$fixture" \
		expect "a gate owning a failed suite names its failing tests" 1 "acceptance gates failed: B8" "$st/stream"
	out="$st/a gate owning a failed suite names its failing tests.out"
	grep -qF "B1: pass" "$out" || { echo "SELF-TEST FAIL: the gate owning a passing suite did not pass"; cat "$out"; exit 1; }
	for t in 'FAILED TEST: test "fails"' 'FAILED TEST: test "throws"' 'FAILED TEST: suite "bad suite"'; do
		grep -qF "        $t" "$out" || { echo "SELF-TEST FAIL: the runner did not name $t"; cat "$out"; exit 1; }
	done
	if grep -qF '| FAILED TEST: ' "$out"; then
		echo "SELF-TEST FAIL: the planted failing names reached the tail, so the test proves nothing"; exit 1
	fi
	[ ! -s "$st/swift-calls" ] || { echo "SELF-TEST FAIL: a gate given a stream ran swift: $(cat "$st/swift-calls")"; exit 1; }
	echo "    ok: a gate given a stream runs no swift test"

	# A shared stream of a shape the reader does not know reds the gate.
	sed 's/"kind":"testSkipped"/"kind":"testVanished"/' "$fixture" > "$st/odd.jsonl"
	stream_gate "$st/odd" B1 "good suite"
	PATH="$st/bin:$PATH" K3SM_APP_TEST_EVENTS="$st/odd.jsonl" \
		expect "an unknown stream shape reds the gate" 1 "unrecognised event kind" "$st/odd"

	# A gate run on its own whose swift test fails with nothing in the stream
	# (a test process that died) still names the log's failure line ahead of
	# the tail: the run that said only "K3smStatusTests reported failures".
	mkdir -p "$st/bin2"
	cat > "$st/bin2/swift" <<'FAKE'
#!/bin/sh
echo "error: K3smStatusTests reported failures"
for i in $(seq 80); do echo "noise $i"; done
exit 1
FAKE
	chmod 755 "$st/bin2/swift"
	stream_gate "$st/died" B1 "good suite"
	PATH="$st/bin2:$PATH" K3SM_APP_TEST_EVENTS="" \
		expect "a run that died names the log's failure line" 1 "FAILED TEST:     error: K3smStatusTests reported failures" "$st/died"

	# Every real gate reads the suite through app_test_results; the one other
	# swift test allowed is B571's run against its fake CLI, which needs an
	# environment of its own.
	for f in hack/acceptance/B*.sh; do
		grep -qF "app_test_results \"\$tmp\"" "$f" \
			|| { echo "SELF-TEST FAIL: $f does not read the suite through app_test_results"; exit 1; }
		if grep -E '^[[:space:]]*swift test' "$f" | grep -vq -- '--filter StartFakeCLITests'; then
			echo "SELF-TEST FAIL: $f runs swift test itself"; exit 1
		fi
	done
	echo "    ok: every gate reads the suite through app_test_results"

	mkdir -p "$st/empty"
	expect "no gate at all is a failure" 1 "no acceptance gate" "$st/empty"
	expect "a missing directory is a failure" 1 "no acceptance directory" "$st/missing"

	echo "run-acceptance self-test: ok"
}

case "${1:-}" in
--self-test)
	[ "$#" = 1 ] || usage
	self_test
	;;
--dir)
	[ "$#" = 2 ] || usage
	run_gates "$2"
	;;
"")
	run_gates hack/acceptance
	;;
*)
	usage
	;;
esac
