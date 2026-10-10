#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# build-app.sh [--version <x.y.z>] [--payload <staged-tree>] <outdir>
#
# Builds "k3sm.app" for arm64 and ad-hoc signs it.
#
#   --version <x.y.z>        stamps CFBundleShortVersionString and
#                            CFBundleVersion (default 0.0.0, a developer build)
#   --payload <staged-tree>  copies a k3sm staged tree (the stage.sh output)
#                            into Contents/Resources/payload and writes its
#                            SHA-256 manifest beside it as payload.sha256
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
set -euo pipefail

usage() {
	echo "usage: hack/build-app.sh [--version <x.y.z>] [--payload <staged-tree>] <outdir>" >&2
	exit 2
}

VERSION=0.0.0
PAYLOAD=
OUTARG=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--version)
		[ "$#" -ge 2 ] || usage
		VERSION="$2"
		shift 2
		;;
	--payload)
		[ "$#" -ge 2 ] || usage
		PAYLOAD="$2"
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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT=K3smApp   # the SwiftPM executable product
EXE=k3sm-app      # the bundle executable (CFBundleExecutable in Resources/Info.plist)

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
fi

mkdir -p "$OUTARG"
OUT="$(cd "$OUTARG" && pwd)"
APP="$OUT/k3sm.app"

echo "==> toolchain"
swift --version 2>&1 | sed 's/^/    /'

echo "==> swift build -c release --arch arm64"
( cd "$ROOT" && swift build -c release --arch arm64 --product "$PRODUCT" )
BIN_DIR="$(cd "$ROOT" && swift build -c release --arch arm64 --show-bin-path)"
[ -x "$BIN_DIR/$PRODUCT" ] || { echo "build-app: $BIN_DIR/$PRODUCT not found" >&2; exit 1; }

echo "==> assemble $APP (version $VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$EXE"
chmod 0755 "$APP/Contents/MacOS/$EXE"
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
fi

echo "==> ad-hoc sign (inside out)"
# Nested code first. The app's own executable is the only code this script
# signs; payload binaries keep the signatures stage.sh gave them, because
# re-signing would change the bytes the manifest describes.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/$EXE"
codesign --force --sign - --timestamp=none "$APP"

echo "==> verify"
codesign --verify --strict --deep --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/$EXE" | grep -qx arm64 \
	|| { echo "build-app: executable is not arm64-only" >&2; exit 1; }
echo "build-app: $APP"
