#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-help.sh [--self-test] [root] -- every control carries a catalog help tag.
#
#   1. no help string is written outside the catalog: a .help( with a string
#      literal on its line, or a toolTip set to a literal, anywhere under
#      Sources/ except Sources/K3smStatus/Help.swift, fails
#   2. every SwiftUI Button, Toggle, Picker, Menu and Stepper under
#      Sources/K3smApp has a .help( in its own modifier chain: from the
#      control to the end of its statement (where its brackets close and the
#      next line does not continue it with a modifier or a label: closure),
#      at the control's own bracket depth, so a .help( inside its label or on
#      the next statement does not count
#   3. a control that justly has none (a dialog's button, a context menu's
#      item: macOS shows no help tag there) is listed in hack/help.allow as
#      "<path>: <the line, trimmed> ## <reason>"; an entry without a reason,
#      or one that matches no control, fails
#
# The check is textual, tuned on this tree; the standard itself (length, case,
# punctuation, never the label) is checked by the catalog's own test,
# helpCatalogFollowsTheStandard. --self-test runs the rules against the
# hermetic fixtures in hack/testdata/verify-help/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fixtures="$here/testdata/verify-help"
catalog="Sources/K3smStatus/Help.swift"

# controls_without_help <file> <label>: print "<label>:<line>:<text>" for each
# control in <file> whose statement has no .help( at its own depth.
controls_without_help() {
	awk -v F="$2" '
	{ lines[NR] = $0 }
	END {
		for (i = 1; i <= NR; i++) {
			L = lines[i]
			if (L ~ /^[ \t]*\/\//) continue
			if (!match(L, /(^|[^A-Za-z0-9_.])(Button|Toggle|Picker|Menu|Stepper)[ \t]*[({]/)) continue
			start = RSTART
			if (substr(L, start, 1) !~ /[A-Z]/) start++
			depth = 0; seen = 0; found = 0; instr = 0; done = 0
			j = i; pos = start
			while (j <= NR && !done) {
				s = lines[j]; n = length(s); k = pos
				while (k <= n) {
					ch = substr(s, k, 1)
					if (instr) {
						if (ch == "\\") k++
						else if (ch == "\"") instr = 0
						k++; continue
					}
					if (ch == "\"") { instr = 1; k++; continue }
					if (ch == "/" && substr(s, k + 1, 1) == "/") break
					if (ch == "(" || ch == "{" || ch == "[") { depth++; seen = 1 }
					else if (ch == ")" || ch == "}" || ch == "]") { depth--; if (depth < 0) { done = 1; break } }
					else if (depth == 0 && seen && substr(s, k, 6) == ".help(") found = 1
					k++
				}
				if (done) break
				if (depth == 0 && seen) {
					nx = j + 1
					while (nx <= NR && lines[nx] ~ /^[ \t]*(\/\/.*)?$/) nx++
					if (nx <= NR && lines[nx] ~ /^[ \t]*(\.|label:)/) { j = nx; pos = 1; continue }
					break
				}
				j++; pos = 1
			}
			if (!found) print F ":" i ":" L
		}
	}' "$1"
}

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# check <root>: rules 1 to 3 over the tree at <root>.
check() {
	local root="$1"
	local bad=0 f rel hit allow entry path content reason rest
	allow="$root/hack/help.allow"
	local missing="" used="" n_allow=0
	# Rule 1: help strings live only in the catalog.
	while IFS= read -r -d '' f; do
		rel="${f#"$root"/}"
		[ "$rel" = "$catalog" ] && continue
		while IFS= read -r hit; do
			[ -n "$hit" ] || continue
			echo "    FAIL: $rel:${hit%%:*}: a help string literal; put it in $catalog and use Help.<area>.<name>"
			echo "        ${hit#*:}" | trim | sed 's/^/        /'
			bad=1
		done < <(grep -nE '\.help\(.*"|toolTip[[:space:]]*=[[:space:]]*"' "$f" | grep -vE '^[0-9]+:[[:space:]]*//' || true)
	done < <(find "$root/Sources" -name '*.swift' -print0 2>/dev/null)
	# Rule 2: every control has a help tag in its chain.
	if [ -d "$root/Sources/K3smApp" ]; then
		while IFS= read -r -d '' f; do
			rel="${f#"$root"/}"
			missing="$missing$(controls_without_help "$f" "$rel")
"
		done < <(find "$root/Sources/K3smApp" -name '*.swift' -print0 | sort -z)
	fi
	# Rule 3: the reviewed allowlist.
	if [ -f "$allow" ]; then
		while IFS= read -r entry; do
			case "$entry" in ''|'#'*) continue ;; esac
			n_allow=$((n_allow + 1))
			path="${entry%%: *}"
			content="${entry#*: }"
			reason=""
			case "$content" in *' ## '*) reason="${content##* ## }"; content="${content% ## *}" ;; esac
			content="$(printf '%s' "$content" | trim)"
			reason="$(printf '%s' "$reason" | trim)"
			if [ -z "$reason" ]; then
				echo "    FAIL: hack/help.allow: no reason (\" ## <reason>\") for: $entry"; bad=1; continue
			fi
			if ! printf '%s\n' "$missing" | awk -v p="$path" -v c="$content" '
				{ i = index($0, ":"); fp = substr($0, 1, i - 1); rest = substr($0, i + 1)
				  j = index(rest, ":"); t = substr(rest, j + 1); gsub(/^[ \t]+|[ \t]+$/, "", t)
				  if (fp == p && t == c) { found = 1 } }
				END { exit found ? 0 : 1 }'; then
				echo "    FAIL: hack/help.allow: matches no control without a help tag (stale): $path: $content"; bad=1; continue
			fi
			used="$used$path: $content
"
		done < "$allow"
	fi
	while IFS= read -r hit; do
		[ -n "$hit" ] || continue
		path="${hit%%:*}"; rest="${hit#*:}"
		content="$(printf '%s' "${rest#*:}" | trim)"
		if printf '%s' "$used" | grep -qxF -- "$path: $content"; then continue; fi
		echo "    FAIL: $path:${rest%%:*}: a control with no .help( in its modifier chain; give it .help(Help.<area>.<name>)"
		echo "        $content"
		bad=1
	done <<< "$missing"
	[ "$bad" = 0 ] || return 1
	local n_controls=0
	if [ -d "$root/Sources/K3smApp" ]; then
		n_controls="$(find "$root/Sources/K3smApp" -name '*.swift' -exec cat {} + | grep -vE '^[[:space:]]*//' \
			| grep -cE '(^|[^A-Za-z0-9_.])(Button|Toggle|Picker|Menu|Stepper)[[:space:]]*[({]' || true)"
	fi
	echo "    $n_controls control(s) checked, $n_allow allowlisted in hack/help.allow"
}

stage_fixture() {
	local src="$1" dest="$2" f rel
	mkdir -p "$dest/hack" "$dest/Sources"
	(cd "$src" && find . -type f -name '*.fixture') | while IFS= read -r rel; do
		rel="${rel#./}"
		mkdir -p "$dest/$(dirname "$rel")"
		cp "$src/$rel" "$dest/${rel%.fixture}"
	done
	if [ -f "$src/help.allow" ]; then cp "$src/help.allow" "$dest/hack/help.allow"; fi
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
		out="$(check "$tmp/$name" 2>&1)" || status=$?
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
	echo "verify-help self-test: $n cases ok"
}

case "${1:-}" in
--self-test) self_test ;;
*)
	root="${1:-$here/..}"
	root="$(cd "$root" && pwd)"
	if check "$root"; then echo "    ok"; else echo "FAIL: help tags (see the standard in CLAUDE.md)"; exit 1; fi
	;;
esac
