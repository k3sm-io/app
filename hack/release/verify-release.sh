#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# verify-release.sh -- check the app's disk image the way a user receives it.
#
#   hack/release/verify-release.sh <tag> [--repo <owner/name>] [--team-id <TEAMID>]
#   hack/release/verify-release.sh --image <file.dmg> --checksums <file>
#                                  [--team-id <TEAMID>]
#   hack/release/verify-release.sh --stable-url [--repo <owner/name>]
#   hack/release/verify-release.sh --self-test [<k3sm.app>]
#
# <tag> downloads k3sm_<version>_darwin_arm64.dmg and k3sm_<version>_checksums.txt
# from the published release (https://github.com/<repo>/releases/download/<tag>/,
# default repo k3sm-io/k3sm, https only, no credential) into a fresh private
# temporary directory, checks them, and removes the directory. --image checks a
# local image against a local checksums file the same way; release.sh
# --rehearsal runs it on the rehearsal image.
#
# --stable-url checks the stable link of the LATEST release (network, https
# only, no credential; --self-test drives the same decision from fixtures and
# makes no request). Every one required; any miss is a failure (exit 1):
#   a. the latest release carries k3sm_<v>_darwin_arm64.dmg, the same image
#      under the fixed alias k3sm_darwin_arm64.dmg, and the checksums file
#   b. the checksums file has exactly one line for each image name, with the
#      same sha256
#   c. each image asset's digest, as the API reports it, is that sha256
#   d. a HEAD request for releases/latest/download/k3sm_darwin_arm64.dmg
#      redirects (not followed) to that same tag's alias asset
#
# THE CHECKS, every one required; any miss is a failure (exit 1):
#   1. the image is named exactly k3sm_<version>_darwin_arm64.dmg (a release)
#      or k3sm_<version>_darwin_arm64-unsigned.dmg (a rehearsal); a published
#      release is always the first
#   2. every line of the checksums file is `<sha256>  <name>`, exactly one line
#      names the image, and its sha256 is the image's
#   3. a release image is Developer ID signed: codesign --verify --strict
#      against the Developer ID requirement for its Team ID (and --team-id,
#      when given), spctl -a -t open --context context:primary-signature, and
#      stapler validate. A rehearsal image is unsigned, so --team-id fails it
#   4. nothing is mounted unless 1 to 3 pass. hdiutil verify is not run: the
#      checksum already binds the bytes to the published line, make-dmg.sh
#      verifies the image when it builds it, and attach rejects a malformed one
#   5. attached read-only, without browsing, at a private mount point: the
#      volume is named k3sm; its root holds exactly k3sm.app and an
#      Applications symlink to /Applications (and at most a .fseventsd
#      directory)
#   6. k3sm.app: bundle id io.k3sm.app (io.k3sm.app.rehearsal for a rehearsal),
#      CFBundleShortVersionString and CFBundleVersion equal to the version's
#      core (1.2.3 for 1.2.3-rc.1), no K3smTeamID key in Info.plist, and
#      codesign --verify --strict --deep passes
#   7. a release app is signed by the image's Developer ID team, verifies
#      against its requirement with --deep, passes stapler validate, and
#      holds exactly that Team ID as its compiled pin; a rehearsal app is
#      ad-hoc (Signature=adhoc, no Authority, no Team ID) and holds no pin
#
# The image is detached on every exit path; a failed detach is a failure.
# This script signs nothing, notarizes nothing, reads no keychain and uploads
# nothing.
#
# --self-test needs no network and takes about half a minute. It builds the
# good rehearsal image with make-dmg.sh around <k3sm.app> when given (a
# rehearsal app, for example hack/build-app.sh --rehearsal output) or around a
# fixture app, and checks that it passes. Each broken image is a copy of that
# layout with one thing wrong (no Applications link, a link elsewhere, an
# extra root entry, the wrong volume name, a modified app), built with hdiutil
# makehybrid, which takes a fraction of a second where hdiutil create takes
# five; the checksum, name and signature cases reuse the good image. Each must
# fail. The Developer ID branch runs against fake codesign, spctl and stapler.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$HERE/../.." && pwd)"
MAKE_DMG="$HERE/make-dmg.sh"
CHECK_TEAM_PIN="$APP_ROOT/hack/check-team-pin.sh"

DEFAULT_REPO=k3sm-io/k3sm
VOLUME_NAME=k3sm
BUNDLE_ID=io.k3sm.app
REHEARSAL_BUNDLE_ID=io.k3sm.app.rehearsal
TEAM_PIN_MARKER='k3sm-team-id-pin:'
# The protocols curl may use, for the request and any redirect. The self-test
# serves its fixtures from file:// in a subshell of its own.
CURL_PROTO='=https'

die() { echo "verify-release: $*" >&2; exit 1; }
usage() { sed -n '7,11p' "$0" | sed 's/^# //' >&2; exit 2; }

valid_version() { [[ "$1" =~ ^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.[0-9]{1,4})?$ ]]; }
core_version() { local v="${1#v}"; printf '%s' "${v%-rc.*}"; }
sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
image_name() { printf 'k3sm_%s_darwin_arm64.dmg' "${1#v}"; }
checksums_name() { printf 'k3sm_%s_checksums.txt' "${1#v}"; }

# parse_image_name <basename>: prints "<tag> release" or "<tag> rehearsal" for
# the two closed names; fails for any other name.
parse_image_name() {
	local tag kind=release
	[[ "$1" =~ ^k3sm_([0-9][0-9.]*(-rc\.[0-9]+)?)_darwin_arm64(-unsigned)?\.dmg$ ]] || return 1
	tag="v${BASH_REMATCH[1]}"
	[ -z "${BASH_REMATCH[3]}" ] || kind=rehearsal
	valid_version "$tag" || return 1
	printf '%s %s\n' "$tag" "$kind"
}

# signature_kind: reads `codesign -dv` output on stdin and prints adhoc,
# developer-id:<TEAMID>, unsigned or other. Ad-hoc is Signature=adhoc with no
# Authority and no Team ID; Developer ID is a first Authority of "Developer ID
# Application: ... (<TEAMID>)" with TeamIdentifier=<TEAMID>.
signature_kind() {
	local info first team
	info="$(cat)"
	if grep -q 'is not signed at all' <<<"$info"; then echo unsigned; return 0; fi
	team="$(sed -n 's/^TeamIdentifier=//p' <<<"$info" | head -1)"
	first="$(sed -n 's/^Authority=//p' <<<"$info" | head -1)"
	if grep -qx 'Signature=adhoc' <<<"$info" && [ -z "$first" ] && { [ -z "$team" ] || [ "$team" = "not set" ]; }; then
		echo adhoc
	elif [[ "$team" =~ ^[A-Z0-9]{10}$ ]] && [[ "$first" == "Developer ID Application: "*" ($team)" ]]; then
		echo "developer-id:$team"
	else
		echo other
	fi
}

developer_id_requirement() {
	printf 'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "%s"' "$1"
}

# checksums_problems <checksums-file> <image>: prints every problem.
checksums_problems() {
	local sums="$1" img="$2" name rc=0 bad lines want
	name="$(basename "$img")"
	if [ -L "$sums" ] || [ ! -f "$sums" ]; then echo "    no checksums file at $sums"; return 1; fi
	bad="$(sed -E '/^[0-9a-f]{64}  [A-Za-z0-9._+-]+$/d' "$sums")"
	[ -z "$bad" ] || { echo "    $(basename "$sums") holds a line that is not '<sha256>  <name>':"; printf '%s\n' "$bad" | head -5 | sed 's/^/      /'; rc=1; }
	lines="$(awk -v n="$name" 'substr($0, 67) == n' "$sums")"
	case "$(printf '%s' "$lines" | grep -c .)" in
	1)
		want="${lines%%  *}"
		[ "$want" = "$(sha256_of "$img")" ] ||
			{ echo "    the sha256 of $name is $(sha256_of "$img"), not $want as $(basename "$sums") lists"; rc=1; }
		;;
	0) echo "    $(basename "$sums") has no line for $name"; rc=1 ;;
	*) echo "    $(basename "$sums") has more than one line for $name"; rc=1 ;;
	esac
	return "$rc"
}

# team_stamps <executable>: how many compiled Team ID stamps it holds.
team_stamps() {
	{ LC_ALL=C grep -ao "${TEAM_PIN_MARKER}[[:print:]][[:print:]]*" "$1" || true; } | sed '/^$/d' | wc -l | tr -d ' '
}

# app_problems <app> <tag> <kind> <team>: the mounted app, as step 6 and 7 of
# the header. <team> is the image's Developer ID team (release) or empty.
app_problems() {
	local app="$1" tag="$2" kind="$3" team="$4" rc=0 plist want v key bundle info sig exe
	plist="$app/Contents/Info.plist"
	exe="$app/Contents/MacOS/k3sm-app"
	if [ -L "$app" ] || [ ! -d "$app" ] || [ ! -f "$plist" ]; then echo "    no app bundle at k3sm.app"; return 1; fi
	bundle="$BUNDLE_ID"
	[ "$kind" = release ] || bundle="$REHEARSAL_BUNDLE_ID"
	v="$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true)"
	[ "$v" = "$bundle" ] || { echo "    the app's CFBundleIdentifier is '$v', not '$bundle'"; rc=1; }
	want="$(core_version "$tag")"
	for key in CFBundleShortVersionString CFBundleVersion; do
		v="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true)"
		[ "$v" = "$want" ] || { echo "    the app's $key is '$v', not '$want' (the version of $tag)"; rc=1; }
	done
	if plutil -extract K3smTeamID raw -o - "$plist" >/dev/null 2>&1; then
		echo "    the app's Info.plist carries K3smTeamID; the Team ID comes only from the compiled pin"; rc=1
	fi
	codesign --verify --strict --deep "$app" >/dev/null 2>&1 ||
		{ echo "    codesign --verify --strict --deep rejects k3sm.app"; rc=1; }
	info="$(codesign -dv "$app" 2>&1 || true)"
	sig="$(signature_kind <<<"$info")"
	[ -f "$exe" ] || { echo "    k3sm.app has no Contents/MacOS/k3sm-app"; return 1; }
	if [ "$kind" = release ]; then
		if [ "$sig" != "developer-id:$team" ]; then
			echo "    k3sm.app is signed $sig, not by the image's Developer ID team $team"; return 1
		fi
		codesign --verify --strict --deep -R="$(developer_id_requirement "$team")" "$app" >/dev/null 2>&1 ||
			{ echo "    codesign --verify --strict --deep rejects k3sm.app against the Developer ID requirement for $team"; rc=1; }
		xcrun stapler validate "$app" >/dev/null 2>&1 || { echo "    stapler validate rejects k3sm.app"; rc=1; }
		bash "$CHECK_TEAM_PIN" "$exe" "$team" >/dev/null 2>&1 ||
			{ echo "    k3sm.app is not pinned to exactly the Team ID $team"; rc=1; }
	else
		[ "$sig" = adhoc ] || { echo "    the rehearsal k3sm.app is signed $sig, not ad-hoc"; rc=1; }
		[ "$(team_stamps "$exe")" = 0 ] || { echo "    the rehearsal k3sm.app holds a compiled Team ID stamp"; rc=1; }
	fi
	return "$rc"
}

# root_problems <mount point>: step 5 of the header, past the attach.
root_problems() {
	local root="$1" rc=0 entries vol
	vol="$(diskutil info -plist "$root" 2>/dev/null | plutil -extract VolumeName raw -o - - 2>/dev/null || true)"
	[ "$vol" = "$VOLUME_NAME" ] || { echo "    the volume is named '$vol', not '$VOLUME_NAME'"; rc=1; }
	entries="$(cd "$root" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort)"
	if [ -e "$root/.fseventsd" ] || [ -L "$root/.fseventsd" ]; then
		if [ -L "$root/.fseventsd" ] || [ ! -d "$root/.fseventsd" ]; then
			echo "    .fseventsd in the image is not a directory"; rc=1
		fi
		entries="$(printf '%s\n' "$entries" | grep -vxF .fseventsd || true)"
	fi
	[ "$entries" = $'Applications\nk3sm.app' ] ||
		{ echo "    the image root holds [${entries//$'\n'/, }], not exactly [Applications, k3sm.app]"; rc=1; }
	if [ ! -L "$root/Applications" ] || [ "$(readlink "$root/Applications")" != /Applications ]; then
		echo "    Applications in the image is not a symlink to /Applications"; rc=1
	fi
	return "$rc"
}

# image_problems <image> <checksums> <team-pin>: every check of the header.
# Prints every problem; zero only when all pass. It is a subshell so its EXIT
# trap (the detach) is its own.
image_problems() (
	local img="$1" sums="$2" pin="$3" rc=0 parsed tag kind team="" info sig
	mnt="" attached=0
	detach() {
		[ -n "$mnt" ] || return 0
		if [ "$attached" = 1 ] && ! hdiutil detach -quiet "$mnt" >/dev/null 2>&1 && ! hdiutil detach -quiet -force "$mnt" >/dev/null 2>&1; then
			echo "    hdiutil could not detach the image at $mnt; run: hdiutil detach -force $mnt"
			attached=0 mnt=""
			return 1
		fi
		rmdir "$mnt" 2>/dev/null || true
		attached=0 mnt=""
	}
	trap 'detach || exit 1' EXIT
	trap 'detach; exit 129' HUP
	trap 'detach; exit 130' INT TERM

	if [ -L "$img" ] || [ ! -f "$img" ]; then echo "    no image file at $img"; exit 1; fi
	parsed="$(parse_image_name "$(basename "$img")")" ||
		{ echo "    $(basename "$img") is not named k3sm_<version>_darwin_arm64.dmg (or -unsigned.dmg for a rehearsal)"; exit 1; }
	tag="${parsed% *}" kind="${parsed#* }"
	checksums_problems "$sums" "$img" || { echo "    the image is not mounted: its checksum does not match"; exit 1; }

	if [ "$kind" = release ]; then
		info="$(codesign -dv "$img" 2>&1 || true)"
		sig="$(signature_kind <<<"$info")"
		case "$sig" in
		developer-id:*) team="${sig#developer-id:}" ;;
		*) echo "    the image is signed $sig, not with a Developer ID; a release image must be"; exit 1 ;;
		esac
		[ -z "$pin" ] || [ "$team" = "$pin" ] || { echo "    the image is signed by team $team, not --team-id $pin"; rc=1; }
		codesign --verify --strict -R="$(developer_id_requirement "$team")" "$img" >/dev/null 2>&1 ||
			{ echo "    codesign --verify --strict rejects the image against the Developer ID requirement for $team"; rc=1; }
		spctl -a -t open --context context:primary-signature "$img" >/dev/null 2>&1 ||
			{ echo "    spctl -a -t open --context context:primary-signature rejects the image"; rc=1; }
		xcrun stapler validate "$img" >/dev/null 2>&1 || { echo "    stapler validate rejects the image"; rc=1; }
		[ "$rc" = 0 ] || { echo "    the image is not mounted: its signature fails"; exit 1; }
	elif [ -n "$pin" ]; then
		echo "    --team-id $pin names a team, but $(basename "$img") is a rehearsal image with none"; exit 1
	fi

	mnt="$(mktemp -d)"
	chmod 700 "$mnt"
	if ! hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$img" >/dev/null 2>&1; then
		echo "    hdiutil cannot attach the image read-only"
		exit 1
	fi
	attached=1
	root_problems "$mnt" || rc=1
	app_problems "$mnt/k3sm.app" "$tag" "$kind" "$team" || rc=1
	detach || rc=1
	exit "$rc"
)

# verify_image <image> <checksums> <team-pin>: print the verdict.
verify_image() {
	local problems name
	name="$(basename "$1")"
	if problems="$(image_problems "$1" "$2" "$3")"; then
		echo "verify-release: ok $name sha256 $(sha256_of "$1")"
		return 0
	fi
	echo "verify-release: FAIL $name" >&2
	printf '%s\n' "$problems" >&2
	return 1
}

# fetch <url> <out>
fetch() {
	curl -fsSL --proto "$CURL_PROTO" --proto-redir "$CURL_PROTO" --retry 2 -o "$2" "$1" 2>/dev/null
}

# verify_tag <tag> <base-url> <team-pin>: download the image and the checksums
# file from <base-url>/ into a fresh private directory, verify, remove it.
verify_tag() (
	local tag="$1" base="$2" pin="$3" d img sums
	d="$(mktemp -d)"
	chmod 700 "$d"
	trap 'rm -rf "$d"' EXIT
	img="$(image_name "$tag")"
	sums="$(checksums_name "$tag")"
	fetch "$base/$sums" "$d/$sums" || { echo "verify-release: FAIL cannot download $base/$sums" >&2; exit 1; }
	fetch "$base/$img" "$d/$img" || { echo "verify-release: FAIL cannot download $base/$img (does the release carry a disk image?)" >&2; exit 1; }
	verify_image "$d/$img" "$d/$sums" "$pin"
)

# ---- the stable link ------------------------------------------------------------------
STABLE_NAME=k3sm_darwin_arm64.dmg

# release_facts <release.json>: prints the tag on line 1 and one
# "<asset name> <sha256 digest or ->" line per asset.
release_facts() {
	/usr/bin/python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))
print(r.get("tag_name", ""))
for a in r.get("assets", []):
    d = a.get("digest") or "-"
    print(a.get("name", ""), d[7:] if d.startswith("sha256:") else d)
' "$1"
}

# stable_problems <repo> <release.json> <checksums> <location>: prints every
# problem of the --stable-url header; zero only when all pass. <location> is the
# Location header of the HEAD request for the latest/download alias.
stable_problems() {
	local repo="$1" json="$2" sums="$3" loc="$4" rc=0 facts tag img n line count want digest
	facts="$(release_facts "$json" 2>/dev/null)" || { echo "    the release JSON does not parse"; return 1; }
	tag="$(sed -n 1p <<<"$facts")"
	valid_version "$tag" || { echo "    the latest release's tag '$tag' is not vMAJOR.MINOR.PATCH[-rc.N]"; return 1; }
	img="$(image_name "$tag")"
	for n in "$img" "$STABLE_NAME" "$(checksums_name "$tag")"; do
		sed 1d <<<"$facts" | awk -v n="$n" '$1 == n { f = 1 } END { exit !f }' ||
			{ echo "    the release $tag has no asset $n"; rc=1; }
	done
	if [ -L "$sums" ] || [ ! -f "$sums" ]; then
		echo "    no checksums file at $sums"; rc=1
	else
		want=""
		for n in "$img" "$STABLE_NAME"; do
			line="$(awk -v n="$n" 'substr($0, 67) == n' "$sums")"
			count="$(printf '%s' "$line" | grep -c . || true)"
			if [ "$count" != 1 ]; then
				echo "    $(basename "$sums") has $count lines for $n, not exactly one"; rc=1
				continue
			fi
			line="${line%%  *}"
			[[ "$line" =~ ^[0-9a-f]{64}$ ]] || { echo "    the line for $n is not a sha256"; rc=1; continue; }
			if [ -z "$want" ]; then want="$line"; elif [ "$line" != "$want" ]; then
				echo "    $STABLE_NAME and $img list different sha256 values ($line, $want)"; rc=1
			fi
			digest="$(sed 1d <<<"$facts" | awk -v n="$n" '$1 == n { print $2 }')"
			[ "$digest" = "$line" ] || { echo "    the release's digest for $n is '$digest', not $line as the checksums list"; rc=1; }
		done
	fi
	loc="${loc%$'\r'}"
	if [ "$loc" != "https://github.com/$repo/releases/download/$tag/$STABLE_NAME" ] &&
		[ "$loc" != "/$repo/releases/download/$tag/$STABLE_NAME" ]; then
		echo "    the latest/download alias redirects to '$loc', not to the $tag asset $STABLE_NAME"; rc=1
	fi
	return "$rc"
}

# verify_stable <repo>: fetch the latest release, its checksums file and the
# alias redirect into a private directory, then decide.
verify_stable() (
	local repo="$1" d tag problems loc
	d="$(mktemp -d)"
	chmod 700 "$d"
	trap 'rm -rf "$d"' EXIT
	fetch "https://api.github.com/repos/$repo/releases/latest" "$d/release.json" ||
		{ echo "verify-release: FAIL cannot read the latest release of $repo" >&2; exit 1; }
	tag="$(release_facts "$d/release.json" | sed -n 1p)"
	valid_version "$tag" || { echo "verify-release: FAIL the latest release's tag '$tag' is not a version" >&2; exit 1; }
	fetch "https://github.com/$repo/releases/download/$tag/$(checksums_name "$tag")" "$d/sums.txt" ||
		{ echo "verify-release: FAIL cannot download the checksums file of $tag" >&2; exit 1; }
	loc="$(curl -sS -I --proto "$CURL_PROTO" --max-redirs 0 --retry 2 "https://github.com/$repo/releases/latest/download/$STABLE_NAME" 2>/dev/null |
		awk 'tolower($1) == "location:" { print $2 }' | tail -1 || true)"
	if problems="$(stable_problems "$repo" "$d/release.json" "$d/sums.txt" "$loc")"; then
		echo "verify-release: ok stable $STABLE_NAME is $tag"
		return 0
	fi
	echo "verify-release: FAIL the stable link of $tag" >&2
	printf '%s\n' "$problems" >&2
	return 1
)

# ---- self-test ----------------------------------------------------------------------
# shellcheck disable=SC2016 # each case's assertion is a single-quoted string for eval
self_test() {
	local given="${1:-}" T passes=0 fails=0 rc ver tag app good
	T="$(mktemp -d)"
	SELFTEST_TMP="$T"
	trap 'rm -rf "$SELFTEST_TMP"' EXIT
	ok() { echo "  ok   $1"; passes=$((passes + 1)); }
	bad() { echo "  FAIL $1"; fails=$((fails + 1)); sed 's/^/       /' "$T/out" 2>/dev/null || true; }
	# expect <name> <want-rc> <grep-pattern> <command...>
	expect() {
		local name="$1" want="$2" pat="$3"
		shift 3
		rc=0
		"$@" >"$T/out" 2>&1 || rc=$?
		if [ "$rc" = "$want" ] && { [ -z "$pat" ] || grep -q -- "$pat" "$T/out"; }; then ok "$name"; else bad "$name (exit $rc)"; fi
	}

	# fixture_app <dir> <bundle-id> <version>: a minimal ad-hoc signed bundle
	# whose executable is a copy of /usr/bin/true.
	fixture_app() {
		local a="$1/k3sm.app"
		mkdir -p "$a/Contents/MacOS" "$a/Contents/Resources"
		cp /usr/bin/true "$a/Contents/MacOS/k3sm-app"
		cat >"$a/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>k3sm-app</string>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$3</string>
<key>CFBundleVersion</key><string>$3</string>
</dict></plist>
EOF
		printf 'fixture\n' >"$a/Contents/Resources/notes.txt"
		codesign --force --sign - --timestamp=none "$a/Contents/MacOS/k3sm-app" >/dev/null 2>&1
		codesign --force --sign - --timestamp=none "$a" >/dev/null 2>&1
	}
	# raw_image <srcdir> <out> [volname]: an image of exactly <srcdir>.
	raw_image() {
		mkdir -p "$(dirname "$2")"
		hdiutil makehybrid -quiet -hfs -hfs-volume-name "${3:-$VOLUME_NAME}" -o "$2" "$1"
	}
	# sums_for <image> [sha]: the checksums file beside it, with a tarball line.
	sums_for() {
		local s="${2:-$(sha256_of "$1")}" out
		out="$(dirname "$1")/sums.txt"
		{
			printf '%s  %s\n' "$(printf '1%.0s' $(seq 64))" k3sm_x_darwin_arm64.tar.gz
			printf '%s  %s\n' "$s" "$(basename "$1")"
		} >"$out"
		printf '%s' "$out"
	}

	echo "the decisions"
	expect "name: a release name parses" 0 "^v1.2.3 release$" parse_image_name k3sm_1.2.3_darwin_arm64.dmg
	expect "name: a rehearsal name parses" 0 "^v1.2.3-rc.1 rehearsal$" parse_image_name k3sm_1.2.3-rc.1_darwin_arm64-unsigned.dmg
	local n
	for n in k3sm.dmg k3sm_v1.2.3_darwin_arm64.dmg k3sm_1.2_darwin_arm64.dmg k3sm_1.2.3_darwin_amd64.dmg \
		k3sm_01.2.3_darwin_arm64.dmg k3sm_1.2.3_darwin_arm64.dmg.dmg k3sm_1.2.3_darwin_arm64-signed.dmg; do
		expect "name: $n is refused" 1 "" parse_image_name "$n"
	done
	sigcase() { printf '%b\n' "$2" | signature_kind | grep -qx -- "$1"; }
	expect "signature: ad-hoc" 0 "" sigcase adhoc 'Executable=x\nSignature=adhoc\nTeamIdentifier=not set'
	expect "signature: Developer ID with its team" 0 "" sigcase developer-id:ABCDE12345 \
		'Authority=Developer ID Application: Example (ABCDE12345)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nTeamIdentifier=ABCDE12345'
	expect "signature: Developer ID naming another team is other" 0 "" sigcase other \
		'Authority=Developer ID Application: Example (ZYXWV98765)\nTeamIdentifier=ABCDE12345'
	expect "signature: ad-hoc naming a team is other" 0 "" sigcase other 'Signature=adhoc\nTeamIdentifier=ABCDE12345'
	expect "signature: an Apple Development certificate is other" 0 "" sigcase other \
		'Authority=Apple Development: Example (ABCDE12345)\nTeamIdentifier=ABCDE12345'
	expect "signature: unsigned" 0 "" sigcase unsigned 'x: code object is not signed at all'

	echo "the images (hdiutil, no network)"
	if [ -n "$given" ]; then
		[ -d "$given/Contents" ] || die "--self-test: not an app bundle: $given"
		app="$given"
	else
		fixture_app "$T/app" "$REHEARSAL_BUNDLE_ID" 1.2.3
		app="$T/app/k3sm.app"
	fi
	ver="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
	tag="v$ver"
	local rname rel
	rname="$(image_name "$tag" | sed 's/\.dmg$/-unsigned.dmg/')"
	rel="$(image_name "$tag")"
	fixture_app "$T/relapp" "$BUNDLE_ID" "$ver"
	# The broken trees, each a copy of the good layout with one thing wrong.
	mktree() { mkdir -p "$T/src-$1"; ditto --norsrc --noqtn "${2:-$app}" "$T/src-$1/k3sm.app"; }
	mktree nolink
	mktree badlink; ln -s /tmp "$T/src-badlink/Applications"
	mktree extra; ln -s /Applications "$T/src-extra/Applications"; printf 'readme\n' >"$T/src-extra/README.txt"
	mktree volname; ln -s /Applications "$T/src-volname/Applications"
	mktree tampered; ln -s /Applications "$T/src-tampered/Applications"; printf 'x\n' >"$T/src-tampered/k3sm.app/Contents/Resources/added.txt"
	mktree release "$T/relapp/k3sm.app"; ln -s /Applications "$T/src-release/Applications"
	# One at a time: hdiutil create run side by side can leave an image attached.
	bash "$MAKE_DMG" "$app" "$T/good/$rname" >/dev/null || die "--self-test: make-dmg.sh failed"
	if ! { raw_image "$T/src-nolink" "$T/nolink/$rname" &&
		raw_image "$T/src-badlink" "$T/badlink/$rname" &&
		raw_image "$T/src-extra" "$T/extra/$rname" &&
		raw_image "$T/src-volname" "$T/volname/$rname" k3sm-x &&
		raw_image "$T/src-tampered" "$T/tampered/$rname" &&
		raw_image "$T/src-release" "$T/release/$rel"; }; then
		die "--self-test: hdiutil makehybrid could not build the fixture images"
	fi
	good="$T/good/$rname"

	expect "a good rehearsal image passes" 0 "^verify-release: ok $rname" verify_image "$good" "$(sums_for "$good")" ""
	expect "the CLI form --image --checksums passes it too" 0 "^verify-release: ok" \
		bash "$0" --image "$good" --checksums "$T/good/sums.txt"
	expect "a wrong checksum fails, before any mount" 1 "the image is not mounted" \
		verify_image "$good" "$(sums_for "$good" "$(printf '0%.0s' $(seq 64))")" ""
	printf '%s  %s\n' "$(sha256_of "$good")" other.dmg >"$T/good/sums.txt"
	expect "a checksums file with no line for the image fails" 1 "has no line for" verify_image "$good" "$T/good/sums.txt" ""
	printf '%s  %s\n%s  %s\n' "$(sha256_of "$good")" "$rname" "$(sha256_of "$good")" "$rname" >"$T/good/sums.txt"
	expect "two lines for the image fail" 1 "more than one line" verify_image "$good" "$T/good/sums.txt" ""
	printf '%s %s\n' "$(sha256_of "$good")" "$rname" >"$T/good/sums.txt"
	expect "a malformed checksums line fails" 1 "is not '<sha256>  <name>'" verify_image "$good" "$T/good/sums.txt" ""
	expect "a missing checksums file fails" 1 "no checksums file" verify_image "$good" "$T/none.txt" ""
	expect "a missing Applications link fails" 1 "not a symlink to /Applications" \
		verify_image "$T/nolink/$rname" "$(sums_for "$T/nolink/$rname")" ""
	expect "an Applications link to elsewhere fails" 1 "not a symlink to /Applications" \
		verify_image "$T/badlink/$rname" "$(sums_for "$T/badlink/$rname")" ""
	expect "an extra root entry fails" 1 "image root holds \[Applications, README.txt, k3sm.app\]" \
		verify_image "$T/extra/$rname" "$(sums_for "$T/extra/$rname")" ""
	expect "the wrong volume name fails" 1 "named 'k3sm-x', not 'k3sm'" \
		verify_image "$T/volname/$rname" "$(sums_for "$T/volname/$rname")" ""
	expect "an app modified after signing fails codesign --deep" 1 "codesign --verify --strict --deep rejects k3sm.app" \
		verify_image "$T/tampered/$rname" "$(sums_for "$T/tampered/$rname")" ""
	mkdir -p "$T/asrel" "$T/misnamed" "$T/notdmg"
	cp "$good" "$T/asrel/$(image_name "$tag")"
	expect "a rehearsal image under the release name fails: not Developer ID" 1 "not with a Developer ID" \
		verify_image "$T/asrel/$(image_name "$tag")" "$(sums_for "$T/asrel/$(image_name "$tag")")" ""
	cp "$good" "$T/misnamed/k3sm.dmg"
	expect "a misnamed image fails" 1 "is not named" verify_image "$T/misnamed/k3sm.dmg" "$(sums_for "$T/misnamed/k3sm.dmg")" ""
	printf 'not a disk image\n' >"$T/notdmg/$rname"
	expect "a file that is not a disk image fails" 1 "cannot attach the image" \
		verify_image "$T/notdmg/$rname" "$(sums_for "$T/notdmg/$rname")" ""
	expect "--team-id on a rehearsal image fails" 1 "is a rehearsal image with none" \
		verify_image "$good" "$(sums_for "$good")" ABCDE12345

	echo "the Developer ID branch (fake codesign, spctl and stapler; real hdiutil)"
	local F="$T/fakes" relimg="$T/release/$rel" relsums
	mkdir -p "$F"
	relsums="$(sums_for "$relimg")"
	cat >"$F/codesign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "codesign $*" >>"$FAKE_LOG"
if [ "$1" = -dv ]; then
	printf 'Executable=x\nAuthority=Developer ID Application: Example (%s)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nTeamIdentifier=%s\n' "${FAKE_TEAM:-ABCDE12345}" "${FAKE_TEAM:-ABCDE12345}" >&2
	exit 0
fi
exit "${FAKE_CODESIGN_RC:-0}"
EOF
	cat >"$F/spctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "spctl $*" >>"$FAKE_LOG"
exit "${FAKE_SPCTL_RC:-0}"
EOF
	cat >"$F/xcrun" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "xcrun $*" >>"$FAKE_LOG"
[ "$1 $2" = "stapler validate" ] || exit 97
exit "${FAKE_STAPLER_RC:-0}"
EOF
	chmod +x "$F/"*
	# The fixture executable holds no stamp; the pin check reads a fake one.
	cat >"$F/check-team-pin.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "check-team-pin $*" >>"$FAKE_LOG"
exit "${FAKE_PIN_RC:-0}"
EOF
	export FAKE_LOG="$T/fake.log"
	signed() { : >"$FAKE_LOG"; (PATH="$F:$PATH" CHECK_TEAM_PIN="$F/check-team-pin.sh" "$@"); }
	# with_env <NAME=value> <command...>: export it for this subshell's command.
	with_env() { export "${1?}"; shift; "$@"; }
	expect "a Developer ID image the tools accept passes" 0 "^verify-release: ok $rel" signed verify_image "$relimg" "$relsums" ""
	local req
	req="$(developer_id_requirement ABCDE12345)"
	if grep -qF -- "codesign --verify --strict -R=$req $relimg" "$FAKE_LOG" &&
		grep -qx -- "spctl -a -t open --context context:primary-signature $relimg" "$FAKE_LOG" &&
		grep -qx -- "xcrun stapler validate $relimg" "$FAKE_LOG" &&
		grep -qF -- "codesign --verify --strict --deep -R=$req " "$FAKE_LOG" &&
		grep -q -- "^xcrun stapler validate .*/k3sm.app$" "$FAKE_LOG" &&
		grep -q -- "^check-team-pin .*/k3sm.app/Contents/MacOS/k3sm-app ABCDE12345$" "$FAKE_LOG"; then
		ok "it checks the image and the app against the team's requirement, spctl, both staples and the pin"
	else
		cp "$FAKE_LOG" "$T/out"; bad "it checks the image and the app against the team's requirement, spctl, both staples and the pin"
	fi
	expect "--team-id naming the same team passes" 0 "^verify-release: ok" signed verify_image "$relimg" "$relsums" ABCDE12345
	expect "--team-id naming another team fails" 1 "not --team-id ZYXWV98765" signed verify_image "$relimg" "$relsums" ZYXWV98765
	expect "spctl rejecting the image fails" 1 "spctl -a -t open" signed with_env FAKE_SPCTL_RC=3 verify_image "$relimg" "$relsums" ""
	expect "stapler rejecting fails" 1 "stapler validate rejects" signed with_env FAKE_STAPLER_RC=65 verify_image "$relimg" "$relsums" ""
	expect "codesign rejecting fails" 1 "codesign --verify --strict rejects the image" signed with_env FAKE_CODESIGN_RC=1 verify_image "$relimg" "$relsums" ""
	expect "a wrong compiled pin fails" 1 "not pinned to exactly the Team ID" signed with_env FAKE_PIN_RC=1 verify_image "$relimg" "$relsums" ""
	expect "the release name with a rehearsal bundle id fails" 1 "CFBundleIdentifier is 'io.k3sm.app.rehearsal', not 'io.k3sm.app'" \
		signed verify_image "$T/asrel/$(image_name "$tag")" "$T/asrel/sums.txt" ""

	echo "the download (file:// fixtures; the CLI allows https only)"
	local S="$T/server"
	mkdir -p "$S/ok" "$S/none" "$S/badsum"
	cp "$relimg" "$S/ok/$rel"
	(cd "$S/ok" && shasum -a 256 "$rel" >"$(checksums_name "$tag")")
	(cd "$S/ok" && shasum -a 256 "$rel" >"$S/none/$(checksums_name "$tag")")
	cp "$relimg" "$S/badsum/$rel"
	printf '%s  %s\n' "$(printf 'f%.0s' $(seq 64))" "$rel" >"$S/badsum/$(checksums_name "$tag")"
	fetched() { (CURL_PROTO='=file' TMPDIR="$T/dl" "$@"); }
	mkdir -p "$T/dl"
	expect "a release downloaded and verified passes" 0 "^verify-release: ok $rel" signed fetched verify_tag "$tag" "file://$S/ok" ""
	expect "a release without a disk image fails" 1 "cannot download .*$rel" fetched verify_tag "$tag" "file://$S/none" ""
	expect "a release whose checksum does not match fails" 1 "the image is not mounted" fetched verify_tag "$tag" "file://$S/badsum" ""
	expect "a release with no checksums file fails" 1 "cannot download .*checksums" fetched verify_tag "$tag" "file://$T/nowhere" ""
	if [ -z "$(ls -A "$T/dl")" ]; then ok "every download directory is removed"; else ls -A "$T/dl" >"$T/out"; bad "every download directory is removed"; fi
	expect "the CLI refuses a tag that is not vX.Y.Z" 2 "not vMAJOR.MINOR.PATCH" bash "$0" 1.2.3
	expect "the CLI refuses a repo that is not owner/name" 2 "not owner/name" bash "$0" v1.2.3 --repo 'a/b;c'
	expect "the CLI refuses a malformed --team-id" 2 "not a 10-character Team ID" bash "$0" --image "$good" --checksums "$T/x" --team-id abc

	echo "the stable link (JSON and header fixtures; no request is made)"
	local V="$T/stable" st="v1.2.3" sh1 sh2 vn sn cn
	mkdir -p "$V"
	vn="$(image_name "$st")"; sn="$STABLE_NAME"; cn="$(checksums_name "$st")"
	sh1="$(printf 'a%.0s' $(seq 64))"; sh2="$(printf 'b%.0s' $(seq 64))"
	# rel_json <file> <tag> <assets...>: each asset is name:digest.
	rel_json() {
		local f="$1" t="$2" a first=1
		shift 2
		{ printf '{"tag_name":"%s","assets":[' "$t"
			for a in "$@"; do
				[ "$first" = 1 ] || printf ','
				first=0
				printf '{"name":"%s","digest":"sha256:%s"}' "${a%%:*}" "${a#*:}"
			done
			printf ']}\n'; } >"$f"
	}
	good_loc="https://github.com/$DEFAULT_REPO/releases/download/$st/$sn"
	rel_json "$V/good.json" "$st" "$vn:$sh1" "$sn:$sh1" "$cn:$sh2"
	printf '%s  %s\n%s  %s\n' "$sh1" "$vn" "$sh1" "$sn" >"$V/good.txt"
	expect "a good latest release passes" 0 "" stable_problems "$DEFAULT_REPO" "$V/good.json" "$V/good.txt" "$good_loc"
	expect "a path-only Location passes" 0 "" stable_problems "$DEFAULT_REPO" "$V/good.json" "$V/good.txt" "/$DEFAULT_REPO/releases/download/$st/$sn"
	expect "a CRLF Location passes" 0 "" stable_problems "$DEFAULT_REPO" "$V/good.json" "$V/good.txt" "$good_loc"$'\r'
	rel_json "$V/nostable.json" "$st" "$vn:$sh1" "$cn:$sh2"
	expect "a release missing the stable name fails" 1 "has no asset $sn" stable_problems "$DEFAULT_REPO" "$V/nostable.json" "$V/good.txt" "$good_loc"
	rel_json "$V/noversioned.json" "$st" "$sn:$sh1" "$cn:$sh2"
	expect "a release missing the versioned name fails" 1 "has no asset $vn" stable_problems "$DEFAULT_REPO" "$V/noversioned.json" "$V/good.txt" "$good_loc"
	printf '%s  %s\n%s  %s\n' "$sh1" "$vn" "$sh2" "$sn" >"$V/differ.txt"
	expect "two different sha256 lines fail" 1 "list different sha256" stable_problems "$DEFAULT_REPO" "$V/good.json" "$V/differ.txt" "$good_loc"
	printf '%s  %s\n' "$sh1" "$vn" >"$V/oneline.txt"
	expect "a checksums file with no stable line fails" 1 "has 0 lines for $sn" stable_problems "$DEFAULT_REPO" "$V/good.json" "$V/oneline.txt" "$good_loc"
	printf '%s  %s\n%s  %s\n%s  %s\n' "$sh1" "$vn" "$sh1" "$sn" "$sh1" "$sn" >"$V/dup.txt"
	expect "two stable lines fail" 1 "has 2 lines for $sn" stable_problems "$DEFAULT_REPO" "$V/good.json" "$V/dup.txt" "$good_loc"
	rel_json "$V/baddigest.json" "$st" "$vn:$sh1" "$sn:$sh2" "$cn:$sh2"
	expect "an asset digest that differs from the checksums fails" 1 "digest for $sn" stable_problems "$DEFAULT_REPO" "$V/baddigest.json" "$V/good.txt" "$good_loc"
	expect "a redirect to the wrong tag fails" 1 "redirects to" stable_problems "$DEFAULT_REPO" "$V/good.json" "$V/good.txt" "https://github.com/$DEFAULT_REPO/releases/download/v1.2.2/$sn"
	expect "no redirect at all fails" 1 "redirects to ''" stable_problems "$DEFAULT_REPO" "$V/good.json" "$V/good.txt" ""
	printf 'not json\n' >"$V/bad.json"
	expect "release JSON that does not parse fails" 1 "does not parse" stable_problems "$DEFAULT_REPO" "$V/bad.json" "$V/good.txt" "$good_loc"
	expect "the CLI refuses --stable-url with a tag" 2 "" bash "$0" --stable-url v1.2.3

	# Read the list whole: grep -q would end the pipe early, and under pipefail
	# hdiutil's SIGPIPE would read as "not found".
	local attached_now
	attached_now="$(hdiutil info)"
	if grep -F "$T" <<<"$attached_now" >"$T/out"; then
		bad "no fixture image is left attached"
	else
		ok "no fixture image is left attached"
	fi
	echo "verify-release self-test: $passes passed, $fails failed"
	[ "$fails" -eq 0 ] || { echo "verify-release self-test: FAILED"; return 1; }
	echo "verify-release self-test: all passed"
}

# ---- main -------------------------------------------------------------------------
main() {
	local tag="" repo="$DEFAULT_REPO" image="" sums="" pin="" stable=0
	case "${1:-}" in
	--self-test)
		[ "$#" -le 2 ] || usage
		self_test "${2:-}"
		return
		;;
	"" | -h | --help) usage ;;
	esac
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--repo) repo="${2:?--repo needs a value}"; shift 2 ;;
		--team-id) pin="${2:?--team-id needs a value}"; shift 2 ;;
		--stable-url) stable=1; shift ;;
		--image) image="${2:?--image needs a value}"; shift 2 ;;
		--checksums) sums="${2:?--checksums needs a value}"; shift 2 ;;
		-*) echo "verify-release: unknown argument: $1" >&2; usage ;;
		*) [ -z "$tag" ] || usage; tag="$1"; shift ;;
		esac
	done
	[ -z "$pin" ] || [[ "$pin" =~ ^[A-Z0-9]{10}$ ]] || { echo "verify-release: --team-id '$pin' is not a 10-character Team ID" >&2; exit 2; }
	if [ "$stable" = 1 ]; then
		[ -z "$tag" ] && [ -z "$image" ] && [ -z "$sums" ] && [ -z "$pin" ] || usage
		[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "verify-release: --repo '$repo' is not owner/name" >&2; exit 2; }
		verify_stable "$repo"
		return
	fi
	if [ -n "$image" ] || [ -n "$sums" ]; then
		[ -z "$tag" ] && [ -n "$image" ] && [ -n "$sums" ] || usage
		verify_image "$image" "$sums" "$pin"
		return
	fi
	valid_version "$tag" || { echo "verify-release: '$tag' is not vMAJOR.MINOR.PATCH[-rc.N]" >&2; exit 2; }
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "verify-release: --repo '$repo' is not owner/name" >&2; exit 2; }
	verify_tag "$tag" "https://github.com/$repo/releases/download/$tag" "$pin"
}
main "$@"
