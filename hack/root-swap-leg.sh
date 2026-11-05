#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# sudo hack/root-swap-leg.sh <scratch-dir> -- the administrator swap's root leg.
#
# Runs one test, appSwapRootLegRealChownAndRenameSwap, as root: a bundle a user
# really owns goes through AdminSwapEngine, with a real chown to uid 0 and a
# real RENAME_SWAP, and the next swap is run over the result. Every path the
# engine touches is under <scratch-dir>, an existing directory on an APFS
# volume, never under /Applications or /Library, and the test refuses those
# too. No other test runs as root, and the app and k3sm on this Mac are not
# touched. The tests are built as the account that ran sudo, and whatever
# SwiftPM writes to .build as root is given back to that account at the end.
#
# Exit 0 means the test ran and passed: a skip is a failure here.
set -euo pipefail

test_name=appSwapRootLegRealChownAndRenameSwap
title='root leg: a bundle a user really owns'

die() {
	echo "root-swap-leg: $*" >&2
	exit 1
}

[ "$#" -eq 1 ] || die "usage: sudo hack/root-swap-leg.sh <scratch-dir>"
[ "$(id -u)" -eq 0 ] || die "run this with sudo"
[ -n "${SUDO_UID:-}" ] && [ "${SUDO_UID:-0}" -ne 0 ] && [ -n "${SUDO_GID:-}" ] || die "run this with sudo from a user account"
[ -d "$1" ] && [ ! -L "$1" ] || die "$1 is not an existing directory"

scratch=$(/usr/bin/realpath "$1")
case "$scratch/" in
/Applications/* | /Library/* | /System/*) die "$scratch is under a folder this leg never touches" ;;
esac

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd "$(dirname "$0")/.."
repo=$PWD

swift_flags=(--disable-sandbox)
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -f "$plugins/libTestingMacros.dylib" ]; then
	swift_flags+=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi

work=$(mktemp -d "$scratch/root-swap-leg.XXXXXXXX")
log="$work/log"
finish() {
	status=$?
	chown -R "$SUDO_UID:$SUDO_GID" "$repo/.build" 2>/dev/null || true
	if [ "$status" -ne 0 ] && [ -f "$log" ]; then cat "$log" >&2; fi
	chflags -R nouchg,nouappnd "$work" 2>/dev/null || true
	rm -rf "$work"
	exit "$status"
}
trap finish EXIT
mkdir -p "$work/home" "$work/tmp"

echo "root-swap-leg: building the tests as uid $SUDO_UID"
sudo -H -u "#$SUDO_UID" -- swift build --build-tests "${swift_flags[@]}"

echo "root-swap-leg: running $test_name as root under $work"
env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work/tmp/" \
	SUDO_UID="$SUDO_UID" SUDO_GID="$SUDO_GID" K3SM_ROOT_SWAP_LEG_SCRATCH="$work" \
	swift test --skip-build "${swift_flags[@]}" --filter "$test_name" > "$log" 2>&1

# A disabled test also exits 0, so the pass line is what counts.
grep -q "Test \"$title.* passed" "$log" || die "the test did not run and pass"
echo "root-swap-leg: passed"
