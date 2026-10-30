#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# build-app.sh [--version <x.y.z>] [--team-id <ID> | --rehearsal] [--payload <staged-tree>]
#              [--payload-tag <tag> [--payload-release <seal>]] <outdir>
#
# Builds "k3sm.app" for arm64 and ad-hoc signs it. The bundle holds the app
# (Contents/MacOS/k3sm-app), the read-only MCP server beside it
# (Contents/MacOS/k3sm-mcp) and the self-update's swap helper
# (Contents/Helpers/k3sm-app-update, signed as io.k3sm.app.update).
#
#   --version <x.y.z>        stamps CFBundleShortVersionString and
#                            CFBundleVersion, a release build. Without it
#                            both are 0.0.0 (a developer build: macOS takes
#                            digits only there) and Info.plist gains
#                            K3smBuildVersion, the pseudo-version
#                            hack/build-version.sh computes from the checkout
#                            (v0.0.0-0.20261016221530-2eda966a1b2c, +dirty
#                            for a modified tree, v0.0.0-unknown outside a
#                            git checkout). A release build carries no
#                            K3smBuildVersion.
#   --team-id <ID>           compiles the Developer ID Team ID the root step
#                            pins into the binary (TeamIDPin). The build runs
#                            from a copy of the source under .build/pinned-src
#                            whose Sources/K3smInstall/TeamIDStamp.swift carries
#                            the ID; the checkout is never modified. Without it
#                            the build pins no team and the app disables every
#                            privileged action, saying why. The Team ID is
#                            never written to Info.plist.
#   --rehearsal              sets the bundle id io.k3sm.app.rehearsal, for the
#                            unsigned release rehearsal
#                            (hack/release/release.sh --rehearsal); refused
#                            with --team-id, so a rehearsal app pins no team
#   --payload <staged-tree>  copies a k3sm staged tree (the stage.sh output)
#                            into Contents/Resources/payload and writes its
#                            SHA-256 manifest beside it as payload.sha256
#   --payload-tag <tag>      stamps K3smPayloadTag in Info.plist with the exact
#                            release tag of the payload (v0.2.0-rc.1 for a
#                            release candidate, v0.2.0 for the final), which
#                            the short version cannot carry: macOS takes digits
#                            only there, so an rc and its final share x.y.z.
#                            Needs --version and --payload; the tag must be
#                            vMAJOR.MINOR.PATCH[-rc.N] with the core version
#                            --version names (hack/release/payload-release.sh
#                            check-tag). The app reads it as the release it
#                            carries (AppVersion.payloadRelease) and as its
#                            own downgrade floor.
#   --payload-release <seal> writes Contents/Resources/payload.release (the tag,
#                            tarball_sha256 and payload_manifest_sha256) from
#                            the seal k3sm's publish.sh --through-verify wrote
#                            beside the staged tree, refusing unless the seal
#                            names the --payload-tag tag and its manifest hash
#                            is the SHA-256 of the payload's PAYLOAD-SHA256
#                            (hack/release/payload-release.sh write). Needs
#                            --payload-tag.
#
# Info.plist and every file under Contents/Resources are sealed by the bundle
# signature, so K3smPayloadTag and payload.release are covered by it.
#
# The payload is refused before anything is built if it holds a symlink, a
# special file, a setuid or setgid file, a group- or other-writable entry, or
# no executable k3sm at its root. Its bytes are copied without extended
# attributes and never modified, so the manifest describes exactly what the
# staged tree held.
#
# Signing is ad-hoc and inside out (nested code first, the bundle root last,
# never --deep for signing). Developer ID signing and notarization are
# hack/release/sign-and-notarize.sh, run by a person.
#
# K3SM_SWIFTPM_DISABLE_SANDBOX=1 passes --disable-sandbox to every swift build
# run. SwiftPM applies its own sandbox when it compiles the manifest and builds,
# and a process already inside a sandbox cannot apply another one
# (sandbox_apply: Operation not permitted). A sandboxed caller sets this to turn
# off the inner sandbox and keep its own. Unset, nothing changes. This script
# runs standalone, so it reads the variable itself rather than relying on ci.sh.
set -euo pipefail

usage() {
	echo "usage: hack/build-app.sh [--version <x.y.z>] [--team-id <ID> | --rehearsal] [--payload <staged-tree>] [--payload-tag <tag> [--payload-release <seal>]] <outdir>" >&2
	exit 2
}

VERSION=0.0.0
RELEASE=
TEAM_ID=
PAYLOAD=
PAYLOAD_TAG=
PAYLOAD_SEAL=
OUTARG=
BUNDLE_ID=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--version)
		[ "$#" -ge 2 ] || usage
		VERSION="$2"
		RELEASE=1
		shift 2
		;;
	--team-id)
		[ "$#" -ge 2 ] || usage
		TEAM_ID="$2"
		shift 2
		;;
	--rehearsal)
		BUNDLE_ID=io.k3sm.app.rehearsal
		shift
		;;
	--payload)
		[ "$#" -ge 2 ] || usage
		PAYLOAD="$2"
		shift 2
		;;
	--payload-tag)
		[ "$#" -ge 2 ] || usage
		PAYLOAD_TAG="$2"
		shift 2
		;;
	--payload-release)
		[ "$#" -ge 2 ] || usage
		PAYLOAD_SEAL="$2"
		shift 2
		;;
	-*) usage ;;
	*)
		[ -z "$OUTARG" ] || usage
		OUTARG="$1"
		shift
		;;
	esac
done
[ -n "$OUTARG" ] || usage

if ! printf '%s\n' "$VERSION" | grep -Eqx '(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})'; then
	echo "build-app: refused: --version must be x.y.z (digits only), got: $VERSION" >&2
	exit 2
fi

if [ -n "$TEAM_ID" ] && ! printf '%s\n' "$TEAM_ID" | grep -Eqx '[A-Z0-9]{10}'; then
	echo "build-app: refused: --team-id must be ten uppercase letters or digits, got: $TEAM_ID" >&2
	exit 2
fi

if [ -n "$TEAM_ID" ] && [ -n "$BUNDLE_ID" ]; then
	echo "build-app: refused: --rehearsal pins no Team ID; drop --team-id" >&2
	exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD_RELEASE_SH="$ROOT/hack/release/payload-release.sh"

if [ -n "$PAYLOAD_TAG" ]; then
	if [ -z "$RELEASE" ] || [ -z "$PAYLOAD" ]; then
		echo "build-app: refused: --payload-tag needs --version and --payload (it names the payload's release)" >&2
		exit 2
	fi
	bash "$PAYLOAD_RELEASE_SH" check-tag "$PAYLOAD_TAG" "$VERSION" || exit 2
fi
if [ -n "$PAYLOAD_SEAL" ] && [ -z "$PAYLOAD_TAG" ]; then
	echo "build-app: refused: --payload-release needs --payload-tag" >&2
	exit 2
fi

BUILD_VERSION=
if [ -z "$RELEASE" ]; then
	BUILD_VERSION="$(bash "$ROOT/hack/build-version.sh" "$ROOT")"
fi
PRODUCT=K3smApp   # the SwiftPM executable product
EXE=k3sm-app      # the bundle executable (CFBundleExecutable in Resources/Info.plist)
MCP=k3sm-mcp      # the read-only MCP server, product and file name alike
MCP_ID=io.k3sm.app.mcp   # its code signing identifier
HELPER=k3sm-app-update   # the swap helper, product and file name alike
HELPER_ID=io.k3sm.app.update   # its code signing identifier (AppUpdateTrust.helperIdentifier)
SWIFT_FLAGS=()
if [ "${K3SM_SWIFTPM_DISABLE_SANDBOX:-}" = 1 ]; then
	SWIFT_FLAGS=(--disable-sandbox)
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "$PAYLOAD" ]; then
	echo "==> payload $PAYLOAD"
	if [ -L "$PAYLOAD" ] || [ ! -d "$PAYLOAD" ]; then
		echo "build-app: refused: --payload must be a directory, not a symlink: $PAYLOAD" >&2
		exit 1
	fi
	# Check the source, then copy and check the copy, so the checked bytes are
	# the bytes that ship. ditto copies a symlink as a symlink but may drop a
	# setuid bit, which is why the source is checked too.
	refuse_unsafe() {
		local bad
		bad="$(cd "$1" && /usr/bin/find . \( ! \( -type f -o -type d \) -o -perm +6022 \) -print)"
		if [ -n "$bad" ]; then
			echo "build-app: refused: the payload holds symlinks, special files, setuid or setgid files, or group/other-writable entries:" >&2
			printf '%s\n' "$bad" | sed 's/^/    /' >&2
			exit 1
		fi
	}
	refuse_unsafe "$PAYLOAD"
	/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$PAYLOAD" "$work/payload"
	refuse_unsafe "$work/payload"
	while IFS= read -r -d '' name; do
		case "$name" in
		*[[:cntrl:]]* | *\\*)
			echo "build-app: refused: payload file names may not contain control characters or backslashes" >&2
			exit 1
			;;
		esac
	done < <(cd "$work/payload" && /usr/bin/find . -print0)
	if [ ! -f "$work/payload/k3sm" ] || [ ! -x "$work/payload/k3sm" ]; then
		echo "build-app: refused: the payload has no executable k3sm at its root" >&2
		exit 1
	fi
	# The release record is written from the checked copy before anything is
	# built, so a seal that does not match refuses early.
	if [ -n "$PAYLOAD_SEAL" ]; then
		bash "$PAYLOAD_RELEASE_SH" write "$PAYLOAD_SEAL" "$PAYLOAD_TAG" \
			"$work/payload/PAYLOAD-SHA256" "$work/payload.release" || exit 1
	fi
fi

mkdir -p "$OUTARG"
OUT="$(cd "$OUTARG" && pwd)"
APP="$OUT/k3sm.app"

echo "==> toolchain"
swift --version 2>&1 | sed 's/^/    /'

# SRC is the package the build compiles: the checkout itself, or, with
# --team-id, a copy whose only difference is the generated stamp file.
SRC="$ROOT"
if [ -n "$TEAM_ID" ]; then
	SRC="$ROOT/.build/pinned-src"
	echo "==> pinned source copy $SRC (team $TEAM_ID)"
	mkdir -p "$SRC"
	rm -rf "$SRC/Sources" "$SRC/Resources" "$SRC/Tests"
	cp "$ROOT/Package.swift" "$SRC/Package.swift"
	cp -R "$ROOT/Sources" "$SRC/Sources"
	cp -R "$ROOT/Resources" "$SRC/Resources"
	cp -R "$ROOT/Tests" "$SRC/Tests"   # Package.swift declares the test targets
	{
		echo '// Generated by hack/build-app.sh --team-id; never committed.'
		echo 'enum TeamIDStamp {'
		echo "    static let value = \"k3sm-team-id-pin:$TEAM_ID\""
		echo '}'
	} > "$SRC/Sources/K3smInstall/TeamIDStamp.swift"
fi

echo "==> swift build -c release --arch arm64"
# ${arr[@]+"${arr[@]}"} expands to nothing for an empty array; macOS bash 3.2
# treats a bare "${arr[@]}" on an empty array as unbound under set -u.
( cd "$SRC" && swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} -c release --arch arm64 --product "$PRODUCT" )
( cd "$SRC" && swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} -c release --arch arm64 --product "$MCP" )
( cd "$SRC" && swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} -c release --arch arm64 --product "$HELPER" )
BIN_DIR="$(cd "$SRC" && swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} -c release --arch arm64 --show-bin-path)"
[ -x "$BIN_DIR/$PRODUCT" ] || { echo "build-app: $BIN_DIR/$PRODUCT not found" >&2; exit 1; }
[ -x "$BIN_DIR/$MCP" ] || { echo "build-app: $BIN_DIR/$MCP not found" >&2; exit 1; }
[ -x "$BIN_DIR/$HELPER" ] || { echo "build-app: $BIN_DIR/$HELPER not found" >&2; exit 1; }

echo "==> assemble $APP (version $VERSION${BUILD_VERSION:+, build $BUILD_VERSION}${PAYLOAD_TAG:+, payload tag $PAYLOAD_TAG})"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
[ -z "$BUILD_VERSION" ] || plutil -replace K3smBuildVersion -string "$BUILD_VERSION" "$APP/Contents/Info.plist"
[ -z "$PAYLOAD_TAG" ] || plutil -replace K3smPayloadTag -string "$PAYLOAD_TAG" "$APP/Contents/Info.plist"
[ -z "$BUNDLE_ID" ] || plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$EXE"
# The MCP server sits beside the app's executable, so the bundle's signature
# seals it and an update of k3sm (under /Library/k3sm) never replaces it.
cp "$BIN_DIR/$MCP" "$APP/Contents/MacOS/$MCP"
chmod 0755 "$APP/Contents/MacOS/$MCP"
# The swap helper: the app copies it out of the bundle before running it, so
# it can rename the whole bundle while the helper runs.
cp "$BIN_DIR/$HELPER" "$APP/Contents/Helpers/$HELPER"
chmod 0755 "$APP/Contents/Helpers/$HELPER"
# The app icon (CFBundleIconFile AppIcon), generated by hack/make-icon.sh.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The accent colour (NSAccentColorName AccentColor), generated by hack/make-accent.sh.
cp "$ROOT/Resources/Assets.car" "$APP/Contents/Resources/Assets.car"
chmod 0755 "$APP/Contents/MacOS/$EXE"
# The demo tours (hack/demo/*.json), so an installed app runs its own
# release tour by name (--demo-tour release-tour). Only small .json files.
mkdir -p "$APP/Contents/Resources/demo"
for f in "$ROOT"/hack/demo/*; do
	[ -e "$f" ] || continue
	case "$f" in *.json) ;; *) echo "build-app: refused: hack/demo holds a non-.json file: $f" >&2; exit 1;; esac
	[ -f "$f" ] && [ ! -L "$f" ] || { echo "build-app: refused: not a regular file: $f" >&2; exit 1; }
	[ "$(wc -c < "$f")" -le 65536 ] || { echo "build-app: refused: demo tour over 64 KiB: $f" >&2; exit 1; }
	cp "$f" "$APP/Contents/Resources/demo/"
done
plutil -lint "$APP/Contents/Info.plist" >/dev/null
[ "$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")" = "$EXE" ] \
	|| { echo "build-app: Info.plist CFBundleExecutable is not $EXE" >&2; exit 1; }

if [ -n "$PAYLOAD" ]; then
	echo "==> payload manifest"
	mv "$work/payload" "$APP/Contents/Resources/payload"
	# One line per regular file, "<sha256>  <path relative to payload/>",
	# sorted bytewise so the manifest is reproducible.
	( cd "$APP/Contents/Resources/payload" \
		&& /usr/bin/find . -type f -print0 | LC_ALL=C sort -z | xargs -0 /usr/bin/shasum -a 256 ) \
		| sed 's|  \./|  |' > "$APP/Contents/Resources/payload.sha256"
	echo "    $(wc -l < "$APP/Contents/Resources/payload.sha256" | tr -d ' ') files"
	if [ -n "$PAYLOAD_SEAL" ]; then
		mv "$work/payload.release" "$APP/Contents/Resources/payload.release"
		echo "    payload.release: $PAYLOAD_TAG"
	fi
fi

echo "==> ad-hoc sign (inside out)"
# Nested code first: the MCP server and the swap helper, then the app's own
# executable, then the bundle root. Payload binaries are not re-signed: they
# keep the signatures stage.sh gave them, because re-signing would change the
# bytes the manifest describes.
codesign --force --sign - --timestamp=none --identifier "$MCP_ID" "$APP/Contents/MacOS/$MCP"
codesign --force --sign - --timestamp=none --identifier "$HELPER_ID" "$APP/Contents/Helpers/$HELPER"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/$EXE"
codesign --force --sign - --timestamp=none "$APP"

echo "==> verify"
codesign --verify --strict --deep --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/$EXE" | grep -qx arm64 \
	|| { echo "build-app: executable is not arm64-only" >&2; exit 1; }
codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/$MCP"
lipo -archs "$APP/Contents/MacOS/$MCP" | grep -qx arm64 \
	|| { echo "build-app: $MCP is not arm64-only" >&2; exit 1; }
codesign --verify --strict --verbose=2 -R="identifier \"$HELPER_ID\"" "$APP/Contents/Helpers/$HELPER"
lipo -archs "$APP/Contents/Helpers/$HELPER" | grep -qx arm64 \
	|| { echo "build-app: $HELPER is not arm64-only" >&2; exit 1; }
if [ -n "$TEAM_ID" ]; then
	bash "$ROOT/hack/check-team-pin.sh" "$APP/Contents/MacOS/$EXE" "$TEAM_ID" > /dev/null \
		|| { echo "build-app: the executable is not pinned to exactly $TEAM_ID" >&2; exit 1; }
	bash "$ROOT/hack/check-team-pin.sh" "$APP/Contents/MacOS/$MCP" "$TEAM_ID" > /dev/null \
		|| { echo "build-app: $MCP is not pinned to exactly $TEAM_ID" >&2; exit 1; }
	bash "$ROOT/hack/check-team-pin.sh" "$APP/Contents/Helpers/$HELPER" "$TEAM_ID" > /dev/null \
		|| { echo "build-app: $HELPER is not pinned to exactly $TEAM_ID" >&2; exit 1; }
	echo "    team pin: $TEAM_ID"
else
	echo "    team pin: none (a developer build; privileged actions stay disabled)"
fi
echo "build-app: $APP"
