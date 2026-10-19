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
# A gate sources this file, runs
#
#   swift test ... --experimental-event-stream-output "$tmp/events.jsonl"
#
# and then, once:
#
#   test_results "$tmp/events.jsonl" > "$tmp/results.tsv" || exit 1
#   suite_passed "$tmp/results.tsv" "<suite display name>"
#   test_passed "$tmp/results.tsv" "<test display name>"
#
# test_results writes one line per suite or test that has a display name:
# <suite|test> TAB <pass|fail|skip|notrun> TAB <display name>.
#   fail    a failing issue was recorded in it or, for a suite, in anything it
#           contains (a warning or a known issue is not a failure, as in the
#           console)
#   skip    it was skipped (disabled, or a condition was false)
#   pass    it ended with none of the above
#   notrun  it was declared and never ended
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

# test_results <events.jsonl>: prints the verdict table described above.
test_results() {
	local events="$1"
	[ -s "$events" ] || { echo "FAIL: no swift-testing event stream at $events" >&2; return 1; }
	[ -x /usr/bin/jq ] || { echo "FAIL: /usr/bin/jq is missing; it reads the swift-testing event stream" >&2; return 1; }
	local out
	out="$(/usr/bin/jq -rn '
		[inputs] as $all
		| ($all | map(select(.kind == "test") | .payload)) as $tests
		| ($all | map(select(.kind == "event") | .payload)) as $events
		| if ($events | map(select(.kind == "runEnded")) | length) == 0 then
			error("the event stream holds no completed run")
		  elif ($tests | length) == 0 then
			error("the event stream declares no tests")
		  else . end
		| (reduce ($events[] | select(.kind == "testEnded") | .testID) as $id ({}; .[$id] = true)) as $ended
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
	echo "    ok ($n verdicts, and a cut-off and an empty stream refused)"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	set -euo pipefail
	case "${1:-}" in
	--self-test) test_passed_self_test ;;
	*) echo "usage: hack/acceptance/lib/test-passed.sh --self-test (gates source this file)" >&2; exit 2 ;;
	esac
fi
