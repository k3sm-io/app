#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-shipped-helper.sh [--self-test]
#
# Runs the swap helper exactly as a release ships it, not a test build. The
# Swift tests drive the swap engine with an injected requirement; this check
# covers the binary those tests do not reach:
#
#   1. build: hack/build-app.sh --version 1.2.3 --team-id ABCDE12345, the
#      release build path, so the helper carries the compiled Team ID pin and
#      the compiled helper and app requirements, and has no test seam (the
#      helper builds its engine from the compiled requirements only). The
#      Team ID is a fixture: no Developer ID is used, read or needed.
#   2. sign: the helper is re-signed ad-hoc with the flags
#      hack/release/sign-and-notarize.sh gives it (--options runtime and the
#      identifier io.k3sm.app.update), with "-" as the identity. That script
#      must still carry the same codesign line, so a change there reds here.
#   3. the signature: codesign -d --entitlements shows no entitlements, the
#      CodeDirectory flags carry "runtime" (the hardened runtime), the
#      identifier is io.k3sm.app.update, and the stamp pins exactly the
#      fixture team (hack/check-team-pin.sh).
#   4. refusals: the helper is run in each of its three modes (--swap,
#      --go-back, --relaunch) against each ad-hoc signed fixture below, and
#      must refuse every run: exit 64 (refusedRequest) with a
#      "k3sm-app-update: refused:" line, or exit 65 (verificationFailed). The
#      fixture tree must be unchanged afterwards, byte for byte and entry for
#      entry, and nothing may appear under the account's real
#      ~/Library/Application Support/io.k3sm.app.
#
#        loose      the helper as a loose file in a temp directory
#        in-bundle  the helper in place in the ad-hoc signed release bundle,
#                   at Contents/Helpers/k3sm-app-update
#        fake-home  a fake home laid out as an update would leave it: the
#                   0700 private directory holding the helper copy and a
#                   request naming an ad-hoc signed staged bundle beside an
#                   ad-hoc signed target, run with HOME pointing at it
#
#      The helper takes its paths from the account's passwd entry, never from
#      HOME, so the fake home cannot redirect it, and it refuses to run from
#      any place but its copy in the account's own private directory. That
#      refusal comes before it reads any bundle. This check never writes into
#      the real home, so the helper's own requirement check and its bundle
#      verifier are not reached here: those need a Developer ID signed helper
#      and are covered by the attended release verification.
#
# --self-test needs no build. It runs the same checks against stand-ins and
# requires each check to fail on the stand-in that breaks it: a helper that
# exits 0 (accepts), one that exits 64 with no refusal line, one that
# refuses but changes the fixture tree, one signed without the hardened
# runtime, and one signed with an entitlement. A stand-in that refuses
# properly and one signed with the hardened runtime and no entitlements must
# pass, so the checks are not vacuous in either direction.
#
# K3SM_SWIFTPM_DISABLE_SANDBOX=1 is read by hack/build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=ABCDE12345
HELPER_ID=io.k3sm.app.update
MODES="--swap --go-back --relaunch"
SUPPORT="Library/Application Support/io.k3sm.app"
# The codesign line hack/release/sign-and-notarize.sh signs the helper with.
# shellcheck disable=SC2016 # the literal text of the line, unexpanded
SIGN_LINE='/usr/bin/codesign --force --options runtime "$SIGN_TIMESTAMP" --identifier io.k3sm.app.update --sign "$SIGN_IDENTITY" "$f"'

# release_sign <file>: the release signing of the helper, ad-hoc.
release_sign() {
	/usr/bin/codesign --force --options runtime --timestamp=none --identifier "$HELPER_ID" --sign - "$1" 2>/dev/null
}

# check_signature <file>: no entitlements, the hardened runtime, the helper's
# identifier. Prints the reason and returns 1 on a failure.
check_signature() {
	local f="$1" ents info flags
	ents="$(/usr/bin/codesign -d --entitlements - --xml "$f" 2>/dev/null)" \
		|| { echo "    codesign -d --entitlements could not read $f"; return 1; }
	[ -z "$ents" ] || { echo "    entitlements present: $ents"; return 1; }
	info="$(/usr/bin/codesign -dv "$f" 2>&1)" || { echo "    codesign -dv could not read $f"; return 1; }
	flags="$(sed -n 's/^CodeDirectory .* flags=\(0x[0-9a-f]*([^)]*)\).*/\1/p' <<<"$info")"
	[ -n "$flags" ] || { echo "    no CodeDirectory flags in codesign -dv"; return 1; }
	grep -Eq '[(,]runtime[,)]' <<<"$flags" || { echo "    no hardened runtime: flags=$flags"; return 1; }
	grep -qx "Identifier=$HELPER_ID" <<<"$info" || { echo "    identifier is not $HELPER_ID"; return 1; }
	echo "    flags=$flags, no entitlements, Identifier=$HELPER_ID"
}

# snapshot <dir>: every entry's path, type, mode, owner, size and mtime, and
# every regular file's SHA-256, sorted.
snapshot() {
	(cd "$1" && /usr/bin/find . -exec /usr/bin/stat -f '%N %HT %Lp %u %z %m' {} + | LC_ALL=C sort \
		&& /usr/bin/find . -type f -print0 | LC_ALL=C sort -z | xargs -0 /usr/bin/shasum -a 256)
}

# real_support_state: what the account's real support directory looks like,
# so a run that created or changed it is caught.
real_support_state() {
	local home
	home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')"
	[ -n "$home" ] || home="$(eval echo "~$(id -un)")"
	if [ -e "$home/$SUPPORT" ]; then
		/usr/bin/find "$home/$SUPPORT" -exec /usr/bin/stat -f '%N %HT %Lp %z %m' {} + 2>&1 | LC_ALL=C sort
	else
		echo "absent: $home/$SUPPORT"
	fi
}

# expect_refused <name> <helper> <fixture-root> <mode> [env...]: runs the
# helper once and requires a refusal that left the fixture tree and the real
# support directory as they were. Prints the reason and returns 1 otherwise.
expect_refused() {
	local name="$1" helper="$2" root="$3" mode="$4" before after real_before real_after status=0 err
	shift 4
	before="$(snapshot "$root")"
	real_before="$(real_support_state)"
	err="$(cd "$root" && env "$@" "$helper" "$mode" 2>&1 >/dev/null </dev/null)" || status=$?
	after="$(snapshot "$root")"
	real_after="$(real_support_state)"
	case "$status" in
	64) grep -q '^k3sm-app-update: refused: ' <<<"$err" \
		|| { echo "    $name $mode: exit 64 without a refusal line: $err"; return 1; } ;;
	65) ;;
	*) echo "    $name $mode: exit $status, want a refusal (64 or 65): $err"; return 1 ;;
	esac
	[ "$before" = "$after" ] || { echo "    $name $mode: the fixture tree changed"; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/      /'; return 1; }
	[ "$real_before" = "$real_after" ] || { echo "    $name $mode: the real support directory changed"; return 1; }
	echo "    refused: $name $mode (exit $status${err:+: ${err#k3sm-app-update: refused: }})"
}

# make_fixtures <dir> <helper> <bundle>: lays out the three fixtures from an
# ad-hoc signed helper and an ad-hoc signed bundle; prints nothing.
make_fixtures() {
	local d="$1" helper="$2" bundle="$3" home priv staged
	mkdir -p "$d/loose"
	cp "$helper" "$d/loose/k3sm-app-update"
	mkdir -p "$d/in-bundle"
	/usr/bin/ditto "$bundle" "$d/in-bundle/k3sm.app"
	cp "$helper" "$d/in-bundle/k3sm.app/Contents/Helpers/k3sm-app-update"
	home="$d/fake-home"
	priv="$home/$SUPPORT/update"
	staged=".k3sm.app.update-abcdefgh2345"
	mkdir -p "$priv" "$home/$SUPPORT/previous" "$home/Applications/$staged"
	chmod 0700 "$priv"
	cp "$helper" "$priv/k3sm-app-update"
	/usr/bin/ditto "$bundle" "$home/Applications/k3sm.app"
	/usr/bin/ditto "$bundle" "$home/Applications/$staged/k3sm.app"
	printf '{"mode":"update","target":"%s","stagedName":"%s","expectedTag":"v1.2.3","token":"%s","app":{"pid":%d,"start":{"seconds":0,"microseconds":0}},"state":"staged"}\n' \
		"$home/Applications/k3sm.app" "$staged" "$(printf '%064d' 0)" "$$" > "$priv/request.json"
	chmod 0600 "$priv/request.json"
}

# run_fixtures <dir>: every mode against every fixture; returns 1 if any run
# was not a clean refusal.
run_fixtures() {
	local d="$1" bad=0 mode home="$1/fake-home"
	for mode in $MODES; do
		expect_refused loose "$d/loose/k3sm-app-update" "$d/loose" "$mode" || bad=1
		expect_refused in-bundle "$d/in-bundle/k3sm.app/Contents/Helpers/k3sm-app-update" "$d/in-bundle" "$mode" || bad=1
		expect_refused fake-home "$home/$SUPPORT/update/k3sm-app-update" "$home" "$mode" \
			HOME="$home" CFFIXED_USER_HOME="$home" || bad=1
	done
	return "$bad"
}

# A tiny ad-hoc signed bundle for the self-test.
make_standin_bundle() {
	local b="$1/k3sm.app"
	mkdir -p "$b/Contents/MacOS" "$b/Contents/Helpers"
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>io.k3sm.app</string><key>CFBundleExecutable</key><string>k3sm-app</string></dict></plist>\n' > "$b/Contents/Info.plist"
	cp /usr/bin/true "$b/Contents/MacOS/k3sm-app"
	cp /usr/bin/true "$b/Contents/Helpers/k3sm-app-update"
	/usr/bin/codesign --force --sign - --timestamp=none "$b/Contents/MacOS/k3sm-app" 2>/dev/null
	/usr/bin/codesign --force --sign - --timestamp=none "$b" 2>/dev/null
}

self_test() {
	local T pass=0 fail=0 name
	T="$(mktemp -d)"
	# shellcheck disable=SC2064 # expand now: T is local
	trap "rm -rf '$T'" EXIT
	make_standin_bundle "$T/bundle"
	# want <pass|fail> <name> <command...>: the command's verdict must match.
	want() {
		local verdict="$1" what="$2" rc=0
		shift 2
		"$@" > "$T/out" 2>&1 || rc=$?
		if { [ "$verdict" = pass ] && [ "$rc" = 0 ]; } || { [ "$verdict" = fail ] && [ "$rc" != 0 ]; }; then
			echo "ok   $what"; pass=$((pass + 1))
		else
			echo "FAIL $what (exit $rc)"; sed 's/^/     /' "$T/out"; fail=$((fail + 1))
		fi
	}
	# Stand-in helpers: shell scripts, so each one's behaviour is plain.
	printf '#!/bin/sh\necho "k3sm-app-update: refused: stand-in" >&2\nexit 64\n' > "$T/refuses"
	printf '#!/bin/sh\nexit 0\n' > "$T/accepts"
	printf '#!/bin/sh\nexit 64\n' > "$T/silent"
	printf '#!/bin/sh\nexit 66\n' > "$T/other"
	# Refuses, but first touches the tree it was run in (its working directory).
	printf '#!/bin/sh\n: > ./touched\necho "k3sm-app-update: refused: stand-in" >&2\nexit 64\n' > "$T/writes"
	chmod 0755 "$T/refuses" "$T/accepts" "$T/silent" "$T/other" "$T/writes"
	for name in refuses accepts silent other writes; do
		rm -rf "$T/fx-$name"
		make_fixtures "$T/fx-$name" "$T/$name" "$T/bundle/k3sm.app"
	done
	want pass "a helper that refuses every run passes" run_fixtures "$T/fx-refuses"
	want fail "a helper that accepts (exit 0) fails the check" run_fixtures "$T/fx-accepts"
	want fail "an exit 64 with no refusal line fails the check" run_fixtures "$T/fx-silent"
	want fail "an exit that is not a refusal (66) fails the check" run_fixtures "$T/fx-other"
	want fail "a refusal that changed the fixture tree fails the check" run_fixtures "$T/fx-writes"
	# The signature checks, on copies of /usr/bin/true signed each way.
	cp /usr/bin/true "$T/hardened"
	release_sign "$T/hardened"
	cp /usr/bin/true "$T/no-runtime"
	/usr/bin/codesign --force --timestamp=none --identifier "$HELPER_ID" --sign - "$T/no-runtime" 2>/dev/null
	cp /usr/bin/true "$T/entitled"
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>\n' > "$T/ents.plist"
	/usr/bin/codesign --force --options runtime --timestamp=none --identifier "$HELPER_ID" --entitlements "$T/ents.plist" --sign - "$T/entitled" 2>/dev/null
	cp /usr/bin/true "$T/other-id"
	/usr/bin/codesign --force --options runtime --timestamp=none --identifier io.k3sm.app --sign - "$T/other-id" 2>/dev/null
	want pass "the release signing (hardened runtime, no entitlements) passes" check_signature "$T/hardened"
	want fail "a helper without the hardened runtime fails the check" check_signature "$T/no-runtime"
	want fail "a helper with an entitlement fails the check" check_signature "$T/entitled"
	want fail "a helper under another identifier fails the check" check_signature "$T/other-id"
	want fail "an unsigned file fails the check" check_signature "$T/accepts"
	echo "verify-shipped-helper --self-test: $pass passed, $fail failed"
	[ "$fail" = 0 ]
}

if [ "${1:-}" = --self-test ]; then
	[ "$#" = 1 ] || { echo "usage: hack/verify-shipped-helper.sh [--self-test]" >&2; exit 2; }
	self_test
	exit $?
fi
[ "$#" = 0 ] || { echo "usage: hack/verify-shipped-helper.sh [--self-test]" >&2; exit 2; }

# The release signing this check copies must still be the release signing.
grep -qF -- "$SIGN_LINE" hack/release/sign-and-notarize.sh \
	|| { echo "FAIL: hack/release/sign-and-notarize.sh no longer signs the helper with: $SIGN_LINE"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "    build: hack/build-app.sh --version 1.2.3 --team-id $TEAM (a fixture team; ad-hoc signed)"
bash hack/build-app.sh --version 1.2.3 --team-id "$TEAM" "$work/out" > "$work/build.log" 2>&1 \
	|| { echo "FAIL: the release build of the helper"; cat "$work/build.log"; exit 1; }
app="$work/out/k3sm.app"
built="$app/Contents/Helpers/k3sm-app-update"
[ -x "$built" ] || { echo "FAIL: the release build has no Contents/Helpers/k3sm-app-update"; exit 1; }
bash hack/check-team-pin.sh "$built" "$TEAM" > /dev/null \
	|| { echo "FAIL: the helper is not pinned to exactly $TEAM"; exit 1; }
lipo -archs "$built" | grep -qx arm64 || { echo "FAIL: the helper is not arm64-only"; exit 1; }

echo "    sign: the release flags (--options runtime --identifier $HELPER_ID), ad-hoc"
helper="$work/k3sm-app-update"
cp "$built" "$helper"
release_sign "$helper" || { echo "FAIL: codesign could not sign the helper"; exit 1; }
# The bundle the fixtures use: the release build with the release-signed
# helper in it, the bundle re-sealed ad-hoc around it.
cp "$helper" "$built"
/usr/bin/codesign --force --options runtime --timestamp=none --sign - "$app" 2>/dev/null \
	|| { echo "FAIL: codesign could not re-seal the fixture bundle"; exit 1; }
/usr/bin/codesign --verify --strict --deep "$app" || { echo "FAIL: the fixture bundle does not verify"; exit 1; }

echo "    signature:"
check_signature "$helper" || { echo "FAIL: the shipped helper's signature"; exit 1; }

echo "    refusals (every mode, every ad-hoc fixture):"
make_fixtures "$work/fx" "$helper" "$app"
run_fixtures "$work/fx" || { echo "FAIL: the shipped helper did not refuse every ad-hoc fixture"; exit 1; }
echo "    ok (the shipped helper refused all $(( $(wc -w <<<"$MODES") * 3 )) runs)"
