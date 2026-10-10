#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# sign-and-notarize.sh <k3sm.app> <out.dmg> <identity> <team-id>
#
# The release signing step, run by a person at the build Mac:
#
#   1. check that every Mach-O in the payload already carries a Developer ID
#      signature from <team-id> (the payload is signed before
#      build-app.sh --payload, so the manifest describes signed bytes)
#   2. stamp the Team ID into Info.plist (K3smTeamID) for the app's own
#      signature check
#   3. sign the app inside out with <identity>, the hardened runtime and a
#      secure timestamp, then verify it against the designated requirement
#   4. notarize the app (notarytool, keychain profile k3sm-notary) and staple
#   5. build the disk image, sign it, notarize it and staple it
#   6. print the image's SHA-256
#
# <identity> names a Developer ID Application certificate in the keychain,
# for example "Developer ID Application: Example (ABCDE12345)". The script
# references the identity and the notary profile by name only; it never
# reads, prints or stores a secret.
#
# It refuses to run unattended: from an agent session (CLAUDECODE), from the
# autonomous loop (K3SM_AUTO), or without a terminal on stdin.
set -euo pipefail

refuse() {
	echo "sign-and-notarize: refused: $1. Signing is a human step; run it yourself in a terminal." >&2
	exit 3
}
[ -z "${CLAUDECODE:-}" ] || refuse "CLAUDECODE is set (an agent session)"
[ -z "${K3SM_AUTO:-}" ] || refuse "K3SM_AUTO is set (the autonomous loop)"
[ -t 0 ] || refuse "stdin is not a terminal"

if [ "$#" -ne 4 ]; then
	echo "usage: hack/release/sign-and-notarize.sh <k3sm.app> <out.dmg> <identity> <team-id>" >&2
	exit 2
fi
app="$1"
dmg="$2"
identity="$3"
team="$4"
printf '%s\n' "$team" | grep -Eqx '[A-Z0-9]{10}' || { echo "sign-and-notarize: not a Team ID: $team" >&2; exit 2; }
[ -d "$app/Contents/MacOS" ] && [ ! -L "$app" ] || { echo "sign-and-notarize: not an app bundle: $app" >&2; exit 2; }
case "$dmg" in *.dmg) ;; *) echo "sign-and-notarize: the output must end in .dmg: $dmg" >&2; exit 2 ;; esac

PROFILE=k3sm-notary
HERE="$(cd "$(dirname "$0")" && pwd)"
requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$team\""
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> check payload signatures"
if [ -d "$app/Contents/Resources/payload" ]; then
	while IFS= read -r -d '' f; do
		if /usr/bin/file -b "$f" | grep -q 'Mach-O'; then
			/usr/bin/codesign --verify --strict -R="$requirement" "$f" \
				|| { echo "sign-and-notarize: payload binary is not Developer ID signed by $team: $f" >&2; exit 1; }
		fi
	done < <(/usr/bin/find "$app/Contents/Resources/payload" -type f -print0)
fi

echo "==> stamp K3smTeamID"
/usr/bin/plutil -replace K3smTeamID -string "$team" "$app/Contents/Info.plist"

echo "==> sign the app (inside out, hardened runtime, timestamp)"
/usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/MacOS/k3sm-app"
/usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$app"
/usr/bin/codesign --verify --strict --deep -R="$requirement" "$app"

echo "==> notarize and staple the app"
/usr/bin/ditto -c -k --keepParent "$app" "$work/k3sm.zip"
/usr/bin/xcrun notarytool submit "$work/k3sm.zip" --keychain-profile "$PROFILE" --wait
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"

echo "==> build, sign, notarize and staple the disk image"
"$HERE/make-dmg.sh" "$app" "$dmg"
/usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"
/usr/bin/codesign --verify --strict -R="$requirement" "$dmg"
/usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$PROFILE" --wait
/usr/bin/xcrun stapler staple "$dmg"
/usr/bin/xcrun stapler validate "$dmg"

echo "==> sha256"
/usr/bin/shasum -a 256 "$dmg"
