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
# log; a failing gate's tail is printed.
#
# Usage:
#   hack/run-acceptance.sh [--dir <dir>]   run every B*.sh in <dir>
#                                          (default hack/acceptance)
#   hack/run-acceptance.sh --self-test     prove the verdicts with fixtures,
#                                          a planted failing gate among them
#
# The gates read K3SM_DIR and K3SM_SWIFTPM_DISABLE_SANDBOX from the
# environment; the runner passes both through untouched. Runs under macOS
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
		FAIL*) tail -n 40 "$logs/$name.log" | sed 's/^/        | /' ;;
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
