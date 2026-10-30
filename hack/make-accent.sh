#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# make-accent.sh <out.car>
# make-accent.sh --check <committed.car>
#
# Compiles the app's accent colour (Resources/Assets.car): one colour set,
# AccentColor, with the two values Palette.navy in Sources/K3smApp spells:
# the navy #011389 in light and #7d97ff in dark, the pair the strip's
# icons, the Pods chip and the Settings eyebrows already use. The brighter
# Palette.accent (#022ffb) stays a mark colour: on a filled control it reads
# as a second blue beside the navy. Info.plist names the set
# (NSAccentColorName), so every accent-coloured control in the app, the
# Settings toolbar's selected pane among them, takes the navy while the
# system accent is Multicolour; a system accent the user has chosen still
# wins, as it does in every app.
#
# actool ships with Xcode, not the Command Line Tools, so the generated
# Assets.car is committed and a build needs no regeneration; this script is
# its reproducible source, as hack/make-icon.sh is the icon's. Rerun it
# after the colour changes and commit the result.
#
# actool stamps the time of the run into the file, so two runs are not the
# same bytes. --check compiles the catalog afresh and compares what the two
# files hold (assetutil --info, the Timestamp line aside): the same colour
# set, names, appearances and components, or it fails. That is the check a
# reviewer runs against the committed file.
set -euo pipefail

usage() {
	echo "usage: hack/make-accent.sh <out.car> | --check <committed.car>" >&2
	exit 2
}
CHECK=
case "${1:-}" in
	--check) CHECK=1; shift ;;
esac
[ "$#" -eq 1 ] || usage
OUT="$1"
case "$OUT" in *.car) ;; *) echo "make-accent: the file must end in .car: $OUT" >&2; exit 2;; esac
if [ -n "$CHECK" ] && [ ! -f "$OUT" ]; then
	echo "make-accent: no such file: $OUT" >&2
	exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Accent.xcassets/AccentColor.colorset" "$work/out"
printf '%s\n' '{"info":{"author":"xcode","version":1}}' > "$work/Accent.xcassets/Contents.json"
cat > "$work/Accent.xcassets/AccentColor.colorset/Contents.json" <<'JSON'
{"colors":[{"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"0x89","green":"0x13","red":"0x01"}},"idiom":"universal"},{"appearances":[{"appearance":"luminosity","value":"dark"}],"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"0xFF","green":"0x97","red":"0x7D"}},"idiom":"universal"}],"info":{"author":"xcode","version":1}}
JSON
actool="$(xcrun --find actool 2>/dev/null || true)"
[ -n "$actool" ] || { echo "make-accent: actool not found; it ships with Xcode (xcode-select -s /Applications/Xcode.app)" >&2; exit 1; }
"$actool" --compile "$work/out" --platform macosx --minimum-deployment-target 26.0 \
	--output-format human-readable-text --output-partial-info-plist "$work/partial.plist" "$work/Accent.xcassets" > /dev/null
if [ -n "$CHECK" ]; then
	# What each file holds, the run's timestamp left out.
	contents() { /usr/bin/assetutil --info "$1" | grep -v '"Timestamp"'; }
	if diff <(contents "$OUT") <(contents "$work/out/Assets.car") > "$work/diff"; then
		echo "make-accent: $OUT holds what the script compiles"
	else
		echo "make-accent: $OUT differs from what the script compiles:" >&2
		cat "$work/diff" >&2
		exit 1
	fi
	exit 0
fi
cp "$work/out/Assets.car" "$OUT"
echo "make-accent: wrote $OUT"
