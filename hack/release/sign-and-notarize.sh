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
#   2. check that the app executable and the MCP server beside it were built
#      for <team-id>: each must hold exactly one compiled Team ID stamp, equal
#      to <team-id>
#      (hack/build-app.sh --team-id <team-id>, hack/check-team-pin.sh). The
#      pin is the only Team ID the app trusts; nothing is stamped into
#      Info.plist
#   3. sign the app inside out with <identity>, the hardened runtime and a
#      secure timestamp: every Mach-O file under Contents/MacOS,
#      Contents/Helpers and Contents/Frameworks, found by its magic number
#      rather than a list of names or extensions, deepest first and the
#      bundle's main executable last; each but the main executable is
#      verified against the Developer ID requirement for <team-id> right after
#      it is signed, and any file that fails is named and stops the run before
#      the bundle is sealed. Then the bundle, verified with --deep against the
#      same requirement, which covers the main executable. A nested bundle (a
#      .framework or a helper .app) is not signed as a bundle here, so the
#      --deep verification fails on it and stops the run
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
#
# hack/release/sign-and-notarize.sh --self-test
#
# runs the enumeration and the per-file sign-and-verify step over a fixture
# bundle in a temporary directory, ad-hoc signed and checked against a
# requirement an ad-hoc signature satisfies. It needs no identity, no notary
# profile and no terminal, and it signs nothing outside its fixture.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# The signing policy. Fixed here, never read from the environment; the
# self-test alone replaces SIGN_IDENTITY, SIGN_TIMESTAMP and SIGNER.
SIGN_IDENTITY=""
SIGN_TIMESTAMP="--timestamp"
SIGNER=sign_one

# is_macho <file>: the file starts with a Mach-O or universal magic number.
is_macho() {
	local magic
	magic="$(/usr/bin/od -An -N4 -tx1 "$1" 2>/dev/null | /usr/bin/tr -d ' \n')" || return 1
	case "$magic" in
	feedface | cefaedfe | feedfacf | cffaedfe | cafebabe | bebafeca | cafebabf | bfbafeca) return 0 ;;
	*) return 1 ;;
	esac
}

# bundle_machos <app>: print every Mach-O file under Contents/MacOS,
# Contents/Helpers and Contents/Frameworks, one per line, in signing order:
# deepest path first, then by path, and the bundle's main executable last.
# Symbolic links are not followed (a framework's links point at files the walk
# already finds). Fails, naming the cause, when the walk of a directory fails
# (so a partial list never reaches signing), on a path holding a newline, on a
# Mach-O file with more than one hard link (codesign --force could rewrite the
# file it shares with a path outside the bundle), and on a main executable that
# is missing or not Mach-O.
bundle_machos() {
	local app="$1" main f dir list links tmp rc
	main="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist" 2>/dev/null)" \
		|| { echo "sign-and-notarize: no CFBundleExecutable in $app/Contents/Info.plist" >&2; return 1; }
	case "$main" in "" | */* | . | ..) echo "sign-and-notarize: bad CFBundleExecutable: $main" >&2; return 1 ;; esac
	main="$app/Contents/MacOS/$main"
	if [ ! -f "$main" ] || [ -L "$main" ] || ! is_macho "$main"; then
		echo "sign-and-notarize: the main executable is missing or not Mach-O: $main" >&2
		return 1
	fi
	tmp="$(mktemp -d)" || return 1
	list=""
	rc=0
	for dir in MacOS Helpers Frameworks; do
		[ -d "$app/Contents/$dir" ] || continue
		if ! /usr/bin/find "$app/Contents/$dir" -type f -print0 >"$tmp/files" 2>"$tmp/err"; then
			echo "sign-and-notarize: could not list every file under ${app}/Contents/$dir:" >&2
			sed 's/^/    /' "$tmp/err" >&2
			rc=1
			break
		fi
		while IFS= read -r -d '' f; do
			case "$f" in *$'\n'*) echo "sign-and-notarize: a path holds a newline under $app/Contents/$dir" >&2; rc=1; break 2 ;; esac
			is_macho "$f" || continue
			links="$(/usr/bin/stat -f %l "$f")" || { rc=1; break 2; }
			if [ "$links" != 1 ]; then
				echo "sign-and-notarize: refused: ${f#"$app"/} has $links hard links; signing it could rewrite a file outside the bundle" >&2
				rc=1
				break 2
			fi
			[ "$f" = "$main" ] && continue
			list="$list$(printf '%s' "$f" | /usr/bin/tr -cd / | /usr/bin/wc -c | /usr/bin/tr -d ' ')"$'\t'"$f"$'\n'
		done <"$tmp/files"
	done
	rm -rf "$tmp"
	[ "$rc" = 0 ] || return 1
	printf '%s' "$list" | LC_ALL=C /usr/bin/sort -t $'\t' -k1,1nr -k2,2 | /usr/bin/cut -f2-
	printf '%s\n' "$main"
}

# sign_one <file>: sign one file with the policy above. The MCP server keeps
# its own identifier; every other file takes codesign's default.
sign_one() {
	local f="$1"
	if [ "$(basename "$f")" = k3sm-mcp ]; then
		/usr/bin/codesign --force --options runtime "$SIGN_TIMESTAMP" --identifier io.k3sm.app.mcp --sign "$SIGN_IDENTITY" "$f"
	else
		/usr/bin/codesign --force --options runtime "$SIGN_TIMESTAMP" --sign "$SIGN_IDENTITY" "$f"
	fi
}

# sign_executables <app> <requirement>: sign every file bundle_machos lists,
# in order, with SIGNER, and verify each against <requirement> right after.
# The main executable comes last and is not verified on its own: codesign
# reads that path as the whole bundle, which has no sealed resources until the
# bundle itself is signed, so the bundle's verification right after the seal
# covers it. Every file that fails is named; any failure fails the step.
sign_executables() {
	local app="$1" req="$2" files main f why failed=0
	files="$(bundle_machos "$app")" || return 1
	main="$(printf '%s\n' "$files" | /usr/bin/tail -n 1)"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		echo "    sign ${f#"$app"/}"
		if ! "$SIGNER" "$f"; then
			echo "sign-and-notarize: could not sign: ${f#"$app"/}" >&2
			failed=1
			continue
		fi
		[ "$f" != "$main" ] || continue
		if ! why="$(/usr/bin/codesign --verify --strict -R="$req" "$f" 2>&1)"; then
			echo "sign-and-notarize: does not verify against the requirement after signing: ${f#"$app"/}" >&2
			printf '%s\n' "$why" | sed 's/^/    /' >&2
			failed=1
		fi
	done <<<"$files"
	[ "$failed" = 0 ] || { echo "sign-and-notarize: one or more executables did not verify; the bundle was not sealed" >&2; return 1; }
}

# The helpers inside are called through check and SIGNER.
# shellcheck disable=SC2329
self_test() {
	local T app req out rc pass=0 fail=0 expected got unsigned
	T="$(mktemp -d)"
	# shellcheck disable=SC2064 # expand now: T is local
	trap "rm -rf '$T'" EXIT
	check() {
		local name="$1"; shift
		if "$@"; then echo "ok   $name"; pass=$((pass + 1)); else echo "FAIL $name"; fail=$((fail + 1)); fi
	}
	# A fixture bundle: Mach-O copies of /usr/bin/true (they keep Apple's
	# signature until re-signed), a nested library and a symlink to it, and a
	# Mach-O outside the three directories. With "decoys", also a script in MacOS and
	# text files named like libraries in Helpers and Frameworks; codesign
	# refuses to seal a bundle around those, so the signing cases leave them out.
	make_fixture() {
		local a="$1" decoys="${2:-}"
		rm -rf "$a"
		mkdir -p "$a/Contents/MacOS" "$a/Contents/Helpers" "$a/Contents/Resources" \
			"$a/Contents/Frameworks/nested"
		cat >"$a/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>k3sm-app</string>
	<key>CFBundleIdentifier</key><string>io.k3sm.app.selftest</string>
	<key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST
		cp /usr/bin/true "$a/Contents/MacOS/k3sm-app"
		cp /usr/bin/true "$a/Contents/MacOS/k3sm-mcp"
		cp /usr/bin/true "$a/Contents/MacOS/extra-tool"
		cp /usr/bin/true "$a/Contents/Helpers/helper-bin"
		cp /usr/bin/true "$a/Contents/Frameworks/libfixture.dylib"
		if [ "$decoys" = decoys ]; then
			printf '#!/bin/sh\nexit 0\n' >"$a/Contents/MacOS/run.sh"
			chmod +x "$a/Contents/MacOS/run.sh"
			printf 'not a library\n' >"$a/Contents/Helpers/notes.dylib"
			printf 'not a library\n' >"$a/Contents/Frameworks/notes.dylib"
		fi
		cp /usr/bin/true "$a/Contents/Frameworks/nested/libdeep.dylib"
		ln -s nested/libdeep.dylib "$a/Contents/Frameworks/libalias.dylib"
		cp /usr/bin/true "$a/Contents/Resources/not-scanned"
	}
	rel() { sed "s|^$1/||"; }
	# has_line <text> <line>: <text> holds <line> exactly.
	has_line() { grep -qxF -- "$2" <<<"$1"; }
	# count_lines <text> <fixed string>: how many lines of <text> hold it.
	count_lines() { grep -cF -- "$2" <<<"$1" || true; }
	no_match() { ! grep -Eq -- "$2" <<<"$1"; }
	ident_is() { has_line "$(/usr/bin/codesign -dv "$1" 2>&1)" "Identifier=$2"; }
	# A signer that skips the extra executable: the hand-kept list's failure.
	sign_all_but_extra() { [ "$(basename "$1")" = extra-tool ] || sign_one "$1"; }

	SIGN_IDENTITY="-"
	SIGN_TIMESTAMP="--timestamp=none"
	# Ad-hoc signatures satisfy this; Apple's signature on the copied
	# /usr/bin/true does not, and an unsigned file fails before any requirement.
	req='! anchor apple generic'
	app="$T/k3sm.app"

	make_fixture "$app" decoys
	expected="Contents/Frameworks/nested/libdeep.dylib
Contents/Frameworks/libfixture.dylib
Contents/Helpers/helper-bin
Contents/MacOS/extra-tool
Contents/MacOS/k3sm-mcp
Contents/MacOS/k3sm-app"
	got="$(bundle_machos "$app" | rel "$app")"
	check "enumeration finds every Mach-O by magic, deepest first, main executable last" [ "$got" = "$expected" ]
	check "enumeration finds the extra executable in Contents/MacOS" has_line "$got" Contents/MacOS/extra-tool
	check "enumeration skips a script, a text .dylib, a symlink and Contents/Resources" \
		no_match "$got" 'run\.sh|notes\.dylib|libalias|not-scanned'

	make_fixture "$app"
	rc=0; out="$(SIGNER=sign_one sign_executables "$app" "$req" 2>&1)" || rc=$?
	check "every file signs and verifies" [ "$rc" = 0 ]
	check "every file is signed by name" [ "$(count_lines "$out" "    sign Contents/")" = 6 ]
	check "the MCP server keeps its identifier" ident_is "$app/Contents/MacOS/k3sm-mcp" io.k3sm.app.mcp
	check "the extra executable carries a signature that satisfies the requirement" \
		/usr/bin/codesign --verify --strict -R="$req" "$app/Contents/MacOS/extra-tool"
	check "the bundle seals over the signed executables" \
		/usr/bin/codesign --force --options runtime --timestamp=none --sign - "$app"
	check "the sealed bundle verifies with --deep" /usr/bin/codesign --verify --strict --deep -R="$req" "$app"

	unsigned="sign-and-notarize: does not verify against the requirement after signing: Contents/MacOS/extra-tool"
	make_fixture "$app"
	/usr/bin/codesign --remove-signature "$app/Contents/MacOS/extra-tool"
	rc=0; out="$(SIGNER=sign_all_but_extra sign_executables "$app" "$req" 2>&1)" || rc=$?
	check "an unsigned extra executable fails closed" [ "$rc" != 0 ]
	check "the failure names the unsigned file" has_line "$out" "$unsigned"
	check "the failure names no other file" [ "$(count_lines "$out" "does not verify against")" = 1 ]
	check "the failure carries codesign's reason" has_line "$out" "    $app/Contents/MacOS/extra-tool: code object is not signed at all"

	make_fixture "$app"
	rc=0; out="$(SIGNER=sign_all_but_extra sign_executables "$app" "$req" 2>&1)" || rc=$?
	check "an extra executable left with a foreign signature fails closed" [ "$rc" != 0 ]
	check "the foreign-signature failure names the file" has_line "$out" "$unsigned"

	make_fixture "$app"
	rc=0; out="$(SIGNER=false sign_executables "$app" "$req" 2>&1)" || rc=$?
	check "a signing error fails closed" [ "$rc" != 0 ]
	check "a signing error names the file" has_line "$out" "sign-and-notarize: could not sign: Contents/MacOS/k3sm-app"

	make_fixture "$app"
	rm "$app/Contents/MacOS/k3sm-app"
	rc=0; bundle_machos "$app" >/dev/null 2>&1 || rc=$?
	check "a missing main executable fails the enumeration" [ "$rc" != 0 ]

	make_fixture "$app"
	/usr/bin/plutil -remove CFBundleExecutable "$app/Contents/Info.plist"
	rc=0; bundle_machos "$app" >/dev/null 2>&1 || rc=$?
	check "no CFBundleExecutable fails the enumeration" [ "$rc" != 0 ]

	make_fixture "$app"
	mkdir "$app/Contents/MacOS/locked"
	cp /usr/bin/true "$app/Contents/MacOS/locked/hidden-tool"
	chmod 000 "$app/Contents/MacOS/locked"
	rc=0; out="$(SIGNER=sign_one sign_executables "$app" "$req" 2>&1)" || rc=$?
	chmod 755 "$app/Contents/MacOS/locked"
	check "a directory the walk cannot read fails closed" [ "$rc" != 0 ]
	check "the walk failure is named" has_line "$out" "sign-and-notarize: could not list every file under $app/Contents/MacOS:"
	check "a failed walk signs nothing" [ "$(count_lines "$out" "    sign Contents/")" = 0 ]

	make_fixture "$app"
	ln "$app/Contents/MacOS/extra-tool" "$T/outside-the-bundle"
	rc=0; out="$(SIGNER=sign_one sign_executables "$app" "$req" 2>&1)" || rc=$?
	check "a hard-linked executable fails closed" [ "$rc" != 0 ]
	check "the hard-linked executable is named" has_line "$out" \
		"sign-and-notarize: refused: Contents/MacOS/extra-tool has 2 hard links; signing it could rewrite a file outside the bundle"
	check "a hard link refusal signs nothing" [ "$(count_lines "$out" "    sign Contents/")" = 0 ]
	rm -f "$T/outside-the-bundle"

	echo "sign-and-notarize self-test: $pass passed, $fail failed"
	[ "$fail" = 0 ]
}

if [ "${1:-}" = "--self-test" ] && [ "$#" -eq 1 ]; then
	self_test
	exit
fi

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

echo "==> check the compiled Team ID pin"
"$HERE/../check-team-pin.sh" "$app/Contents/MacOS/k3sm-app" "$team" \
	|| { echo "sign-and-notarize: the app is not pinned to exactly team $team; rebuild it with hack/build-app.sh --team-id $team" >&2; exit 1; }
"$HERE/../check-team-pin.sh" "$app/Contents/MacOS/k3sm-mcp" "$team" \
	|| { echo "sign-and-notarize: k3sm-mcp is not pinned to exactly team $team; rebuild the app with hack/build-app.sh --team-id $team" >&2; exit 1; }

echo "==> sign the app (inside out, hardened runtime, timestamp)"
SIGN_IDENTITY="$identity"
sign_executables "$app" "$requirement" || exit 1
/usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$app"
/usr/bin/codesign --verify --strict --deep -R="$requirement" "$app" \
	|| { echo "sign-and-notarize: the bundle does not verify against the requirement after signing: $app" >&2; exit 1; }

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
