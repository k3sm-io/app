#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# make-accent-fixtures.sh [<dir>]
#
# Writes the two tamper fixtures AccentCatalogTests checks the accent catalog
# against, into <dir> (default Tests/Fixtures/accent). Not run by ci.sh: the
# output is committed, because actool ships with Xcode only. Rerun it after
# the colour in make-accent.sh changes and commit the result.
#
#   wrong-colour.car  make-accent.sh's colour set with the light blue
#                     component moved from its value to 0x99 (or to 0x88 when
#                     it already is 0x99): one component wrong, nothing else.
#   foreign.car       another app's catalog: a colour named Brand and a data
#                     asset named Notes, no AccentColor.
#
# The colour set is read from make-accent.sh's <<'JSON' heredoc, the one
# source of the pair, so the wrong-colour catalog differs from the real one
# in exactly the component the script changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/Tests/Fixtures/accent}"
actool="$(xcrun --find actool 2>/dev/null || true)"
[ -n "$actool" ] || { echo "make-accent-fixtures: actool not found; it ships with Xcode" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

colorset="$(awk '/<<'"'"'JSON'"'"'$/ {f=1; next} f && /^JSON$/ {exit} f' "$ROOT/hack/make-accent.sh")"
[ -n "$colorset" ] || { echo "make-accent-fixtures: no <<'JSON' heredoc in make-accent.sh" >&2; exit 1; }
blue="$(printf '%s' "$colorset" | sed -n 's/^{"colors":\[{"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"\(0x[0-9A-Fa-f][0-9A-Fa-f]\)".*/\1/p')"
[ -n "$blue" ] || { echo "make-accent-fixtures: the light colour's blue component is not where it is expected" >&2; exit 1; }
other=0x99
[ "$blue" != "$other" ] || other=0x88
wrong="${colorset/\"blue\":\"$blue\"/\"blue\":\"$other\"}"
[ "$wrong" != "$colorset" ] || { echo "make-accent-fixtures: the blue component did not change" >&2; exit 1; }

compile() { # <xcassets> <out.car>
	mkdir -p "$work/out-$2"
	"$actool" --compile "$work/out-$2" --platform macosx --minimum-deployment-target 26.0 \
		--output-format human-readable-text --output-partial-info-plist "$work/partial-$2.plist" "$1" > /dev/null
	cp "$work/out-$2/Assets.car" "$OUT/$2"
	echo "make-accent-fixtures: wrote $OUT/$2"
}
info='{"info":{"author":"xcode","version":1}}'

w="$work/wrong.xcassets"
mkdir -p "$w/AccentColor.colorset"
printf '%s\n' "$info" > "$w/Contents.json"
printf '%s\n' "$wrong" > "$w/AccentColor.colorset/Contents.json"

f="$work/foreign.xcassets"
mkdir -p "$f/Brand.colorset" "$f/Notes.dataset"
printf '%s\n' "$info" > "$f/Contents.json"
printf '%s\n' '{"colors":[{"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"0x20","green":"0x80","red":"0xE0"}},"idiom":"universal"}],"info":{"author":"xcode","version":1}}' \
	> "$f/Brand.colorset/Contents.json"
printf 'a fixture data asset\n' > "$f/Notes.dataset/notes.txt"
printf '%s\n' '{"data":[{"filename":"notes.txt","idiom":"universal"}],"info":{"author":"xcode","version":1}}' \
	> "$f/Notes.dataset/Contents.json"

mkdir -p "$OUT"
compile "$w" wrong-colour.car
compile "$f" foreign.car
