#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# test-passed.sh -- answers "did the suite or test with this exact display
# name run and pass?" from swift-testing's JSON event stream, never from the
# console log. The console lines of tests running in parallel interleave, so
# a `Test "..." passed` line can arrive split and a grep for it misses a test
# that passed.
#
# A gate sources this file and then, once:
#
#   app_test_results "$tmp" || exit 1
#   suite_passed "$tmp/results.tsv" "<suite display name>"
#   test_passed "$tmp/results.tsv" "<test display name>"
#
# app_test_results (below) reads the event stream hack/ci.sh hands every gate,
# or runs swift test with the stream when the gate runs on its own, and writes
# the table through test_results, which writes one line per suite or test
# that has a display name:
# <suite|test> TAB <pass|fail|skip|unfinished|notrun> TAB <display name>.
#   fail    a failing issue was recorded in it or, for a suite, in anything it
#           contains (a warning or a known issue is not a failure, as in the
#           console)
#   skip    it was skipped (disabled, or a condition was false)
#   pass    it ended with none of the above
#   unfinished  it started and never ended: its test process stopped under
#           it, a crash or a kill, which records no issue in the stream
#   notrun  it was declared and never started
# It fails when the stream holds no completed run or no declared test.
#
# suite_passed and test_passed match the whole display name, so a name that
# is a prefix of another never matches the longer one. They succeed when at
# least one suite or test of that kind and name passed and none failed.
#
# Run directly with --self-test to check these verdicts against
# hack/testdata/test-passed/events.jsonl, a recorded stream that holds a
# passing test and a longer name it prefixes, a warning, a known issue, a
# skipped test, a failing parameterized case, a thrown error, a failure in a
# nested suite, and one display name used by a passing and a failing test.
#
# Needs /usr/bin/jq (macOS 15 and later). Runs under macOS /bin/bash 3.2.

# The event kinds this reader knows. A record that is not a test or an event,
# or an event of any other kind, fails the read: a shape this reader was not
# written for could carry a failure it does not see, so it answers red, never
# green. A new toolchain that adds a kind is read only after the kind is
# added here and to the fixture.
TEST_EVENT_KINDS='["runStarted","runEnded","iterationStarted","iterationEnded","testStarted","testEnded","testCaseStarted","testCaseEnded","testSkipped","issueRecorded","valueAttached"]'

# test_results <events.jsonl>: prints the verdict table described above.
test_results() {
	local events="$1"
	[ -s "$events" ] || { echo "FAIL: no swift-testing event stream at $events" >&2; return 1; }
	[ -x /usr/bin/jq ] || { echo "FAIL: /usr/bin/jq is missing; it reads the swift-testing event stream" >&2; return 1; }
	local out
	out="$(/usr/bin/jq -rn --argjson known "$TEST_EVENT_KINDS" '
		[inputs] as $all
		| ($all | map(select((type == "object" and (.kind == "test" or .kind == "event") and (.payload | type) == "object") | not))) as $odd
		| if ($odd | length) > 0 then
			error("an unrecognised record: \($odd[0] | tojson | .[0:200])")
		  else . end
		| ($all | map(select(.kind == "event") | .payload.kind) | map(select(. as $k | $known | index($k) | not))) as $unknown
		| if ($unknown | length) > 0 then
			error("an unrecognised event kind: \($unknown[0] | tojson)")
		  else . end
		| ($all | map(select(.kind == "test") | .payload)) as $tests
		| ($all | map(select(.kind == "event") | .payload)) as $events
		| if ($events | map(select(.kind == "runEnded")) | length) == 0 then
			error("the event stream holds no completed run")
		  elif ($tests | length) == 0 then
			error("the event stream declares no tests")
		  else . end
		| (reduce ($events[] | select(.kind == "testEnded") | .testID) as $id ({}; .[$id] = true)) as $ended
		| (reduce ($events[] | select(.kind == "testStarted") | .testID) as $id ({}; .[$id] = true)) as $started
		| (reduce ($events[] | select(.kind == "testSkipped") | .testID) as $id ({}; .[$id] = true)) as $skipped
		| [$events[]
			| select(.kind == "issueRecorded" and .testID != null)
			| select(if (.issue | has("isFailure")) then .issue.isFailure
				else ((.issue.isKnown != true) and (.issue.severity != "warning")) end)
			| .testID] as $failed
		| $tests[]
		| select(.displayName != null)
		| .id as $id
		| (if .kind == "suite" then "suite" else "test" end) as $kind
		| (if any($failed[]; . == $id or startswith($id + "/")) then "fail"
			elif $skipped[$id] then "skip"
			elif $ended[$id] then "pass"
			elif $started[$id] then "unfinished"
			else "notrun" end) as $verdict
		| [$kind, $verdict, .displayName] | @tsv
	' "$events")" || { echo "FAIL: could not read the swift-testing event stream at $events" >&2; return 1; }
	[ -n "$out" ] || { echo "FAIL: the event stream at $events names no suite or test" >&2; return 1; }
	printf '%s\n' "$out"
}

# result_passed <results.tsv> <suite|test> <display name>
result_passed() {
	local tab
	tab="$(printf '\t')"
	grep -qxF "$2${tab}pass${tab}$3" "$1" && ! grep -qxF "$2${tab}fail${tab}$3" "$1"
}

# suite_passed <results.tsv> <display name>
suite_passed() { result_passed "$1" suite "$2"; }

# test_passed <results.tsv> <display name>
test_passed() { result_passed "$1" test "$2"; }

# failed_tests <results.tsv>: prints one line per failing or unfinished
# suite or test,
#   FAILED TEST: <suite|test> "<display name>"[ (started, never ended: ...)]
# hack/run-acceptance.sh prints these lines of a failed gate's log before its
# tail, so a failing test is named even when the tail does not reach it.
failed_tests() {
	local tab kind verdict name
	tab="$(printf '\t')"
	while IFS="$tab" read -r kind verdict name; do
		case "$verdict" in
		fail) printf 'FAILED TEST: %s "%s"\n' "$kind" "$name" ;;
		unfinished) printf 'FAILED TEST: %s "%s" (started, never ended: its test process stopped)\n' "$kind" "$name" ;;
		esac
	done < "$1"
	return 0
}

# failure_names <events.jsonl> <log> <results.tsv>: for a swift test run that
# exited non-zero, names what failed: the FAILED TEST: lines of the stream
# and, when the stream names none (a test process that died before it could
# record an issue, or a stream that cannot be read), the log's own failure
# and crash lines, so a failing test is never left to the tail alone.
failure_names() {
	local events="$1" log="$2" results="$3" named=""
	if test_results "$events" > "$results" 2> /dev/null; then
		named="$(failed_tests "$results")"
	fi
	if [ -n "$named" ]; then
		printf '%s\n' "$named"
		return 0
	fi
	echo "FAILED TEST: the event stream names no failing test; the log's failure lines:"
	grep -E '✘|error:|Fatal error|crashed|signal [0-9]+|reported failures|exited with' "$log" 2> /dev/null \
		| head -n 40 | sed 's/^/FAILED TEST:     /' || true
	return 0
}

# app_test_results <dir> [<swift test argument>...]: writes <dir>/results.tsv,
# the verdict table of one swift test run of this package.
#
# When K3SM_APP_TEST_EVENTS names a stream, that stream is read and nothing
# runs: hack/ci.sh runs swift test once and hands its stream to every gate,
# which asserts that the suites and tests it owns ran and passed there. A
# failure in a suite the gate does not own is not its failure.
#
# Otherwise (a gate run on its own) it runs swift test here with the
# arguments given, into <dir>/events.jsonl and <dir>/test.log, and exports
# K3SM_APP_TEST_EVENTS so a gate this one runs reads the same stream. A
# non-zero exit fails it, after the failing tests are named and the log's
# tail is shown. The caller sets SWIFT_FLAGS and TEST_FLAGS (they may be
# empty) and changes to the package root first.
#
# Either way the failing suites and tests are printed as FAILED TEST: lines,
# and a stream that cannot be read fails.
app_test_results() {
	local dir="$1" events status=0
	shift
	if [ -n "${K3SM_APP_TEST_EVENTS:-}" ]; then
		events="$K3SM_APP_TEST_EVENTS"
		echo "    reading the event stream at $events (no second run)"
		test_results "$events" > "$dir/results.tsv" || return 1
		failed_tests "$dir/results.tsv"
		return 0
	fi
	events="$dir/events.jsonl"
	swift test ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"} "$@" \
		--experimental-event-stream-output "$events" > "$dir/test.log" 2>&1 || status=$?
	if [ "$status" != 0 ]; then
		failure_names "$events" "$dir/test.log" "$dir/results.tsv"
		tail -n 60 "$dir/test.log"
		echo "FAIL: swift test exited $status"
		return 1
	fi
	test_results "$events" > "$dir/results.tsv" || return 1
	failed_tests "$dir/results.tsv"
	K3SM_APP_TEST_EVENTS="$events"
	export K3SM_APP_TEST_EVENTS
}

test_passed_self_test() {
	local dir fixture tmp rc=0
	dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	fixture="$dir/testdata/test-passed/events.jsonl"
	tmp="$(mktemp -d)"
	test_passed_self_test_cases "$fixture" "$tmp" || rc=1
	rm -rf "$tmp"
	return "$rc"
}

test_passed_self_test_cases() {
	local fixture="$1" tmp="$2" n=0 got
	test_results "$fixture" > "$tmp/results.tsv" || return 1
	want() {
		n=$((n + 1))
		if "$2" "$tmp/results.tsv" "$3"; then got=yes; else got=no; fi
		[ "$got" = "$1" ] || { echo "FAIL: self-test: $2 \"$3\" answered $got, want $1"; return 1; }
	}
	want yes test_passed "a pass" || return 1
	want yes test_passed "a pass, longer" || return 1
	want no test_passed "a pass, long" || return 1
	want no test_passed "a pas" || return 1
	want yes test_passed "warns" || return 1
	want yes test_passed "known issue" || return 1
	want no test_passed "skipped" || return 1
	want no test_passed "fails" || return 1
	want no test_passed "throws" || return 1
	want no test_passed "a parameterized test that fails one case" || return 1
	want no test_passed "same name" || return 1
	want no test_passed "inner fails" || return 1
	want no test_passed "no such test" || return 1
	want no test_passed "good suite" || return 1
	want yes suite_passed "good suite" || return 1
	want yes suite_passed "good suite, longer" || return 1
	want no suite_passed "good" || return 1
	want no suite_passed "a pass" || return 1
	want no suite_passed "bad suite" || return 1
	want no suite_passed "inner suite" || return 1
	want no suite_passed "outer suite" || return 1
	# A stream cut off before its run ended, or an empty one, is refused.
	grep -v '"runEnded"' "$fixture" > "$tmp/cut.jsonl"
	if test_results "$tmp/cut.jsonl" > /dev/null 2>&1; then
		echo "FAIL: self-test: a stream with no completed run was read"; return 1
	fi
	: > "$tmp/empty.jsonl"
	if test_results "$tmp/empty.jsonl" > /dev/null 2>&1; then
		echo "FAIL: self-test: an empty stream was read"; return 1
	fi
	# A shape this reader was not written for is refused, never read green:
	# an event kind it does not know, a record that is neither a test nor an
	# event, and a line that is not JSON.
	sed 's/"kind":"testSkipped"/"kind":"testVanished"/' "$fixture" > "$tmp/kind.jsonl"
	if test_results "$tmp/kind.jsonl" > "$tmp/kind.out" 2>&1; then
		echo "FAIL: self-test: a stream with an unknown event kind was read"; return 1
	fi
	grep -q 'unrecognised event kind' "$tmp/kind.out" \
		|| { echo "FAIL: self-test: the unknown event kind was not named"; cat "$tmp/kind.out"; return 1; }
	{ cat "$fixture"; echo '{"kind":"attachment","payload":{},"version":"6.4.0"}'; } > "$tmp/record.jsonl"
	if test_results "$tmp/record.jsonl" > /dev/null 2>&1; then
		echo "FAIL: self-test: a stream with an unknown record was read"; return 1
	fi
	{ cat "$fixture"; echo 'not json'; } > "$tmp/garbage.jsonl"
	if test_results "$tmp/garbage.jsonl" > /dev/null 2>&1; then
		echo "FAIL: self-test: a stream with a line that is not JSON was read"; return 1
	fi
	# A test that started and never ended (its process died) is unfinished,
	# never a pass, and is named.
	/usr/bin/jq -c 'select(.kind != "event" or .payload.kind != "testEnded" or (.payload.testID | startswith("LTests.Good/a()") | not))' \
		"$fixture" > "$tmp/crash.jsonl"
	test_results "$tmp/crash.jsonl" > "$tmp/crash.tsv" || return 1
	if test_passed "$tmp/crash.tsv" "a pass"; then
		echo "FAIL: self-test: a test that never ended was read as a pass"; return 1
	fi
	failed_tests "$tmp/crash.tsv" | grep -qF 'FAILED TEST: test "a pass" (started, never ended' \
		|| { echo "FAIL: self-test: the unfinished test was not named"; failed_tests "$tmp/crash.tsv"; return 1; }
	# A run that failed with nothing in the stream still names the log's
	# failure lines.
	printf 'building\nerror: K3smStatusTests reported failures\n' > "$tmp/crash.log"
	failure_names "$tmp/empty.jsonl" "$tmp/crash.log" "$tmp/none.tsv" > "$tmp/names.out"
	grep -qF 'FAILED TEST:     error: K3smStatusTests reported failures' "$tmp/names.out" \
		|| { echo "FAIL: self-test: the log's failure line was not named"; cat "$tmp/names.out"; return 1; }
	# The failing suites and tests are named, and only those.
	failed_tests "$tmp/results.tsv" > "$tmp/failed.out"
	for name in 'test "fails"' 'test "throws"' 'suite "bad suite"' 'test "inner fails"'; do
		grep -qxF "FAILED TEST: $name" "$tmp/failed.out" \
			|| { echo "FAIL: self-test: failed_tests does not name $name"; cat "$tmp/failed.out"; return 1; }
	done
	if grep -qF '"a pass"' "$tmp/failed.out"; then
		echo "FAIL: self-test: failed_tests names a passing test"; return 1
	fi
	echo "    ok ($n verdicts; a cut-off, an empty and three unknown shapes refused; failing and unfinished tests named, and the log's failure lines when the stream names none)"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	set -euo pipefail
	case "${1:-}" in
	--self-test) test_passed_self_test ;;
	*) echo "usage: hack/acceptance/lib/test-passed.sh --self-test (gates source this file)" >&2; exit 2 ;;
	esac
fi
