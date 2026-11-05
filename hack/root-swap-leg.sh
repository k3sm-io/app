#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# sudo hack/root-swap-leg.sh <scratch-dir> -- the administrator swap's root leg.
# hack/root-swap-leg.sh --self-test        -- its refusals, as any account.
#
# Runs one test, appSwapRootLegRealChownAndRenameSwap, as root: a bundle a user
# really owns goes through AdminSwapEngine, with a real chown to uid 0 and a
# real RENAME_SWAP, and the next swap is run over the result. Every path the
# engine touches is under <scratch-dir>, which must be an existing directory
# inside the home folder of the account that ran sudo, owned by that account.
# The test refuses /Applications, /Library and /System too. No other test runs
# as root, and the app and k3sm on this Mac are not touched.
#
# The tests are built as that account. As root, the home folder, TMPDIR and
# SwiftPM's cache, config and security paths all sit in a private work directory
# under <scratch-dir>, removed at the end. What SwiftPM writes to .build as root is
# given back to that account, and the run fails if the repository or SwiftPM's
# usual folders still hold anything root owns.
#
# Exit 0 means the test ran and passed: a skip is a failure here.
set -euo pipefail

test_name=appSwapRootLegRealChownAndRenameSwap
title='root leg: a bundle a user really owns'

die() {
	echo "root-swap-leg: $*" >&2
	exit 1
}

# check_scratch <path> <home> <uid>: prints the resolved path when it is an
# existing directory, not a symlink, strictly inside <home>, owned by <uid>.
check_scratch() {
	[ -d "$1" ] && [ ! -L "$1" ] || die "$1 is not an existing directory"
	local path home
	path=$(/bin/realpath "$1")
	home=$(/bin/realpath "$2")
	case "$path" in
	"$home"/*) ;;
	*) die "$path is not inside $home" ;;
	esac
	[ "$(/usr/bin/stat -f %u "$path")" = "$3" ] || die "$path is not owned by uid $3"
	printf '%s\n' "$path"
}

# check_build <repo>: refuses a .build that is a symlink.
check_build() {
	if [ -L "$1/.build" ]; then die "$1/.build is a symlink"; fi
}

# owned_by <uid> <newer-than, or empty> <path>...: prints the first entry under
# the existing paths that <uid> owns, optionally only those newer than a file.
owned_by() {
	local uid=$1 newer=$2 path
	shift 2
	for path in "$@"; do
		[ -e "$path" ] || continue
		if [ -n "$newer" ]; then
			/usr/bin/find "$path" -user "$uid" -newer "$newer" -print -quit
		else
			/usr/bin/find "$path" -user "$uid" -print -quit
		fi
	done | /usr/bin/head -n 1
}

self_test() {
	local dir me failed=0
	dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/root-swap-leg-test.XXXXXXXX")
	dir=$(/bin/realpath "$dir")
	trap '/bin/rm -rf "$dir"' RETURN
	me=$(/usr/bin/id -u)
	mkdir -p "$dir/home/scratch" "$dir/elsewhere" "$dir/repo-link/real" "$dir/repo-plain/.build" "$dir/tree"
	ln -s "$dir/home/scratch" "$dir/home/link"
	ln -s "$dir/elsewhere" "$dir/home/escape"
	ln -s real "$dir/repo-link/.build"
	: > "$dir/tree/file"

	expect() { # expect <pass|fail> <name> <command...>
		local want=$1 name=$2 got=pass
		shift 2
		("$@") > /dev/null 2>&1 || got=fail
		if [ "$got" != "$want" ]; then
			echo "root-swap-leg: self-test: $name: wanted $want, got $got" >&2
			failed=1
		fi
	}
	expect pass "a directory in the home owned by the account" check_scratch "$dir/home/scratch" "$dir/home" "$me"
	expect fail "the home itself" check_scratch "$dir/home" "$dir/home" "$me"
	expect fail "a directory outside the home" check_scratch "$dir/elsewhere" "$dir/home" "$me"
	expect fail "a symlink in the home" check_scratch "$dir/home/link" "$dir/home" "$me"
	expect fail "a symlink out of the home" check_scratch "$dir/home/escape" "$dir/home" "$me"
	expect fail "a directory another account owns" check_scratch "$dir/home/scratch" "$dir/home" "$((me + 1))"
	expect fail "a missing directory" check_scratch "$dir/home/none" "$dir/home" "$me"
	expect fail "a .build that is a symlink" check_build "$dir/repo-link"
	expect pass "a .build that is a directory" check_build "$dir/repo-plain"
	[ -n "$(owned_by "$me" '' "$dir/tree")" ] || { echo "root-swap-leg: self-test: owned_by missed an entry" >&2; failed=1; }
	[ -z "$(owned_by "$((me + 1))" '' "$dir/tree")" ] || { echo "root-swap-leg: self-test: owned_by named another account's entry" >&2; failed=1; }
	[ -z "$(owned_by "$me" '' "$dir/none")" ] || { echo "root-swap-leg: self-test: owned_by named a missing path" >&2; failed=1; }
	: > "$dir/marker"
	[ -z "$(owned_by "$me" "$dir/marker" "$dir/tree")" ] || { echo "root-swap-leg: self-test: owned_by ignored the marker" >&2; failed=1; }
	if [ "$failed" -ne 0 ]; then exit 1; fi
	echo "root-swap-leg: self-test passed"
}

if [ "$#" -eq 1 ] && [ "$1" = --self-test ]; then
	self_test
	exit 0
fi

[ "$#" -eq 1 ] || die "usage: sudo hack/root-swap-leg.sh <scratch-dir>"
[ "$(id -u)" -eq 0 ] || die "run this with sudo"
[ -n "${SUDO_UID:-}" ] && [ "${SUDO_UID:-0}" -ne 0 ] && [ -n "${SUDO_GID:-}" ] || die "run this with sudo from a user account"

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
sudo_name=$(id -un "$SUDO_UID")
user_home=$(dscl . -read "/Users/$sudo_name" NFSHomeDirectory | awk '{ print $2 }')
[ -n "$user_home" ] && [ -d "$user_home" ] || die "no home folder for uid $SUDO_UID"
scratch=$(check_scratch "$1" "$user_home" "$SUDO_UID") || exit 1

cd "$(dirname "$0")/.."
repo=$PWD
check_build "$repo"

swift_flags=(--disable-sandbox)
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -f "$plugins/libTestingMacros.dylib" ]; then
	swift_flags+=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi

work=$(mktemp -d "$scratch/root-swap-leg.XXXXXXXX")
log="$work/log"
marker="$work/marker"
finish() {
	status=$?
	if [ -L "$repo/.build" ]; then
		echo "root-swap-leg: $repo/.build became a symlink; it was not chowned" >&2
		status=1
	else
		chown -hR "$SUDO_UID:$SUDO_GID" "$repo/.build" 2>/dev/null || true
	fi
	if [ "$status" -ne 0 ] && [ -f "$log" ]; then cat "$log" >&2; fi
	left=$(owned_by 0 '' "$repo")
	if [ -n "$left" ]; then
		echo "root-swap-leg: root still owns $left in the repository" >&2
		status=1
	fi
	if [ -f "$marker" ]; then
		left=$(owned_by 0 "$marker" "$user_home/.swiftpm" "$user_home/Library/Caches/org.swift.swiftpm" \
			"$user_home/Library/org.swift.swiftpm" /var/root/.swiftpm /var/root/Library/Caches/org.swift.swiftpm \
			/var/root/Library/org.swift.swiftpm /var/root/Library/Developer/DVTDownloads)
		if [ -n "$left" ]; then
			echo "root-swap-leg: this run left $left, owned by root, outside its work directory" >&2
			status=1
		fi
	fi
	chflags -R nouchg,nouappnd "$work" 2>/dev/null || true
	rm -rf "$work"
	exit "$status"
}
trap finish EXIT
mkdir -p "$work/home" "$work/tmp" "$work/swiftpm/cache" "$work/swiftpm/config" "$work/swiftpm/security"
: > "$marker"

echo "root-swap-leg: building the tests as uid $SUDO_UID"
sudo -H -u "#$SUDO_UID" -- swift build --build-tests "${swift_flags[@]}"
check_build "$repo"

echo "root-swap-leg: running $test_name as root under $work"
# SwiftPM finds its home folder from the account, not from HOME, so
# CFFIXED_USER_HOME is what keeps its folders out of /var/root. xcrun_nocache
# keeps the /usr/bin tool shims from writing their lookup cache to root's own
# temporary folder.
env -i PATH="$PATH" HOME="$work/home" CFFIXED_USER_HOME="$work/home" TMPDIR="$work/tmp/" xcrun_nocache=1 \
	SUDO_UID="$SUDO_UID" SUDO_GID="$SUDO_GID" K3SM_ROOT_SWAP_LEG_SCRATCH="$work" \
	swift test --skip-build "${swift_flags[@]}" \
	--cache-path "$work/swiftpm/cache" --config-path "$work/swiftpm/config" --security-path "$work/swiftpm/security" \
	--filter "$test_name" > "$log" 2>&1

# A disabled test also exits 0, so the pass line is what counts.
grep -q "Test \"$title.* passed" "$log" || die "the test did not run and pass"
echo "root-swap-leg: passed"
