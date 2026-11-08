#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# testresults.sh -- builds and tests hack/testresults/main.swift, the checker that
# applies the flake quarantine registry (hack/quarantine.txt) to a swift-testing
# event stream (its header has the rules; hack/quarantine.txt has the format).
#
#   hack/testresults.sh build <out>             # swiftc the checker to <out>
#   hack/testresults.sh --self-test [<binary>]  # the table tests: every case
#                                               # under hack/testdata/testresults,
#                                               # then the usage refusals; builds
#                                               # the checker when no binary is given
#
# A case is a directory holding quarantine.txt, events.jsonl, args (the
# checker's arguments, one per line, before --registry and --events, which the
# runner adds; a relative --log names a file in the case) and expect: `#`
# comment lines, `exit <n>`, then fixed strings the output must hold, one per
# line. The checker is built with swiftc alone: Foundation, no package.
#
# Exit 0 = pass, 1 = a case failed, 2 = usage.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: hack/testresults.sh build <out> | --self-test [<binary>]" >&2; exit 2; }

build() {
	swiftc -o "$1" hack/testresults/main.swift
}

# run_case <binary> <case dir> <out file>: runs one case; prints why it failed.
run_case() {
	local bin="$1" dir="$2" out="$3" want="" rc=0 line a args=()
	while IFS= read -r a || [ -n "$a" ]; do
		[ -n "$a" ] || continue
		if [ "${#args[@]}" -gt 0 ] && [ "${args[${#args[@]}-1]}" = --log ]; then a="$dir/$a"; fi
		args+=("$a")
	done < "$dir/args"
	"$bin" --registry "$dir/quarantine.txt" --events "$dir/events.jsonl" "${args[@]}" > "$out" 2>&1 || rc=$?
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'#'* | '') ;;
		'exit '*)
			want="${line#exit }"
			[ "$rc" = "$want" ] || { echo "exit $rc, want $want"; return 1; }
			;;
		*) grep -qF -- "$line" "$out" || { echo "the output lacks: $line"; return 1; } ;;
		esac
	done < "$dir/expect"
	[ -n "$want" ] || { echo "its expect file names no exit status"; return 1; }
}

self_test() {
	local bin="${1:-}" tmp dir name why n=0 failed=0 rc
	tmp="$(mktemp -d "${TMPDIR:-/tmp}/testresults.XXXXXX")"
	# shellcheck disable=SC2064 # the path is fixed now, on purpose
	trap "rm -rf '$tmp'" RETURN
	if [ -z "$bin" ]; then
		bin="$tmp/testresults"
		build "$bin"
	fi
	for dir in hack/testdata/testresults/*/; do
		dir="${dir%/}"
		name="${dir##*/}"
		n=$((n + 1))
		if ! why="$(run_case "$bin" "$dir" "$tmp/out")"; then
			echo "    FAIL: $name: $why"
			sed 's/^/      /' "$tmp/out"
			failed=$((failed + 1))
		fi
	done
	[ "$n" -gt 0 ] || { echo "    FAIL: no cases under hack/testdata/testresults"; return 1; }
	# The usage refusals: no tier, an unknown tier, no stream, a bad date, an
	# unknown flag and a flag without its value each exit 2.
	local d=hack/testdata/testresults/clean-pass
	for args in "--events $d/events.jsonl" "--tier fastest --events $d/events.jsonl" "--tier full" \
		"--tier full --events $d/events.jsonl --today 2026-13-01" "--tier full --events $d/events.jsonl --verbose x" \
		"--tier full --events"; do
		n=$((n + 1))
		rc=0
		# shellcheck disable=SC2086 # the words split on purpose
		"$bin" --registry "$d/quarantine.txt" $args > "$tmp/out" 2>&1 || rc=$?
		[ "$rc" = 2 ] || { echo "    FAIL: usage '$args': exit $rc, want 2"; sed 's/^/      /' "$tmp/out"; failed=$((failed + 1)); }
	done
	# A missing registry is an empty one; a missing stream reds.
	n=$((n + 1))
	"$bin" --registry "$tmp/absent.txt" --tier full --events "$d/events.jsonl" > "$tmp/out" 2>&1 \
		|| { echo "    FAIL: a missing registry is not an empty one"; failed=$((failed + 1)); }
	n=$((n + 1))
	rc=0
	"$bin" --registry "$d/quarantine.txt" --tier full --events "$tmp/absent.jsonl" > "$tmp/out" 2>&1 || rc=$?
	[ "$rc" = 1 ] || { echo "    FAIL: a missing stream: exit $rc, want 1"; failed=$((failed + 1)); }
	# The committed registry validates.
	n=$((n + 1))
	"$bin" --registry hack/quarantine.txt --tier full --events "$d/events.jsonl" > "$tmp/out" 2>&1 \
		|| { echo "    FAIL: hack/quarantine.txt does not validate"; sed 's/^/      /' "$tmp/out"; failed=$((failed + 1)); }
	[ "$failed" = 0 ] || { echo "    testresults self-test: $failed of $n cases FAILED"; return 1; }
	echo "    testresults self-test: ok ($n cases)"
}

case "${1:-}" in
build) [ "$#" = 2 ] || usage; build "$2" ;;
--self-test) [ "$#" -le 2 ] || usage; self_test "${2:-}" ;;
*) usage ;;
esac
