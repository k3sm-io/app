#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-no-inplace-write.sh [--self-test] [<root>]
#
# The swap engine and its helper never write into, truncate, copy over or
# re-sign a file inside an app bundle: a signed Mach-O that a running
# process has mapped must never be overwritten in place, so every bundle
# change is a rename of a whole directory, and removal goes entry by entry
# through descriptors. This check fails on any code line (comments are
# skipped) under Sources/K3smSwap or Sources/K3smAppUpdate that uses one of
# the calls that would do otherwise:
#
#   replaceItem  copyItem  moveItem  removeItem  O_TRUNC  truncate
#   write(to:  createFile(  codesign
#
# --self-test plants each call in a fixture tree and requires a failure, and
# requires a clean fixture (the calls named only in comments) to pass.
set -euo pipefail

DIRS="Sources/K3smSwap Sources/K3smAppUpdate"
PATTERN='replaceItem|copyItem|moveItem|removeItem|O_TRUNC|truncate|write\(to:|createFile\(|codesign'

# scan <root>: print every offending line; exit 1 when there is one.
scan() {
	local root="$1" found=0 dir f
	for dir in $DIRS; do
		[ -d "$root/$dir" ] || { echo "verify-no-inplace-write: missing $root/$dir" >&2; return 2; }
		while IFS= read -r -d '' f; do
			# Code lines only: a line whose first non-blank characters are //
			# is a comment.
			if LC_ALL=C grep -nE "$PATTERN" "$f" | LC_ALL=C grep -vE '^[0-9]+:[[:space:]]*//' >/dev/null; then
				LC_ALL=C grep -nE "$PATTERN" "$f" | LC_ALL=C grep -vE '^[0-9]+:[[:space:]]*//' | sed "s|^|    ${f#"$root"/}:|"
				found=1
			fi
		done < <(find "$root/$dir" -name '*.swift' -print0)
	done
	return "$found"
}

self_test() {
	local T call pass=0 fail=0 rc
	T="$(mktemp -d)"
	# shellcheck disable=SC2064 # expand now: T is local
	trap "rm -rf '$T'" EXIT
	mkdir -p "$T/clean/Sources/K3smSwap" "$T/clean/Sources/K3smAppUpdate"
	printf '// replaceItem, O_TRUNC and codesign are named here only.\nlet x = 1\n' > "$T/clean/Sources/K3smSwap/A.swift"
	printf '    /// truncate: a doc comment\nlet y = 2\n' > "$T/clean/Sources/K3smAppUpdate/main.swift"
	rc=0; scan "$T/clean" > /dev/null || rc=$?
	if [ "$rc" = 0 ]; then echo "ok   a clean tree passes"; pass=$((pass + 1)); else echo "FAIL a clean tree passes"; fail=$((fail + 1)); fi
	for call in 'try FileManager.default.replaceItemAt(a, withItemAt: b)' 'try FileManager.default.copyItem(atPath: a, toPath: b)' \
		'try FileManager.default.moveItem(atPath: a, toPath: b)' 'try FileManager.default.removeItem(atPath: a)' \
		'let fd = open(p, O_WRONLY | O_TRUNC)' 'ftruncate(fd, 0)' 'try data.write(to: url)' \
		'FileManager.default.createFile(atPath: p, contents: d)' 'run("/usr/bin/codesign", ["--force"])'; do
		rm -rf "$T/bad"
		cp -R "$T/clean" "$T/bad"
		printf '%s\n' "$call" >> "$T/bad/Sources/K3smSwap/A.swift"
		rc=0; scan "$T/bad" > /dev/null || rc=$?
		if [ "$rc" = 1 ]; then echo "ok   planted: $call"; pass=$((pass + 1)); else echo "FAIL planted: $call (exit $rc)"; fail=$((fail + 1)); fi
	done
	rm -rf "$T/bad"
	cp -R "$T/clean" "$T/bad"
	printf 'unlink(p); try FileManager.default.removeItem(atPath: p)\n' >> "$T/bad/Sources/K3smAppUpdate/main.swift"
	rc=0; scan "$T/bad" > /dev/null || rc=$?
	if [ "$rc" = 1 ]; then echo "ok   planted in the helper"; pass=$((pass + 1)); else echo "FAIL planted in the helper"; fail=$((fail + 1)); fi
	echo "verify-no-inplace-write self-test: $pass passed, $fail failed"
	[ "$fail" = 0 ]
}

case "${1:-}" in
--self-test)
	[ "$#" -eq 1 ] || { echo "usage: hack/verify-no-inplace-write.sh [--self-test] [<root>]" >&2; exit 2; }
	self_test
	exit
	;;
-*) echo "usage: hack/verify-no-inplace-write.sh [--self-test] [<root>]" >&2; exit 2 ;;
esac
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
rc=0; scan "$root" || rc=$?
if [ "$rc" = 1 ]; then
	echo "FAIL: the swap code may not write into, truncate, copy over or re-sign a file in place (lines above)" >&2
	exit 1
fi
[ "$rc" = 0 ] || exit "$rc"
echo "verify-no-inplace-write: ok"
