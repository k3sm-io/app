#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-shipped-helper.sh [--self-test]
#
# Checks the swap helper exactly as a release builds it, not a test build.
# The Swift tests drive the swap engine with an injected requirement; this
# check covers the binary those tests do not reach. What it proves is
# narrow: the release-built helper refuses to act outside its private copy,
# and it carries no entitlements and the hardened runtime. Its requirement
# check and bundle verifier are exercised only at attended signing, because
# reaching them needs a Developer ID signed helper running from the
# account's real private directory, and this check uses neither.
#
#   1. build: hack/build-app.sh --version 1.2.3 --team-id ABCDE12345, the
#      release build path, so the helper carries the compiled Team ID pin and
#      the compiled helper and app requirements, and has no test seam. The
#      Team ID is a fixture: no Developer ID is used, read or needed.
#   2. sign: the helper is re-signed ad-hoc with the flags
#      hack/release/sign-and-notarize.sh gives it (--options runtime and the
#      identifier io.k3sm.app.update), with "-" as the identity. That script
#      must still carry the same codesign line, so a change there reds here.
#   3. the signature, on the signed helper and again on the helper inside the
#      re-sealed fixture bundle: codesign -d --entitlements shows no
#      entitlements, the CodeDirectory flags carry "runtime" (the hardened
#      runtime), the identifier is io.k3sm.app.update, and the stamp pins
#      exactly the fixture team (hack/check-team-pin.sh).
#   4. the location refusal: the helper is run in each of its three modes
#      (--swap, --go-back, --relaunch) from each place below, and every run
#      must exit 64 (refusedRequest) with exactly the line
#      "k3sm-app-update: refused: runs only from its copy in the private
#      directory", the guard that fires before the requirement check. A run
#      refused for any other reason is a failure. The fixture tree must be
#      unchanged afterwards, entry for entry and byte for byte, and so must
#      the account's real ~/Library/Application Support/io.k3sm.app.
#
#        loose      the helper as a loose file in a temp directory
#        in-bundle  the helper in place in the ad-hoc signed release bundle,
#                   at Contents/Helpers/k3sm-app-update
#        fake-home  a fake home laid out as an update would leave it: the
#                   0700 private directory holding the helper copy and a
#                   request naming an ad-hoc signed staged bundle beside an
#                   ad-hoc signed target, run with HOME pointing at it; the
#                   helper takes its paths from the passwd entry, so HOME
#                   does not move its private directory
#
#      Every run is confined first, so a helper that tried to write would be
#      stopped, not just caught afterwards: sandbox-exec with a profile that
#      denies file-write* everywhere but the fixture's temp directory,
#      /dev/null and /dev/tty. macOS refuses a nested sandbox-exec, so when
#      this script already runs inside a sandbox (a confined gate), the
#      outer confinement is what applies; one line says which. The runs
#      happen either way, and the snapshots are checked either way.
#
# --self-test needs no build. It runs the same checks against stand-ins and
# requires each check to fail on the stand-in that breaks it, and to pass on
# one that behaves; the output names every case.
#
# K3SM_SWIFTPM_DISABLE_SANDBOX=1 is read by hack/build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=ABCDE12345
HELPER_ID=io.k3sm.app.update
MODES="--swap --go-back --relaunch"
SUPPORT="Library/Application Support/io.k3sm.app"
# The one refusal every run here must give: the location guard.
REASON="k3sm-app-update: refused: runs only from its copy in the private directory"
# The codesign line hack/release/sign-and-notarize.sh signs the helper with.
# shellcheck disable=SC2016 # the literal text of the line, unexpanded
SIGN_LINE='/usr/bin/codesign --force --options runtime "$SIGN_TIMESTAMP" --identifier io.k3sm.app.update --sign "$SIGN_IDENTITY" "$f"'

# The account's real support directory, from the directory service (the
# helper reads the passwd entry, not HOME). The self-test points this at a
# temp path, so it never reads or writes the real one.
real_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')"
[ -n "$real_home" ] || { echo "verify-shipped-helper: cannot read this account's home directory" >&2; exit 1; }
REAL_SUPPORT="$real_home/$SUPPORT"
# How each run is confined: "sandbox-exec" or "outer" (set by pick_confinement).
CONFINE=

# release_sign <file>: the release signing of the helper, ad-hoc.
release_sign() {
	/usr/bin/codesign --force --options runtime --timestamp=none --identifier "$HELPER_ID" --sign - "$1" 2>/dev/null
}

# check_sign_line <file>: the release signing script still signs the helper
# with SIGN_LINE.
check_sign_line() {
	grep -qF -- "$SIGN_LINE" "$1" \
		|| { echo "    $1 no longer signs the helper with: $SIGN_LINE"; return 1; }
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

# support_state: what REAL_SUPPORT looks like, so a run that created or
# changed it is caught.
support_state() {
	if [ -e "$REAL_SUPPORT" ]; then
		/usr/bin/find "$REAL_SUPPORT" -exec /usr/bin/stat -f '%N %HT %Lp %z %m' {} + 2>&1 | LC_ALL=C sort
	else
		echo "absent: $REAL_SUPPORT"
	fi
}

# profile_for <dir>: the sandbox profile for a run: every file write denied
# except under <dir> (already resolved), /dev/null and /dev/tty.
profile_for() {
	printf '(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write* (subpath "%s") (literal "/dev/null") (literal "/dev/tty"))\n' "$1"
}

# pick_confinement <dir>: sandbox-exec when it can apply here, else the outer
# sandbox this process already runs in (macOS refuses a nested
# sandbox-exec). The probe applies the same profile shape a run uses, since a
# trivial profile can be accepted where a real one is refused. Prints which.
pick_confinement() {
	local dir
	dir="$(cd "$1" && pwd -P)"
	if /usr/bin/sandbox-exec -p "$(profile_for "$dir")" /usr/bin/true 2>/dev/null; then
		CONFINE=sandbox-exec
		echo "    confinement: sandbox-exec, file-write* denied outside the fixture directory, /dev/null and /dev/tty"
	else
		CONFINE=outer
		echo "    confinement: the outer sandbox (sandbox-exec cannot nest here); the snapshots still check every run"
	fi
}

# confined <dir> <command...>: runs the command with file writes allowed only
# under <dir> (resolved), /dev/null and /dev/tty, under CONFINE.
confined() {
	local dir
	dir="$(cd "$1" && pwd -P)"
	shift
	if [ "$CONFINE" = sandbox-exec ]; then
		/usr/bin/sandbox-exec -p "$(profile_for "$dir")" "$@"
	else
		"$@"
	fi
}

# expect_refused <name> <helper> <fixture-root> <mode> [env...]: runs the
# helper once, confined, and requires the location refusal with the fixture
# tree and the real support directory as they were. Prints the reason and
# returns 1 otherwise.
expect_refused() {
	local name="$1" helper="$2" root="$3" mode="$4" before after real_before real_after status=0 err
	shift 4
	before="$(snapshot "$root")"
	real_before="$(support_state)"
	err="$(cd "$root" && confined "$root" env "$@" "$helper" "$mode" 2>&1 >/dev/null </dev/null)" || status=$?
	after="$(snapshot "$root")"
	real_after="$(support_state)"
	[ "$status" = 64 ] || { echo "    $name $mode: exit $status, want 64 (the location refusal): $err"; return 1; }
	[ "$err" = "$REASON" ] || { echo "    $name $mode: refused for another reason: $err"; return 1; }
	[ "$before" = "$after" ] || { echo "    $name $mode: the fixture tree changed"; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/      /'; return 1; }
	[ "$real_before" = "$real_after" ] || { echo "    $name $mode: $REAL_SUPPORT changed"; return 1; }
	echo "    refused outside its private copy: $name $mode (exit 64)"
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
# was not the location refusal with nothing changed.
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
	local T pass=0 fail=0 name confine_was
	T="$(cd "$(mktemp -d)" && pwd -P)"
	# shellcheck disable=SC2064 # expand now: T is local
	trap "rm -rf '$T'" EXIT
	# Never the real directory: the self-test's support state is a temp path.
	REAL_SUPPORT="$T/real-home/$SUPPORT"
	mkdir -p "$REAL_SUPPORT"
	pick_confinement "$T"
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
	printf '#!/bin/sh\necho "%s" >&2\nexit 64\n' "$REASON" > "$T/refuses"
	printf '#!/bin/sh\nexit 0\n' > "$T/accepts"
	printf '#!/bin/sh\nexit 64\n' > "$T/silent"
	printf '#!/bin/sh\necho "k3sm-app-update: refused: this helper does not satisfy the helper requirement" >&2\nexit 64\n' > "$T/wrong-reason"
	printf '#!/bin/sh\necho "%s" >&2\nexit 65\n' "$REASON" > "$T/other"
	# Refuses, but first touches the tree it was run in (its working directory).
	printf '#!/bin/sh\n: > ./touched\necho "%s" >&2\nexit 64\n' "$REASON" > "$T/writes"
	# Refuses, but first writes into the (stand-in) real support directory.
	printf '#!/bin/sh\n: > "%s/touched"\necho "%s" >&2\nexit 64\n' "$REAL_SUPPORT" "$REASON" > "$T/writes-support"
	# Refuses, but first tries to write outside every allowed path.
	printf '#!/bin/sh\ntrue 2>/dev/null > "%s/escaped"\necho "%s" >&2\nexit 64\n' "$T/outside" "$REASON" > "$T/escapes"
	mkdir -p "$T/outside"
	chmod 0755 "$T/refuses" "$T/accepts" "$T/silent" "$T/wrong-reason" "$T/other" "$T/writes" "$T/writes-support" "$T/escapes"
	for name in refuses accepts silent wrong-reason other writes writes-support escapes; do
		make_fixtures "$T/fx-$name" "$T/$name" "$T/bundle/k3sm.app"
	done
	want pass "a helper that gives the location refusal on every run passes" run_fixtures "$T/fx-refuses"
	want fail "a helper that accepts (exit 0) fails the check" run_fixtures "$T/fx-accepts"
	want fail "an exit 64 with no refusal line fails the check" run_fixtures "$T/fx-silent"
	want fail "a refusal for another reason fails the check" run_fixtures "$T/fx-wrong-reason"
	want fail "an exit other than 64 (65) fails the check" run_fixtures "$T/fx-other"
	want fail "a refusal that changed the fixture tree fails the check" run_fixtures "$T/fx-writes"
	# The support-state check, with the confinement off so the write lands
	# and only the snapshot can catch it.
	confine_was="$CONFINE"
	CONFINE=outer
	want fail "a refusal that changed the support directory fails the check" run_fixtures "$T/fx-writes-support"
	CONFINE="$confine_was"
	if [ "$CONFINE" = sandbox-exec ]; then
		want pass "a write outside the fixture directory is denied by sandbox-exec" run_fixtures "$T/fx-escapes"
		want pass "  and nothing landed outside it" test ! -e "$T/outside/escaped"
		want pass "the same write unconfined lands (the denial is the sandbox's)" \
			sh -c "'$T/escapes' 2>/dev/null; test -e '$T/outside/escaped'"
		rm -f "$T/outside/escaped"
	else
		echo "n/a  the sandbox-exec denial cases: the outer sandbox applies here"
	fi
	# The release signing line, on copies of the real script.
	cp hack/release/sign-and-notarize.sh "$T/sign-same.sh"
	# shellcheck disable=SC2016 # the script's literal text, unexpanded
	sed 's/--options runtime "$SIGN_TIMESTAMP" --identifier io.k3sm.app.update/--timestamp=none --identifier io.k3sm.app.update/' \
		hack/release/sign-and-notarize.sh > "$T/sign-changed.sh"
	want pass "the release signing script carries the signing line" check_sign_line "$T/sign-same.sh"
	want fail "a changed signing line fails the check" check_sign_line "$T/sign-changed.sh"
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

check_sign_line hack/release/sign-and-notarize.sh || { echo "FAIL: the release signing line moved"; exit 1; }

work="$(cd "$(mktemp -d)" && pwd -P)"
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

echo "    signature (the signed helper):"
check_signature "$helper" || { echo "FAIL: the shipped helper's signature"; exit 1; }
echo "    signature (the helper inside the re-sealed bundle):"
check_signature "$built" || { echo "FAIL: the bundled helper's signature"; exit 1; }

echo "    the location refusal (every mode, every fixture; the requirement check and bundle verifier are exercised only at attended signing):"
pick_confinement "$work"
make_fixtures "$work/fx" "$helper" "$app"
run_fixtures "$work/fx" || { echo "FAIL: the release-built helper did not refuse to act outside its private copy"; exit 1; }
echo "    ok (the release-built helper refused to act outside its private copy in all $(( $(wc -w <<<"$MODES") * 3 )) runs)"
