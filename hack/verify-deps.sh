#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-deps.sh [--self-test] [root] -- the dependency supply-chain check.
#
#   1. every .package( in Package.swift is listed in hack/deps.allow
#      (format: <url> <40-hex revision sha> <reason>)
#   2. an allowed package is pinned by .revision("<sha>") or exact:, never
#      from:, branch: or a range; a .revision must equal the allowed sha
#   3. Package.resolved exists, is committed, and carries the allowed sha
#   4. a hack/**/*.sh that downloads (curl, wget) verifies a sha256 in the
#      same script (shasum -a 256 -c, or a compared digest)
#
# With no package dependencies the allow file holds only comments and rules 2
# and 3 have nothing to check. --self-test runs the rules against the
# hermetic fixtures in hack/testdata/verify-deps/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fixtures="$here/testdata/verify-deps"

# check <root> <check-committed 0|1>: print each violation, return 1 if any.
check() {
	local root="$1" committed="$2" bad=0
	local manifest="$root/Package.swift" allow="$root/hack/deps.allow"
	local flat chunks chunk url rev sha

	fail() { echo "    FAIL: $*"; bad=1; }

	[ -f "$manifest" ] || { echo "    FAIL: no Package.swift in $root"; return 1; }
	[ -f "$allow" ] || { echo "    FAIL: no hack/deps.allow in $root"; return 1; }

	flat="$(tr '\n' ' ' < "$manifest")"
	# One chunk per .package( declaration, cut at the closing bracket of the list.
	chunks="$(printf '%s' "$flat" | awk 'BEGIN{RS="[.]package[(]"; ORS="\n"} NR>1{sub(/\][^]]*$/, ""); print}')"
	while IFS= read -r chunk; do
		[ -n "$chunk" ] || continue
		url="$(printf '%s' "$chunk" | sed -n 's/.*url:[[:space:]]*"\([^"]*\)".*/\1/p')"
		if [ -z "$url" ]; then fail "a .package( without a url: is not allowed"; continue; fi
		sha="$(awk -v u="$url" '$1 == u && $2 ~ /^[0-9a-f]{40}$/ && NF >= 3 {print $2; exit}' "$allow")"
		if [ -z "$sha" ]; then fail "$url is not in hack/deps.allow (or has no 40-hex revision and reason)"; continue; fi
		if printf '%s' "$chunk" | grep -Eq 'from:|branch:|upToNext|\.\.[.<]'; then
			fail "$url: pin by .revision(\"<sha>\") or exact:, not from:, branch: or a range"; continue
		fi
		rev="$(printf '%s' "$chunk" | sed -nE 's/.*revision(:[[:space:]]*|\()"([0-9a-f]{40})".*/\2/p')"
		if [ -n "$rev" ]; then
			[ "$rev" = "$sha" ] || fail "$url: .revision $rev differs from the allowed $sha"
		elif ! printf '%s' "$chunk" | grep -Eq 'exact:'; then
			fail "$url: not pinned by .revision(\"<40-hex sha>\") or exact:"
		fi
		if [ ! -f "$root/Package.resolved" ]; then
			fail "$url: Package.resolved is missing"
		else
			if [ "$committed" = 1 ]; then
				git -C "$root" ls-files --error-unmatch Package.resolved >/dev/null 2>&1 \
					|| fail "Package.resolved is not committed"
			fi
			if ! { grep -Fq "$url" "$root/Package.resolved" && grep -Fq "$sha" "$root/Package.resolved"; }; then
				fail "$url: Package.resolved does not carry the allowed revision $sha"
			fi
		fi
	done <<< "$chunks"

	# Downloaders need a digest check in the same script. This script and the
	# fixtures are exempt: it names the tools only to look for them.
	local dl='(^|[[:space:];&|(`])(curl|wget)[[:space:]]'
	local f
	if [ -d "$root/hack" ]; then
		while IFS= read -r -d '' f; do
			[ "$(basename "$f")" != verify-deps.sh ] || continue
			if grep -Ev '^[[:space:]]*#' "$f" | grep -Eq "$dl"; then
				{ grep -Eq 'shasum -a 256 -c|sha256sum -c' "$f" \
					|| { grep -Eq 'shasum -a 256|sha256sum|dgst -sha256' "$f" && grep -Eq '\[\[? .*[^!=]=?=[^=~]' "$f"; }; } \
					|| fail "${f#"$root"/}: downloads without a sha256 verification"
			fi
		done < <(find "$root/hack" -name '*.sh' -not -path '*/testdata/*' -print0)
	fi
	return "$bad"
}

# stage_fixture <case dir> <dest>: Package.* lands at the root, deps.allow and
# *.fixture scripts under hack/. The .fixture suffix keeps shellcheck and the
# license-header scan from treating a fixture as live source.
stage_fixture() {
	local src="$1" dest="$2" f name
	mkdir -p "$dest/hack"
	for f in "$src"/*; do
		name="$(basename "$f")"
		case "$name" in
		expect) ;;
		Package.*) cp "$f" "$dest/${name%.fixture}" ;;
		*) cp "$f" "$dest/hack/${name%.fixture}" ;;
		esac
	done
}

self_test() {
	local tmp d name want substr out status n=0
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' RETURN
	for d in "$fixtures"/*/; do
		name="$(basename "$d")"
		read -r want substr < "$d/expect"
		substr="${substr:-}"
		stage_fixture "$d" "$tmp/$name"
		status=0
		out="$(check "$tmp/$name" 0 2>&1)" || status=$?
		case "$want" in
		pass) [ "$status" = 0 ] || { echo "FAIL: $name should pass:"; echo "$out"; return 1; } ;;
		fail)
			[ "$status" != 0 ] || { echo "FAIL: $name should be refused"; return 1; }
			printf '%s' "$out" | grep -Fq -- "$substr" || { echo "FAIL: $name: no '$substr' in:"; echo "$out"; return 1; }
			;;
		*) echo "FAIL: $name: bad expect file"; return 1 ;;
		esac
		echo "    $want: $name"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || { echo "FAIL: no fixtures under $fixtures"; return 1; }
	echo "verify-deps self-test: $n cases ok"
}

case "${1:-}" in
--self-test) self_test ;;
*)
	root="${1:-$here/..}"
	root="$(cd "$root" && pwd)"
	if check "$root" 1; then echo "    ok"; else echo "FAIL: dependency supply-chain check"; exit 1; fi
	;;
esac
