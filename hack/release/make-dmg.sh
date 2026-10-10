#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# make-dmg.sh <k3sm.app> <out.dmg> -- build the drag-to-install disk image.
#
# The image holds the app and an /Applications symlink, compressed (UDZO).
# It works on an unsigned or ad-hoc signed app; signing, notarizing and
# stapling the image is hack/release/sign-and-notarize.sh, run by a person.
set -euo pipefail

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
	echo "usage: hack/release/make-dmg.sh <k3sm.app> <out.dmg>" >&2
	exit 2
fi
app="$1"
out="$2"
case "$out" in
*.dmg) ;;
*) echo "make-dmg: the output must end in .dmg: $out" >&2; exit 2 ;;
esac
if [ -L "$app" ] || [ ! -d "$app/Contents/MacOS" ]; then
	echo "make-dmg: not an app bundle: $app" >&2
	exit 1
fi

src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT
/usr/bin/ditto --norsrc --noqtn "$app" "$src/k3sm.app"
ln -s /Applications "$src/Applications"

mkdir -p "$(dirname "$out")"
rm -f "$out"
/usr/bin/hdiutil create -quiet -volname k3sm -srcfolder "$src" -fs APFS -format UDZO "$out"
/usr/bin/hdiutil verify -quiet "$out"
echo "make-dmg: $out"
