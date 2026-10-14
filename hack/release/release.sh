#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# release.sh -- the one attended entry for a full k3sm release with the app's
# disk image, and the unsigned rehearsal of the same flow.
#
#   hack/release/release.sh --version vX.Y.Z[-rc.N] --stage-dir <dir>
#                           --cp-build <dir> --ldflags <flags>
#                           --identity <identity> --team-id <TEAMID>
#                           --notes-file <file> [--repo <owner/name>]
#                           [--k3sm-dir <dir>]
#   hack/release/release.sh --rehearsal --version vX.Y.Z[-rc.N]
#                           [--k3sm-dir <dir>] [--ldflags <flags>]
#                           [--out-dir <dir>] [--stub-payload]
#   hack/release/release.sh --self-test
#
#   --k3sm-dir   the k3sm checkout whose hack/release scripts are driven
#                (default: ../k3sm beside this repo)
#   The other full-mode flags are passed to the k3sm checkout's
#   hack/release/publish.sh as they are; see its header.
#
# THE FULL RELEASE, each step refusing to continue on any failure:
#   1. publish.sh --through-verify: stage, sign, verify and package the k3sm
#      tree at <stage-dir>, then seal it
#   2. the staged k3sm reports the tag's version, and the seal's manifest hash
#      is the tree's PAYLOAD-SHA256
#   3. hack/build-app.sh --version <x.y.z> --team-id <TEAMID> --payload
#      <stage-dir> <stage-dir>.app-build, where x.y.z is the tag's core
#      version (vX.Y.Z-rc.N builds X.Y.Z)
#   4. every file under the app's payload/ is checked against the tree's
#      PAYLOAD-SHA256: exactly the listed files plus the manifest itself,
#      byte for byte, nothing else (no .DS_Store, no symlink); the app's own
#      payload.sha256 lists the same lines; the app's version and bundle id
#   5. hack/release/sign-and-notarize.sh (attended; it keeps its refusals)
#      signs, notarizes and staples the app and the image
#      <stage-dir>.app-build/k3sm_<version>_darwin_arm64.dmg
#   6. the image: named exactly k3sm_<version>_darwin_arm64.dmg (the tag
#      without its leading v); codesign --verify --strict against the
#      Developer ID requirement for <TEAMID>, stapler validate, and spctl -a
#      -t open --context context:primary-signature accept it; mounted
#      read-only at a private mount point, its root holds only k3sm.app and an
#      Applications symlink (and at most a .fseventsd directory), and the app
#      passes the checks of step 4 again plus codesign --verify --strict
#      --deep against the requirement, stapler validate, the compiled Team ID
#      pin, and no K3smTeamID key in Info.plist
#   7. publish.sh --upload --disk-image <the image>
#
# publish.sh --upload checks the image again, fully, before anything reaches
# GitHub; the checks here are an earlier, friendlier failure, never the only
# one. This script holds no secret: --identity names a keychain identity, and
# the notary profile is named inside sign-and-notarize.sh. It never reads a
# key and never prompts for one.
#
# THE REFUSAL. Outside --self-test and --rehearsal, before any argument is
# parsed, it refuses when CLAUDECODE or K3SM_AUTO is set at all, when stdin is
# not a terminal, or when /dev/tty cannot be opened, naming every reason that
# applies. publish.sh and sign-and-notarize.sh repeat their own checks. It is a
# guard against accident, not a security boundary.
#
# THE REHEARSAL (--rehearsal) is the unsigned mode the autonomous loop and the
# lab use. It runs the k3sm checkout's hack/release/stage.sh (ad-hoc, no
# Developer ID), builds the app ad-hoc with the bundle id
# io.k3sm.app.rehearsal and no Team ID (hack/build-app.sh --rehearsal), builds
# the image with make-dmg.sh, and runs the same payload and mount checks. In
# place of the signed checks it requires an ad-hoc signature that verifies:
# codesign -dv reports Signature=adhoc, no Authority and no Team ID, and the
# executable holds no Team ID stamp. Every child it starts runs under env -i
# with only PATH, HOME, TMPDIR, DEVELOPER_DIR and the Go toolchain locations.
# The output is
#   <out-dir>/k3sm_<version>_darwin_arm64-unsigned.dmg
# where <out-dir> defaults to a fresh rehearsal-<version>-<UTC time> directory
# in the nearest k3sm-io.scratch directory beside an ancestor of this repo.
# The rehearsal has no code path to publish.sh, gh, sign-and-notarize.sh or a
# Developer ID codesign, and the self-test asserts that from its fakes' logs.
# Its app carries a bundle id and no Team ID that the root copy-out refuses.
#
# --stub-payload passes stage.sh's placeholder payload through, for a quick
# shape check only; such an image installs nothing.
#
# Every tool is called by its bare name on PATH, so the self-test can replace
# codesign, xcrun, spctl, hdiutil and gh with fakes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$HERE/../.." && pwd)"

# The scripts this one drives. Fixed paths; the self-test points them at fakes
# inside its own subshells.
BUILD_APP="$APP_ROOT/hack/build-app.sh"
CHECK_TEAM_PIN="$APP_ROOT/hack/check-team-pin.sh"
SIGN_NOTARIZE="$HERE/sign-and-notarize.sh"
MAKE_DMG="$HERE/make-dmg.sh"

BUNDLE_ID=io.k3sm.app
REHEARSAL_BUNDLE_ID=io.k3sm.app.rehearsal
TEAM_PIN_MARKER='k3sm-team-id-pin:'

die() { echo "release: $*" >&2; exit 1; }
refuse() {
	printf '%s\n' "$1" | sed 's/^/release: REFUSE: /' >&2
	shift
	[ "$#" -eq 0 ] || printf 'release: %s\n' "$@" >&2
	exit 3
}

valid_version() { [[ "$1" =~ ^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.[0-9]{1,4})?$ ]]; }
# core_version vX.Y.Z[-rc.N] -> X.Y.Z, the only form CFBundleShortVersionString takes
core_version() { local v="${1#v}"; printf '%s' "${v%-rc.*}"; }
# image_name <tag> [suffix] -> k3sm_<version>_darwin_arm64<suffix>.dmg
image_name() { printf 'k3sm_%s_darwin_arm64%s.dmg' "${1#v}" "${2:-}"; }
sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# attended_problems <claudecode-set> <k3sm-auto-set> <stdin-tty> <dev-tty>:
# each argument 1 or 0. Prints one line per reason the full release must not
# run; prints nothing when it may.
attended_problems() {
	[ "$1" = 0 ] || echo "automation-env: CLAUDECODE is set (an agent session)"
	[ "$2" = 0 ] || echo "automation-env: K3SM_AUTO is set (the autonomous loop)"
	[ "$3" = 1 ] || echo "no-tty: stdin is not a terminal"
	[ "$4" = 1 ] || echo "no-tty: /dev/tty cannot be opened"
}

check_attended() {
	local cc=0 auto=0 stdin=0 tty=0 problems
	[ -z "${CLAUDECODE+x}" ] || cc=1
	[ -z "${K3SM_AUTO+x}" ] || auto=1
	[ ! -t 0 ] || stdin=1
	if (exec 3<>/dev/tty) 2>/dev/null; then tty=1; fi
	problems="$(attended_problems "$cc" "$auto" "$stdin" "$tty")"
	[ -z "$problems" ] || refuse "$problems" \
		"A release signs and uploads with the operator's credentials; run it yourself in a terminal." \
		"The unsigned rehearsal is: hack/release/release.sh --rehearsal --version <tag>"
}

# image_name_problems <file> <tag> [suffix]: the closed name, nothing else.
image_name_problems() {
	local want
	want="$(image_name "$2" "${3:-}")"
	[ "$(basename "$1")" = "$want" ] || echo "    the disk image is named $(basename "$1"), not exactly $want"
	[ "$(basename "$1")" = "$want" ]
}

# payload_problems <dir> <manifest>: zero when <dir> holds exactly the files
# <manifest> lists, with its SHA-256 each, plus PAYLOAD-SHA256 byte-identical to
# <manifest>; no other file (.DS_Store included), no symlink, no special file,
# no setuid or setgid file and no group- or other-writable entry (the rule
# hack/build-app.sh applies). A last manifest line without a newline counts.
# Prints every problem.
payload_problems() {
	local dir="$1" manifest="$2" rc=0 odd lines want got line sum rel
	[ -f "$manifest" ] && [ ! -L "$manifest" ] || { echo "    no manifest at $manifest"; return 1; }
	if [ -L "$dir" ] || [ ! -d "$dir" ]; then echo "    no payload directory at $dir"; return 1; fi
	odd="$(cd "$dir" && find . ! -type f ! -type d | sed 's|^\./||')"
	[ -z "$odd" ] || { echo "    $dir holds symlinks or special files:"; printf '%s\n' "$odd" | sed 's/^/      /'; rc=1; }
	odd="$(cd "$dir" && find . -perm +6022 | sed 's|^\./||')"
	[ -z "$odd" ] || { echo "    $dir holds setuid or setgid files or group/other-writable entries:"; printf '%s\n' "$odd" | sed 's/^/      /'; rc=1; }
	cmp -s "$dir/PAYLOAD-SHA256" "$manifest" || { echo "    $dir/PAYLOAD-SHA256 differs from $manifest"; rc=1; }
	lines="$(sed -e '/^#/d' -e '/^$/d' "$manifest")"
	if [ -n "$(printf '%s\n' "$lines" | sed -E '/^[0-9a-f]{64}  [^/].*$/d; /^$/d')" ]; then
		echo "    $manifest holds a line that is not '<sha256>  <path>'"; rc=1
	fi
	want="$({ printf '%s\n' "$lines" | sed -e '/^$/d' -e 's/^[0-9a-f]\{64\}  //'; echo PAYLOAD-SHA256; } | LC_ALL=C sort)"
	got="$(cd "$dir" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
	if [ "$want" != "$got" ]; then
		echo "    the files under $dir differ from the manifest (< listed, > present):"
		diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed -n 's/^\([<>]\)/      \1/p'
		rc=1
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '#'* | '') continue ;; esac
		sum="${line%%  *}"
		rel="${line#*  }"
		[ -f "$dir/$rel" ] && [ ! -L "$dir/$rel" ] || continue
		[ "$(sha256_of "$dir/$rel")" = "$sum" ] || { echo "    $rel: sha256 differs from the manifest"; rc=1; }
	done <"$manifest"
	return "$rc"
}

# app_problems <app> <tag> <bundle-id> <manifest>: the bundle's identity and
# its payload, signed or not. Prints every problem.
app_problems() {
	local app="$1" tag="$2" bundle="$3" manifest="$4" rc=0 plist want v key own
	plist="$app/Contents/Info.plist"
	if [ -L "$app" ] || [ ! -d "$app" ] || [ ! -f "$plist" ]; then echo "    no app bundle at $app"; return 1; fi
	want="$(core_version "$tag")"
	for key in CFBundleShortVersionString CFBundleVersion; do
		v="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true)"
		[ "$v" = "$want" ] || { echo "    the app's $key is '$v', not '$want' (the version of $tag)"; rc=1; }
	done
	v="$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null || true)"
	[ "$v" = "$bundle" ] || { echo "    the app's CFBundleIdentifier is '$v', not '$bundle'"; rc=1; }
	# The Team ID the app trusts is compiled in, never read from Info.plist.
	if plutil -extract K3smTeamID raw -o - "$plist" >/dev/null 2>&1; then
		echo "    the app's Info.plist carries K3smTeamID; the Team ID must come only from the compiled pin"; rc=1
	fi
	payload_problems "$app/Contents/Resources/payload" "$manifest" || rc=1
	own="$app/Contents/Resources/payload.sha256"
	if [ ! -f "$own" ] || [ -L "$own" ]; then
		echo "    the app has no payload.sha256"; rc=1
	elif [ "$(grep -v '  PAYLOAD-SHA256$' "$own" | LC_ALL=C sort)" != "$(grep -v '^#' "$manifest" | sed '/^$/d' | LC_ALL=C sort)" ]; then
		echo "    the app's payload.sha256 does not list the manifest's lines"; rc=1
	fi
	return "$rc"
}

developer_id_requirement() {
	printf 'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "%s"' "$1"
}

# signed_image_problems <image> <team>: the image-level checks of a signed,
# notarized and stapled image.
signed_image_problems() {
	local img="$1" team="$2" rc=0
	codesign --verify --strict -R="$(developer_id_requirement "$team")" "$img" >/dev/null 2>&1 ||
		{ echo "    codesign --verify --strict rejects the image against the Developer ID requirement for $team"; rc=1; }
	xcrun stapler validate "$img" >/dev/null 2>&1 || { echo "    stapler validate rejects the image"; rc=1; }
	spctl -a -t open --context context:primary-signature "$img" >/dev/null 2>&1 ||
		{ echo "    spctl -a -t open --context context:primary-signature rejects the image"; rc=1; }
	return "$rc"
}

# signed_app_problems <app> <team>: the mounted app is Developer ID signed for
# <team>, stapled, and pinned to exactly <team>.
signed_app_problems() {
	local app="$1" team="$2" rc=0
	codesign --verify --strict --deep -R="$(developer_id_requirement "$team")" "$app" >/dev/null 2>&1 ||
		{ echo "    codesign --verify --strict --deep rejects k3sm.app against the Developer ID requirement for $team"; rc=1; }
	xcrun stapler validate "$app" >/dev/null 2>&1 || { echo "    stapler validate rejects k3sm.app"; rc=1; }
	bash "$CHECK_TEAM_PIN" "$app/Contents/MacOS/k3sm-app" "$team" >/dev/null 2>&1 ||
		{ echo "    k3sm.app is not pinned to exactly the Team ID $team"; rc=1; }
	return "$rc"
}

# team_stamps <executable>: how many compiled Team ID stamps it holds.
team_stamps() {
	{ LC_ALL=C grep -ao "${TEAM_PIN_MARKER}[[:print:]][[:print:]]*" "$1" || true; } | sed '/^$/d' | wc -l | tr -d ' '
}

# rehearsal_app_problems <app>: the app's signature is ad-hoc and verifies:
# `codesign -dv` reports Signature=adhoc, no Authority and no Team ID
# (TeamIdentifier absent or "not set", which is how codesign prints an ad-hoc
# signature), and the executable holds no compiled Team ID stamp.
rehearsal_app_problems() {
	local app="$1" rc=0 exe n info
	exe="$app/Contents/MacOS/k3sm-app"
	codesign --verify --strict --deep "$app" >/dev/null 2>&1 ||
		{ echo "    codesign --verify --strict --deep rejects the rehearsal k3sm.app"; rc=1; }
	info="$(codesign -dv "$app" 2>&1 || true)"
	grep -qx 'Signature=adhoc' <<<"$info" ||
		{ echo "    codesign -dv does not report Signature=adhoc for the rehearsal k3sm.app"; rc=1; }
	if grep -q '^Authority=' <<<"$info"; then
		echo "    the rehearsal k3sm.app is signed by a certificate authority, not ad-hoc"; rc=1
	fi
	if grep '^TeamIdentifier=' <<<"$info" | grep -vqx 'TeamIdentifier=not set'; then
		echo "    the rehearsal k3sm.app's signature names a Team ID: $(grep '^TeamIdentifier=' <<<"$info" | head -1)"; rc=1
	fi
	if [ ! -f "$exe" ]; then
		echo "    k3sm.app has no Contents/MacOS/k3sm-app"; rc=1
	else
		n="$(team_stamps "$exe")"
		[ "$n" = 0 ] || { echo "    the rehearsal k3sm.app holds $n Team ID stamps; it must hold none"; rc=1; }
	fi
	return "$rc"
}

# The private mount point of the image under check, and its cleanup.
IMAGE_MNT="" IMAGE_ATTACHED=0
detach_image() {
	[ -n "$IMAGE_MNT" ] || return 0
	if [ "$IMAGE_ATTACHED" = 1 ]; then
		if ! hdiutil detach "$IMAGE_MNT" >/dev/null 2>&1 && ! hdiutil detach -force "$IMAGE_MNT" >/dev/null 2>&1; then
			echo "release: could not detach the image at $IMAGE_MNT; run: hdiutil detach -force $IMAGE_MNT" >&2
			IMAGE_MNT="" IMAGE_ATTACHED=0
			return 1
		fi
	fi
	rmdir "$IMAGE_MNT" 2>/dev/null || true
	IMAGE_MNT="" IMAGE_ATTACHED=0
}

# mounted_image_problems <image> <tag> <bundle-id> <manifest> <app-check>
# [args...]: attach the image read-only at a private mount point and check its
# root, the app and its payload, then run `<app-check> <mounted app> [args...]`
# (signed_app_problems for a release, rehearsal_app_problems for a rehearsal,
# so this function holds no path of its own to either). A failed detach fails
# the check.
# Run it only in a command substitution: its EXIT, HUP, INT and TERM traps
# detach the image and must not replace the caller's.
mounted_image_problems() {
	local img="$1" tag="$2" bundle="$3" manifest="$4" check="$5" rc=0 root entries
	shift 5
	IMAGE_MNT="$(mktemp -d)"
	chmod 700 "$IMAGE_MNT"
	trap 'detach_image || exit 1' EXIT
	trap 'detach_image; exit 129' HUP
	trap 'detach_image; exit 130' INT TERM
	if ! hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$IMAGE_MNT" "$img" >/dev/null 2>&1; then
		echo "    hdiutil cannot attach $img read-only"
		detach_image || true
		trap - EXIT HUP INT TERM
		return 1
	fi
	IMAGE_ATTACHED=1
	root="$IMAGE_MNT"
	entries="$(cd "$root" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | LC_ALL=C sort)"
	if [ -e "$root/.fseventsd" ] || [ -L "$root/.fseventsd" ]; then
		if [ -L "$root/.fseventsd" ] || [ ! -d "$root/.fseventsd" ]; then
			echo "    .fseventsd in the image is not a directory"; rc=1
		fi
		entries="$(printf '%s\n' "$entries" | grep -vxF .fseventsd || true)"
	fi
	[ "$entries" = $'Applications\nk3sm.app' ] ||
		{ echo "    the image root holds [${entries//$'\n'/, }], not exactly [Applications, k3sm.app] (and at most .fseventsd)"; rc=1; }
	if [ ! -L "$root/Applications" ] || [ "$(readlink "$root/Applications")" != /Applications ]; then
		echo "    Applications in the image is not a symlink to /Applications"; rc=1
	fi
	app_problems "$root/k3sm.app" "$tag" "$bundle" "$manifest" || rc=1
	"$check" "$root/k3sm.app" "$@" || rc=1
	detach_image || { echo "    hdiutil could not detach the image; it is still mounted"; rc=1; }
	trap - EXIT HUP INT TERM
	return "$rc"
}

# tree_version <tree>: the version the staged k3sm reports (`k3sm version`,
# first line, second field).
tree_version() {
	local out
	out="$("$1/k3sm" version 2>/dev/null)" || return 1
	printf '%s\n' "$out" | sed -n '1p' | awk '{print $2}'
}

# check_tree <tree> <tag>: the stage tree holds its manifest, matches it, and
# its k3sm reports the tag's version.
check_tree() {
	local tree="$1" tag="$2" problems v
	[ -x "$tree/k3sm" ] || die "the stage tree $tree has no executable k3sm"
	if ! problems="$(payload_problems "$tree" "$tree/PAYLOAD-SHA256")"; then
		printf '%s\n' "$problems" >&2
		refuse tree-manifest "the stage tree does not match its own PAYLOAD-SHA256."
	fi
	v="$(tree_version "$tree" || true)"
	[ "$v" = "${tag#v}" ] ||
		refuse version-mismatch "the staged k3sm reports version '$v', not '${tag#v}' ($tag)."
}

# check_app <app> <tag> <bundle-id> <manifest>: refuse on any app_problems.
check_app() {
	local problems
	if ! problems="$(app_problems "$@")"; then
		printf '%s\n' "$problems" >&2
		refuse app-mismatch "the built k3sm.app does not carry exactly the stage tree, its version and bundle id."
	fi
}

# ---- the full release -------------------------------------------------------------

VERSION="" STAGE="" CP_BUILD="" LDFLAGS="" IDENTITY="" TEAM_ID="" NOTES="" REPO="" K3SM_CHECKOUT=""
OUT_DIR="" STUB_PAYLOAD=0

# run_full: steps 1 to 7 of the header, over the globals parse_full sets.
run_full() {
	local publish build img core problems seal_sum
	publish="$K3SM_CHECKOUT/hack/release/publish.sh"
	build="$STAGE.app-build"
	core="$(core_version "$VERSION")"
	img="$build/$(image_name "$VERSION")"
	[ -x "$publish" ] || die "no executable $publish; --k3sm-dir names a k3sm checkout"
	[ ! -e "$STAGE" ] || die "--stage-dir $STAGE already exists; a release stages into a fresh directory"
	[ ! -e "$build" ] || die "$build already exists; remove it or choose another --stage-dir"

	echo "==> 1/7 publish.sh --through-verify (stage, sign, verify, package, seal)"
	"$publish" --through-verify --version "$VERSION" --stage-dir "$STAGE" --cp-build "$CP_BUILD" \
		--ldflags "$LDFLAGS" --identity "$IDENTITY" --team-id "$TEAM_ID" ||
		die "publish.sh --through-verify failed; nothing was uploaded"
	[ -d "$STAGE" ] && [ -f "$STAGE.seal" ] || die "publish.sh --through-verify left no tree or seal at $STAGE"
	STAGE="$(cd "$STAGE" && pwd)"

	echo "==> 2/7 the verified tree"
	check_tree "$STAGE" "$VERSION"
	seal_sum="$(sed -n 's/^payload_manifest_sha256=//p' "$STAGE.seal")"
	[ "$seal_sum" = "$(sha256_of "$STAGE/PAYLOAD-SHA256")" ] ||
		refuse seal-mismatch "the seal's payload_manifest_sha256 is not the tree's PAYLOAD-SHA256."

	echo "==> 3/7 build k3sm.app $core around the tree (team $TEAM_ID)"
	bash "$BUILD_APP" --version "$core" --team-id "$TEAM_ID" --payload "$STAGE" "$build" ||
		die "hack/build-app.sh failed"

	echo "==> 4/7 the app's payload against PAYLOAD-SHA256"
	check_app "$build/k3sm.app" "$VERSION" "$BUNDLE_ID" "$STAGE/PAYLOAD-SHA256"

	echo "==> 5/7 sign-and-notarize.sh (sign, notarize and staple the app and the image)"
	bash "$SIGN_NOTARIZE" "$build/k3sm.app" "$img" "$IDENTITY" "$TEAM_ID" ||
		die "sign-and-notarize.sh failed; nothing was uploaded"

	echo "==> 6/7 check the image"
	if ! problems="$(image_name_problems "$img" "$VERSION")"; then
		printf '%s\n' "$problems" >&2
		refuse image-name "nothing was uploaded."
	fi
	[ -f "$img" ] && [ ! -L "$img" ] || die "sign-and-notarize.sh left no image at $img"
	if ! problems="$(signed_image_problems "$img" "$TEAM_ID")"; then
		printf '%s\n' "$problems" >&2
		refuse image-unverified "the signed image fails its checks; nothing was uploaded."
	fi
	if ! problems="$(mounted_image_problems "$img" "$VERSION" "$BUNDLE_ID" "$STAGE/PAYLOAD-SHA256" signed_app_problems "$TEAM_ID")"; then
		printf '%s\n' "$problems" >&2
		refuse image-unverified "the image's contents fail their checks; nothing was uploaded."
	fi
	echo "    $(image_name "$VERSION") sha256 $(sha256_of "$img")"

	echo "==> 7/7 publish.sh --upload --disk-image (it checks everything again)"
	local repo_args=()
	[ -z "$REPO" ] || repo_args=(--repo "$REPO")
	"$publish" --upload --version "$VERSION" --stage-dir "$STAGE" --team-id "$TEAM_ID" \
		--notes-file "$NOTES" --disk-image "$img" ${repo_args[@]+"${repo_args[@]}"} ||
		die "publish.sh --upload failed; see its output"
	echo "==> released $VERSION with $(image_name "$VERSION")"
}

parse_full() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--version) VERSION="${2:?--version needs a value}"; shift 2 ;;
		--stage-dir) STAGE="${2:?--stage-dir needs a value}"; shift 2 ;;
		--cp-build) CP_BUILD="${2:?--cp-build needs a value}"; shift 2 ;;
		--ldflags) LDFLAGS="${2:?--ldflags needs a value}"; shift 2 ;;
		--identity) IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
		--team-id) TEAM_ID="${2:?--team-id needs a value}"; shift 2 ;;
		--notes-file) NOTES="${2:?--notes-file needs a value}"; shift 2 ;;
		--repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
		--k3sm-dir) K3SM_CHECKOUT="${2:?--k3sm-dir needs a value}"; shift 2 ;;
		--rehearsal) die "--rehearsal must be the first argument" ;;
		-h | --help) sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d'; exit 0 ;;
		*) die "unknown argument: $1" ;;
		esac
	done
	local v
	for v in VERSION STAGE CP_BUILD LDFLAGS IDENTITY TEAM_ID NOTES; do
		[ -n "${!v}" ] || die "missing a required flag (see --help): $v"
	done
	valid_version "$VERSION" || die "--version '$VERSION' is not vMAJOR.MINOR.PATCH[-rc.N]"
	[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "--team-id '$TEAM_ID' is not a 10-character Team ID"
	[ -z "$REPO" ] || [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo '$REPO' is not owner/name"
	[ -f "$NOTES" ] || die "--notes-file $NOTES is not a file"
	resolve_k3sm
	STAGE="${STAGE%/}"
}

resolve_k3sm() {
	[ -n "$K3SM_CHECKOUT" ] || K3SM_CHECKOUT="$APP_ROOT/../k3sm"
	[ -d "$K3SM_CHECKOUT/hack/release" ] || die "$K3SM_CHECKOUT is not a k3sm checkout (no hack/release); pass --k3sm-dir"
	K3SM_CHECKOUT="$(cd "$K3SM_CHECKOUT" && pwd)"
}

# ---- the rehearsal ------------------------------------------------------------------

# default_out_dir <tag>: a fresh directory in the nearest k3sm-io.scratch
# beside an ancestor of this repo.
default_out_dir() {
	local d="$APP_ROOT"
	while [ "$d" != / ]; do
		d="$(dirname "$d")"
		if [ -d "$d/k3sm-io.scratch" ] && [ ! -L "$d/k3sm-io.scratch" ]; then
			printf '%s/rehearsal-%s-%s' "$d/k3sm-io.scratch" "${1#v}" "$(date -u +%Y%m%dT%H%M%SZ)"
			return 0
		fi
	done
	return 1
}

# The only variables a rehearsal child (stage.sh, build-app.sh, make-dmg.sh
# and everything they run) receives. No signing identity, Team ID, notary
# profile, keychain, CODESIGN or GO override, and no CLAUDECODE or K3SM_AUTO
# either, so the children see nothing that could select a Developer ID.
SCRUB_KEEP="PATH HOME TMPDIR DEVELOPER_DIR GOPATH GOCACHE GOMODCACHE GOROOT GOTOOLCHAIN"

# scrubbed <command...>: run it under env -i with only SCRUB_KEEP.
scrubbed() {
	local keep=() v
	for v in $SCRUB_KEEP; do
		[ -z "${!v+x}" ] || keep+=("$v=${!v}")
	done
	env -i ${keep[@]+"${keep[@]}"} "$@"
}

# run_rehearsal: stage ad-hoc, build the rehearsal app, make the unsigned
# image, check it. No publish.sh, no gh, no sign-and-notarize.sh, no identity.
run_rehearsal() {
	local stage_sh tree build img core problems stage_args=()
	stage_sh="$K3SM_CHECKOUT/hack/release/stage.sh"
	core="$(core_version "$VERSION")"
	[ -x "$stage_sh" ] || die "no executable $stage_sh; --k3sm-dir names a k3sm checkout"
	[ ! -e "$OUT_DIR" ] || die "$OUT_DIR already exists; the rehearsal writes into a fresh directory"
	mkdir -p "$(dirname "$OUT_DIR")"
	mkdir "$OUT_DIR" || die "cannot create $OUT_DIR"
	OUT_DIR="$(cd "$OUT_DIR" && pwd)"
	tree="$OUT_DIR/stage"
	build="$OUT_DIR/app-build"
	img="$OUT_DIR/$(image_name "$VERSION" -unsigned)"
	[ "$STUB_PAYLOAD" = 0 ] || stage_args=(--stub-payload)

	echo "==> 1/5 stage.sh (ad-hoc, unsigned) into $tree"
	scrubbed "$stage_sh" "$tree" --ldflags "$LDFLAGS" ${stage_args[@]+"${stage_args[@]}"} || die "stage.sh failed"

	echo "==> 2/5 the staged tree"
	check_tree "$tree" "$VERSION"

	echo "==> 3/5 build the rehearsal k3sm.app $core (ad-hoc, no Team ID)"
	scrubbed bash "$BUILD_APP" --rehearsal --version "$core" --payload "$tree" "$build" || die "hack/build-app.sh failed"
	check_app "$build/k3sm.app" "$VERSION" "$REHEARSAL_BUNDLE_ID" "$tree/PAYLOAD-SHA256"
	if ! problems="$(rehearsal_app_problems "$build/k3sm.app")"; then
		printf '%s\n' "$problems" >&2
		refuse app-mismatch "the rehearsal k3sm.app is not an ad-hoc app without a Team ID."
	fi

	echo "==> 4/5 make-dmg.sh (unsigned)"
	scrubbed bash "$MAKE_DMG" "$build/k3sm.app" "$img" || die "make-dmg.sh failed"

	echo "==> 5/5 check the image"
	if ! problems="$(image_name_problems "$img" "$VERSION" -unsigned)"; then
		printf '%s\n' "$problems" >&2
		refuse image-name "the rehearsal image is misnamed."
	fi
	[ -f "$img" ] && [ ! -L "$img" ] || die "make-dmg.sh left no image at $img"
	if ! problems="$(mounted_image_problems "$img" "$VERSION" "$REHEARSAL_BUNDLE_ID" "$tree/PAYLOAD-SHA256" rehearsal_app_problems)"; then
		printf '%s\n' "$problems" >&2
		refuse image-unverified "the rehearsal image's contents fail their checks."
	fi
	echo "==> rehearsal image: $img"
	echo "    sha256 $(sha256_of "$img")"
	echo "    unsigned, bundle id $REHEARSAL_BUNDLE_ID, no Team ID: the app's root copy-out refuses it;"
	echo "    install its payload through the CLI: sudo $tree/k3sm install"
}

parse_rehearsal() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--version) VERSION="${2:?--version needs a value}"; shift 2 ;;
		--k3sm-dir) K3SM_CHECKOUT="${2:?--k3sm-dir needs a value}"; shift 2 ;;
		--ldflags) LDFLAGS="${2:?--ldflags needs a value}"; shift 2 ;;
		--out-dir) OUT_DIR="${2:?--out-dir needs a value}"; shift 2 ;;
		--stub-payload) STUB_PAYLOAD=1; shift ;;
		-h | --help) sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d'; exit 0 ;;
		*) die "unknown --rehearsal argument: $1 (the rehearsal takes no signing or upload flag)" ;;
		esac
	done
	[ -n "$VERSION" ] || die "--rehearsal needs --version"
	valid_version "$VERSION" || die "--version '$VERSION' is not vMAJOR.MINOR.PATCH[-rc.N]"
	[ -n "$LDFLAGS" ] || LDFLAGS="-X k3sm.io/k3sm/pkg/version.Version=${VERSION#v}"
	resolve_k3sm
	if [ -z "$OUT_DIR" ]; then
		OUT_DIR="$(default_out_dir "$VERSION")" || die "no k3sm-io.scratch directory beside an ancestor of $APP_ROOT; pass --out-dir"
	fi
	OUT_DIR="${OUT_DIR%/}"
}

# ---- self-test ----------------------------------------------------------------------
# Each case's assertion is a single-quoted string evaluated by check(), so its
# variables expand when the case runs (SC2016), and the helpers and variables
# it names are used only from inside those strings (SC2034, SC2329).
# shellcheck disable=SC2016,SC2034,SC2329
self_test() {
	local own_functions
	own_functions="$(declare -F | awk '{print $3}')"
	local T log fails=0 passes=0 out rc tag=v1.2.3 team=ABCDE12345 id="Developer ID Application: Example (ABCDE12345)"
	T="$(mktemp -d)"
	SELFTEST_TMP="$T"
	trap 'rm -rf "$SELFTEST_TMP"' EXIT
	umask 022
	log="$T/tool.log"
	: >"$log"
	export FAKE_TOOL_LOG="$log"
	ok() { echo "  ok   $1"; passes=$((passes + 1)); }
	bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
	# check <name> <command...>: ok when the command succeeds
	check() {
		local name="$1"; shift
		if "$@"; then ok "$name"; else bad "$name"; sed 's/^/       /' "$T/out" 2>/dev/null || true; echo "       log:"; sed 's/^/         /' "$log"; fi
	}
	# run_case <function>: run it in a subshell with errexit live (never in a
	# conditional context, where bash ignores set -e); output in $T/out, status
	# in CASE_RC.
	CASE_RC=0
	run_case() {
		sync_ctl
		set +e
		(
			set -e
			"$@"
		) >"$T/out" 2>&1
		CASE_RC=$?
		set -e
	}

	# The fakes read their FAKE_* controls from a file as well as the
	# environment, because the rehearsal starts its children under env -i. The
	# child fakes record the names in their environment, less those FAKE_*.
	local CTL="$T/fake.ctl"
	sync_ctl() {
		local v
		: >"$CTL"
		for v in $(compgen -v FAKE_); do printf "export %s='%s'\n" "$v" "${!v}" >>"$CTL"; done
	}
	# ---- fakes: every tool and script logs its argv to $FAKE_TOOL_LOG ----
	local F="$T/fakes" K="$T/k3sm" A="$T/appscripts"
	mkdir -p "$F" "$K/hack/release" "$A"
	for tool in notarytool security gh; do
		# shellcheck disable=SC2016 # $* and $FAKE_TOOL_LOG belong to the fake
		printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >>"$FAKE_TOOL_LOG"\nexit 97\n' "$tool" >"$F/$tool"
	done
	cat >"$F/codesign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "codesign $*" >>"$FAKE_TOOL_LOG"
[ "$1" = --verify ] && [ "${FAKE_CODESIGN_VERIFY_OK:-}" = 1 ] && exit 0
if [ "$1" = -dv ]; then
	printf '%b\n' "${FAKE_CODESIGN_DV:-Executable=${!#}\nIdentifier=io.k3sm.app.rehearsal\nSignature=adhoc\nTeamIdentifier=not set}" >&2
	exit 0
fi
exit 97
EOF
	cat >"$F/xcrun" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "xcrun $*" >>"$FAKE_TOOL_LOG"
[ "$1 $2" = "stapler validate" ] && [ "${FAKE_STAPLER_OK:-}" = 1 ] && exit 0
exit 97
EOF
	cat >"$F/spctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "spctl $*" >>"$FAKE_TOOL_LOG"
[ "${FAKE_SPCTL_OK:-}" = 1 ] && exit 0
exit 97
EOF
	# hdiutil attach "mounts" an image whose first line is `FIXTURE <dir>` by
	# copying <dir> (symlinks kept) to the mount point; detach empties it.
	cat >"$F/hdiutil" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "hdiutil $*" >>"$FAKE_TOOL_LOG"
case "$1" in
attach)
	shift
	mnt="" img="" ro=0
	while [ $# -gt 0 ]; do
		case "$1" in -mountpoint) mnt="$2"; shift 2 ;; -readonly) ro=1; shift ;; -*) shift ;; *) img="$1"; shift ;; esac
	done
	src="$(sed -n '1s/^FIXTURE //p' "$img" 2>/dev/null)"
	[ "$ro" = 1 ] && [ -n "$mnt" ] && [ -d "$mnt" ] && [ -n "$src" ] && [ -d "$src" ] || exit 1
	cp -R "$src/." "$mnt/" || exit 1
	exit 0 ;;
detach)
	[ -z "${FAKE_DETACH_FAIL:-}" ] || exit 16
	mnt="${!#}"
	[ -d "$mnt" ] || exit 1
	find "$mnt" -mindepth 1 -delete
	exit 0 ;;
esac
exit 97
EOF
	# The staged tree: an executable k3sm reporting FAKE_TREE_VERSION (or the
	# version given), a data file, PAYLOAD-SHA256 inside and beside it.
	cat >"$F/mk-tree" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
d="$1" v="$2"
mkdir -p "$d/share"
printf '#!/bin/sh\necho "k3sm %s"\necho "commit: fixture"\n' "${FAKE_TREE_VERSION:-$v}" >"$d/k3sm"
printf 'fixture\n' >"$d/share/notes.txt"
chmod 0755 "$d" "$d/share" "$d/k3sm"
chmod 0644 "$d/share/notes.txt"
{ echo "# fixture manifest"; (cd "$d" && shasum -a 256 k3sm share/notes.txt); } >"$d.PAYLOAD-SHA256"
if [ -n "${FAKE_MANIFEST_NO_NL:-}" ]; then
	printf '%s' "$(cat "$d.PAYLOAD-SHA256")" >"$d.PAYLOAD-SHA256"
fi
cp "$d.PAYLOAD-SHA256" "$d/PAYLOAD-SHA256"
EOF
	# publish.sh: --through-verify stages a tree and seals it; --upload succeeds.
	cat >"$K/hack/release/publish.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "publish.sh \$*" >>"\$FAKE_TOOL_LOG"
mode="" stage="" version=""
while [ \$# -gt 0 ]; do
	case "\$1" in
	--through-verify | --upload) mode="\$1"; shift ;;
	--stage-dir) stage="\$2"; shift 2 ;;
	--version) version="\$2"; shift 2 ;;
	*) shift ;;
	esac
done
if [ "\$mode" = --through-verify ]; then
	"$F/mk-tree" "\$stage" "\${version#v}"
	printf 'tag=%s\npayload_manifest_sha256=%s\n' "\$version" "\$(shasum -a 256 "\$stage/PAYLOAD-SHA256" | cut -d' ' -f1)" >"\$stage.seal"
fi
exit 0
EOF
	cat >"$K/hack/release/stage.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "stage.sh \$*" >>"\$FAKE_TOOL_LOG"
printf 'stage.sh %s\n' "\$(env | sed 's/=.*//' | grep -v '^FAKE_' | LC_ALL=C sort | tr '\n' ' ')" >>"$T/child-env"
v="\$(printf '%s\n' "\$*" | sed -n 's/.*pkg\/version.Version=\([^ ]*\).*/\1/p')"
"$F/mk-tree" "\$1" "\$v"
EOF
	# build-app.sh: copies the payload and its manifest like the real one and
	# writes an Info.plist; FAKE_APP_VERSION, FAKE_APP_BUNDLE_ID,
	# FAKE_APP_TAMPER (edit|extra|missing|dsstore) and FAKE_APP_STAMP bend it.
	cat >"$A/build-app.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "build-app.sh $*" >>"$FAKE_TOOL_LOG"
printf 'build-app.sh %s\n' "$(env | sed 's/=.*//' | grep -v '^FAKE_' | LC_ALL=C sort | tr '\n' ' ')" >>"$FAKE_CHILD_ENV"
version="" team="" payload="" out="" bundle=io.k3sm.app
while [ $# -gt 0 ]; do
	case "$1" in
	--version) version="$2"; shift 2 ;;
	--team-id) team="$2"; shift 2 ;;
	--payload) payload="$2"; shift 2 ;;
	--rehearsal) bundle=io.k3sm.app.rehearsal; shift ;;
	*) out="$1"; shift ;;
	esac
done
app="$out/k3sm.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
version="${FAKE_APP_VERSION:-$version}"
bundle="${FAKE_APP_BUNDLE_ID:-$bundle}"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
</dict></plist>
PLIST
stamp=""
[ -z "$team" ] || stamp="k3sm-team-id-pin:$team"
[ -z "${FAKE_APP_STAMP:-}" ] || stamp="k3sm-team-id-pin:$FAKE_APP_STAMP"
printf 'binary\0k3sm-team-id-pin:\0%s\0' "$stamp" >"$app/Contents/MacOS/k3sm-app"
cp -R "$payload" "$app/Contents/Resources/payload"
p="$app/Contents/Resources/payload"
(cd "$p" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) | sed 's|  \./|  |' >"$app/Contents/Resources/payload.sha256"
case "${FAKE_APP_TAMPER:-}" in
edit) printf 'tampered\n' >>"$p/share/notes.txt" ;;
extra) printf 'extra\n' >"$p/share/extra.txt" ;;
missing) rm "$p/share/notes.txt" ;;
dsstore) printf 'x' >"$p/.DS_Store" ;;
setuid) chmod 4755 "$p/k3sm" ;;
group-writable) chmod 0664 "$p/share/notes.txt" ;;
esac
EOF
	# sign-and-notarize.sh and make-dmg.sh: write a FIXTURE image of the app
	# plus an Applications symlink, and FAKE_IMAGE_EXTRA at its root if set.
	cat >"$F/mk-image" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
app="$1" dmg="$2"
src="$dmg.fixture"
mkdir -p "$src"
cp -R "$app" "$src/k3sm.app"
ln -s /Applications "$src/Applications"
[ -z "${FAKE_IMAGE_EXTRA:-}" ] || printf 'x' >"$src/$FAKE_IMAGE_EXTRA"
printf 'FIXTURE %s\n' "$src" >"$dmg"
EOF
	cat >"$A/sign-and-notarize.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "sign-and-notarize.sh \$*" >>"\$FAKE_TOOL_LOG"
"$F/mk-image" "\$1" "\$2"
EOF
	cat >"$A/make-dmg.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "make-dmg.sh \$*" >>"\$FAKE_TOOL_LOG"
printf 'make-dmg.sh %s\n' "\$(env | sed 's/=.*//' | grep -v '^FAKE_' | LC_ALL=C sort | tr '\n' ' ')" >>"$T/child-env"
"$F/mk-image" "\$1" "\$2"
EOF
	local f
	for f in "$F/"* "$K/hack/release/"*.sh "$A/"*.sh; do
		awk -v c="$CTL" 'NR == 1 { print; print "[ ! -f \"" c "\" ] || . \"" c "\""; next } { print }' "$f" >"$f.tmp"
		mv "$f.tmp" "$f"
	done
	chmod +x "$F/"* "$K/hack/release/"*.sh "$A/"*.sh
	export FAKE_CHILD_ENV="$T/child-env"
	sync_ctl
	local FPATH="$F:$PATH"
	printf 'notes\n' >"$T/notes.md"

	# Point this shell's script paths at the fakes; run_case subshells inherit.
	BUILD_APP="$A/build-app.sh" SIGN_NOTARIZE="$A/sign-and-notarize.sh" MAKE_DMG="$A/make-dmg.sh"

	# full_case <n>: set the full-mode globals for a fresh stage dir.
	full_case() {
		VERSION="${2:-$tag}" STAGE="$T/run-$1/stage" CP_BUILD="$T/cp" LDFLAGS="-X fixture" IDENTITY="$id"
		TEAM_ID="$team" NOTES="$T/notes.md" REPO="" K3SM_CHECKOUT="$K"
		mkdir -p "$T/run-$1"
		: >"$log"
	}
	in_fakes() { PATH="$FPATH" "$@"; }
	logged() { grep -q "$1" "$log"; }
	not_logged() { ! grep -q "$1" "$log"; }
	out_has() { grep -q -- "$1" "$T/out"; }

	echo "the attended refusal (full mode)"
	# Run in a new session with no controlling terminal and stdin not a tty.
	no_tty() { perl -MPOSIX -e 'my $p = fork; if ($p) { waitpid($p, 0); exit($? >> 8) } POSIX::setsid(); exec @ARGV' "$@" </dev/null >"$T/out" 2>&1; }
	sync_ctl
	local full_args=(--version "$tag" --stage-dir "$T/refused/stage" --cp-build "$T/cp" --ldflags x
		--identity "$id" --team-id "$team" --notes-file "$T/notes.md" --k3sm-dir "$K")
	: >"$log"
	rc=0; env CLAUDECODE=1 PATH="$FPATH" bash "$0" "${full_args[@]}" </dev/null >"$T/out" 2>&1 || rc=$?
	check "CLAUDECODE=1 refuses before any tool or script runs" \
		eval '[ "$rc" = 3 ] && out_has "REFUSE: automation-env: CLAUDECODE" && [ ! -s "$log" ] && [ ! -e "$T/refused" ]'
	rc=0; env K3SM_AUTO=1 PATH="$FPATH" bash "$0" "${full_args[@]}" </dev/null >"$T/out" 2>&1 || rc=$?
	check "K3SM_AUTO=1 refuses, named" \
		eval '[ "$rc" = 3 ] && out_has "automation-env: K3SM_AUTO" && [ ! -s "$log" ]'
	rc=0; env K3SM_AUTO= PATH="$FPATH" bash "$0" "${full_args[@]}" </dev/null >"$T/out" 2>&1 || rc=$?
	check "K3SM_AUTO set but empty refuses" \
		eval '[ "$rc" = 3 ] && out_has "automation-env: K3SM_AUTO" && [ ! -s "$log" ]'
	rc=0; no_tty env PATH="$FPATH" bash "$0" "${full_args[@]}" || rc=$?
	check "no terminal refuses, both checks named (stdin and /dev/tty)" \
		eval '[ "$rc" = 3 ] && out_has "no-tty: stdin is not a terminal" && out_has "no-tty: /dev/tty cannot be opened" && [ ! -s "$log" ]'
	rc=0; env CLAUDECODE=1 PATH="$FPATH" bash "$0" --no-such-flag </dev/null >"$T/out" 2>&1 || rc=$?
	check "the refusal precedes argument parsing" \
		eval '[ "$rc" = 3 ] && out_has REFUSE && ! out_has "unknown argument"'
	check "decision: attended (no automation, both terminals) passes" eval '[ -z "$(attended_problems 0 0 1 1)" ]'
	check "decision: stdin alone not a terminal refuses" eval '[ "$(attended_problems 0 0 0 1)" = "no-tty: stdin is not a terminal" ]'
	check "decision: /dev/tty alone unopenable refuses" eval '[ "$(attended_problems 0 0 1 0)" = "no-tty: /dev/tty cannot be opened" ]'
	check "decision: CLAUDECODE alone refuses" eval '[ "$(attended_problems 1 0 1 1)" = "automation-env: CLAUDECODE is set (an agent session)" ]'
	check "decision: K3SM_AUTO alone refuses" eval '[ "$(attended_problems 0 1 1 1)" = "automation-env: K3SM_AUTO is set (the autonomous loop)" ]'
	check "decision: every reason is named" eval '[ "$(attended_problems 1 1 0 0 | wc -l | tr -d " ")" = 4 ]'
	rc=0; env CLAUDECODE=1 PATH="$FPATH" bash "$0" --rehearsal </dev/null >"$T/out" 2>&1 || rc=$?
	check "the rehearsal is not refused under automation (it fails on its missing --version instead)" \
		eval '[ "$rc" = 1 ] && ! out_has REFUSE && out_has "needs --version"'

	echo "the full release with fakes"
	export FAKE_CODESIGN_VERIFY_OK=1 FAKE_STAPLER_OK=1 FAKE_SPCTL_OK=1
	full_case ok
	run_case in_fakes run_full
	local img_ok="$T/run-ok/stage.app-build/k3sm_1.2.3_darwin_arm64.dmg"
	check "a good run passes" eval '[ "$CASE_RC" = 0 ] && out_has "released v1.2.3"'
	local want_order got_order
	want_order="publish.sh --through-verify
build-app.sh
sign-and-notarize.sh
codesign --verify --strict -R=
xcrun stapler validate $img_ok
spctl -a -t open --context context:primary-signature $img_ok
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint
codesign --verify --strict --deep -R=
xcrun stapler validate
hdiutil detach
publish.sh --upload"
	printf '%s\n' "$want_order" >"$T/order"
	got_order="$(awk 'NR == FNR { p[++n] = $0; next } FNR == 1 { i = 1 } i <= n && index($0, p[i]) == 1 { i++ } END { print i - 1 }' "$T/order" "$log")"
	check "the calls run in order: through-verify, build-app, sign, image checks, mount, upload" \
		eval '[ "$got_order" = 11 ] && [ "$(grep -c "^publish.sh" "$log")" = 2 ] && [ "$(tail -1 "$log" | cut -d" " -f1-2)" = "publish.sh --upload" ]'
	check "through-verify gets the stage, cp-build, ldflags, identity and Team ID" \
		logged "^publish.sh --through-verify --version v1.2.3 --stage-dir $T/run-ok/stage --cp-build $T/cp --ldflags -X fixture --identity $id --team-id $team\$"
	check "build-app gets the core version, the Team ID and the verified tree" \
		logged "^build-app.sh --version 1.2.3 --team-id $team --payload $T/run-ok/stage $T/run-ok/stage.app-build\$"
	check "sign-and-notarize gets the app, the exact image name, the identity and the Team ID" \
		logged "^sign-and-notarize.sh $T/run-ok/stage.app-build/k3sm.app $img_ok $id $team\$"
	check "upload gets exactly the checked image" \
		logged "^publish.sh --upload --version v1.2.3 --stage-dir $T/run-ok/stage --team-id $team --notes-file $T/notes.md --disk-image $img_ok\$"
	check "the image is mounted read-only and detached" eval 'logged "^hdiutil attach -readonly" && logged "^hdiutil detach"'

	full_case rc v1.2.3-rc.1
	REPO=example/k3sm
	run_case in_fakes run_full
	check "a release candidate builds the core version and keeps the tag in the image name" \
		eval '[ "$CASE_RC" = 0 ] && logged "^build-app.sh --version 1.2.3 " && logged "k3sm_1.2.3-rc.1_darwin_arm64.dmg" && logged "^publish.sh --upload .* --repo example/k3sm\$"'

	local t
	for t in edit extra missing dsstore setuid group-writable; do
		full_case "tamper-$t"
		export FAKE_APP_TAMPER="$t"
		run_case in_fakes run_full
		unset FAKE_APP_TAMPER
		check "an app payload differing from the manifest ($t) refuses before signing" \
			eval '[ "$CASE_RC" = 3 ] && out_has "REFUSE: app-mismatch" && not_logged "^sign-and-notarize" && not_logged "^publish.sh --upload"'
	done

	full_case app-version
	export FAKE_APP_VERSION=1.2.4
	run_case in_fakes run_full
	unset FAKE_APP_VERSION
	check "an app version other than the tree's refuses before signing" \
		eval '[ "$CASE_RC" = 3 ] && out_has "CFBundleShortVersionString is .1.2.4., not .1.2.3." && not_logged "^sign-and-notarize" && not_logged "^publish.sh --upload"'
	full_case tree-version
	export FAKE_TREE_VERSION=1.2.4
	run_case in_fakes run_full
	unset FAKE_TREE_VERSION
	check "a tree reporting another version refuses before the app is built" \
		eval '[ "$CASE_RC" = 3 ] && out_has "REFUSE: version-mismatch" && not_logged "^build-app" && not_logged "^publish.sh --upload"'
	full_case bundle
	export FAKE_APP_BUNDLE_ID=io.k3sm.app.rehearsal
	run_case in_fakes run_full
	unset FAKE_APP_BUNDLE_ID
	check "a release app with the rehearsal bundle id refuses" \
		eval '[ "$CASE_RC" = 3 ] && out_has "CFBundleIdentifier is .io.k3sm.app.rehearsal." && not_logged "^publish.sh --upload"'

	check "name: the exact release name passes" image_name_problems "/x/k3sm_1.2.3_darwin_arm64.dmg" v1.2.3
	local n
	for n in k3sm_v1.2.3_darwin_arm64.dmg k3sm_1.2.3_darwin_arm64-unsigned.dmg k3sm_1.2.4_darwin_arm64.dmg \
		k3sm_1.2.3_darwin_amd64.dmg k3sm.dmg k3sm_1.2.3_darwin_arm64.dmg.dmg; do
		check "name: $n is refused for v1.2.3" eval '! image_name_problems "/x/$n" v1.2.3 >/dev/null'
	done
	check "name: the rehearsal name passes only with -unsigned" \
		eval 'image_name_problems /x/k3sm_1.2.3-rc.1_darwin_arm64-unsigned.dmg v1.2.3-rc.1 -unsigned && ! image_name_problems /x/k3sm_1.2.3-rc.1_darwin_arm64.dmg v1.2.3-rc.1 -unsigned >/dev/null'

	full_case extra-root
	export FAKE_IMAGE_EXTRA=README.txt
	run_case in_fakes run_full
	unset FAKE_IMAGE_EXTRA
	check "an extra entry at the image root refuses before upload" \
		eval '[ "$CASE_RC" = 3 ] && out_has "image root holds" && not_logged "^publish.sh --upload"'
	full_case unstapled
	unset FAKE_STAPLER_OK
	run_case in_fakes run_full
	export FAKE_STAPLER_OK=1
	check "an image stapler validate rejects refuses before upload" \
		eval '[ "$CASE_RC" = 3 ] && out_has "stapler validate rejects the image" && not_logged "^publish.sh --upload"'
	full_case unsigned
	unset FAKE_CODESIGN_VERIFY_OK
	run_case in_fakes run_full
	export FAKE_CODESIGN_VERIFY_OK=1
	check "a signature codesign rejects refuses before upload" \
		eval '[ "$CASE_RC" = 3 ] && out_has "codesign --verify --strict rejects the image" && not_logged "^publish.sh --upload"'
	full_case nospctl
	unset FAKE_SPCTL_OK
	run_case in_fakes run_full
	export FAKE_SPCTL_OK=1
	check "an image spctl rejects refuses before upload" \
		eval '[ "$CASE_RC" = 3 ] && out_has "spctl -a -t open" && not_logged "^publish.sh --upload"'
	full_case wrong-pin
	export FAKE_APP_STAMP=ZYXWV98765
	run_case in_fakes run_full
	unset FAKE_APP_STAMP
	check "an app pinned to another Team ID refuses before upload" \
		eval '[ "$CASE_RC" = 3 ] && out_has "not pinned to exactly the Team ID $team" && not_logged "^publish.sh --upload"'
	full_case no-newline
	export FAKE_MANIFEST_NO_NL=1 FAKE_APP_TAMPER=edit
	run_case in_fakes run_full
	unset FAKE_MANIFEST_NO_NL FAKE_APP_TAMPER
	check "a manifest without a final newline whose last file was edited refuses" \
		eval '[ "$CASE_RC" = 3 ] && out_has "share/notes.txt: sha256 differs" && not_logged "^sign-and-notarize" && not_logged "^publish.sh --upload"'
	full_case no-newline-ok
	export FAKE_MANIFEST_NO_NL=1
	run_case in_fakes run_full
	unset FAKE_MANIFEST_NO_NL
	check "a manifest without a final newline and an intact payload passes" eval '[ "$CASE_RC" = 0 ]'
	full_case detach
	export FAKE_DETACH_FAIL=1
	run_case in_fakes run_full
	unset FAKE_DETACH_FAIL
	check "a failed detach is a failure with a clear message, before upload" \
		eval '[ "$CASE_RC" = 3 ] && out_has "could not detach the image" && out_has "REFUSE: image-unverified" && not_logged "^publish.sh --upload"'
	full_case exists
	mkdir -p "$T/run-exists/stage.app-build"
	run_case in_fakes run_full
	check "an existing app-build directory refuses before anything runs" \
		eval '[ "$CASE_RC" = 1 ] && [ ! -s "$log" ]'

	echo "the rehearsal with fakes"
	# rehearsal_case <n> [version]: set the rehearsal globals.
	rehearsal_case() {
		VERSION="${2:-$tag}" K3SM_CHECKOUT="$K" OUT_DIR="$T/reh-$1/out" STUB_PAYLOAD=0
		LDFLAGS="-X k3sm.io/k3sm/pkg/version.Version=${VERSION#v}"
		mkdir -p "$T/reh-$1"
		: >"$log"
		: >"$T/child-env"
	}
	# identity_signs <log>: codesign calls that sign with anything but ad-hoc.
	identity_signs() { grep -E '^codesign .*(--sign|-s) ' "$1" | grep -Ev -- '(--sign|-s) - ' || true; }
	printf 'codesign --force --sign - --timestamp=none x\n' >"$T/sample-adhoc"
	printf 'codesign --force --options runtime --sign Developer ID Application: X x\n' >"$T/sample-identity"
	check "detector: an ad-hoc sign is not an identity sign" eval '[ -z "$(identity_signs "$T/sample-adhoc")" ]'
	check "detector: a Developer ID sign is caught" eval '[ -n "$(identity_signs "$T/sample-identity")" ]'

	rehearsal_case ok v1.2.3-rc.1
	run_case in_fakes run_rehearsal
	local rimg="$T/reh-ok/out/k3sm_1.2.3-rc.1_darwin_arm64-unsigned.dmg"
	check "a rehearsal passes and writes the -unsigned image" eval '[ "$CASE_RC" = 0 ] && [ -f "$rimg" ] && out_has "rehearsal image: $rimg"'
	check "the rehearsal never calls publish.sh, gh, sign-and-notarize, notarytool, stapler or spctl" \
		eval 'not_logged "publish.sh" && not_logged "^gh " && not_logged "sign-and-notarize" && not_logged "notarytool" && not_logged "stapler" && not_logged "^spctl"'
	check "the rehearsal makes no identity codesign" eval '[ -z "$(identity_signs "$log")" ]'
	check "the rehearsal stages with the version stamp and builds with --rehearsal, no Team ID" \
		eval 'logged "^stage.sh $T/reh-ok/out/stage --ldflags -X k3sm.io/k3sm/pkg/version.Version=1.2.3-rc.1\$" && logged "^build-app.sh --rehearsal --version 1.2.3 --payload " && not_logged "^build-app.sh.*--team-id"'
	check "the rehearsal image is made by make-dmg.sh and mounted read-only" \
		eval 'logged "^make-dmg.sh .*/k3sm.app $rimg\$" && logged "^hdiutil attach -readonly"'
	check "the rehearsal app carries io.k3sm.app.rehearsal" \
		eval '[ "$(plutil -extract CFBundleIdentifier raw -o - "$T/reh-ok/out/app-build/k3sm.app/Contents/Info.plist")" = io.k3sm.app.rehearsal ]'
	# Every function the rehearsal path reaches: the closure, over this
	# script's own functions, of the names each body mentions, from its two
	# entry points. mounted_image_problems runs the app check its caller
	# names, so the rehearsal's own call names it and it is in the closure.
	local queue="parse_rehearsal run_rehearsal" reached=" " fn g body banned=""
	while [ -n "$queue" ]; do
		fn="${queue%% *}"
		[ "$fn" = "$queue" ] && queue="" || queue="${queue#* }"
		case "$reached" in *" $fn "*) continue ;; esac
		reached="$reached$fn "
		body="$(declare -f "$fn")"
		for g in $own_functions; do
			case "$reached" in *" $g "*) continue ;; esac
			if grep -Eq "(^|[^A-Za-z0-9_])$g([^A-Za-z0-9_]|$)" <<<"$body"; then queue="${queue:+$queue }$g"; fi
		done
		# Signing, notarizing, uploading or any signed-release path.
		if grep -Eq 'publish|(^|[^A-Za-z0-9_])gh |SIGN_NOTARIZE|IDENTITY|TEAM_ID|signed_|notarytool|stapler|spctl|security |--sign|codesign -s|codesign --force' <<<"$body"; then
			banned="$banned $fn"
		fi
	done
	check "the rehearsal's reach includes every checker and helper on its path" \
		eval 'for g in run_rehearsal parse_rehearsal check_app app_problems payload_problems mounted_image_problems rehearsal_app_problems detach_image scrubbed check_tree tree_version image_name_problems team_stamps; do case "$reached" in *" $g "*) ;; *) echo "not reached: $g" >"$T/out"; false ;; esac; done'
	check "no function the rehearsal reaches signs, notarizes, uploads or runs a signed check" \
		eval '[ -z "$banned" ] || { echo "banned:$banned" >"$T/out"; false; }'
	check "the reach excludes the signed checks and the full release" \
		eval 'case "$reached" in *" signed_app_problems "* | *" signed_image_problems "* | *" run_full "*) false ;; esac'
	check "the rehearsal's children ran under env -i with only the kept variables" \
		eval '[ "$(grep -c . "$T/child-env")" = 3 ] && ! sed "s/^[^ ]* //" "$T/child-env" | tr " " "\n" | sed "/^$/d" | grep -Evx "PATH|HOME|TMPDIR|DEVELOPER_DIR|GO[A-Z]*|PWD|SHLVL|_|OLDPWD" >"$T/out"'

	rehearsal_case scrub
	export CODESIGN_IDENTITY="$id" K3SM_TEAM_ID="$team" NOTARY_PROFILE=k3sm-notary KEYCHAIN=login.keychain CODESIGN=/bin/echo K3SM_AUTO=1
	run_case in_fakes run_rehearsal
	unset CODESIGN_IDENTITY K3SM_TEAM_ID NOTARY_PROFILE KEYCHAIN CODESIGN K3SM_AUTO
	check "identity, team, notary, keychain and codesign variables never reach a rehearsal child" \
		eval '[ "$CASE_RC" = 0 ] && [ "$(grep -c . "$T/child-env")" = 3 ] && ! grep -Eq "IDENTITY|TEAM|NOTARY|KEYCHAIN|CODESIGN|K3SM_AUTO|CLAUDECODE|FAKE_" "$T/child-env"'

	rehearsal_case devid
	export FAKE_CODESIGN_DV='Executable=x\nIdentifier=io.k3sm.app.rehearsal\nSignature size=9000\nAuthority=Developer ID Application: Example (ABCDE12345)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nTeamIdentifier=ABCDE12345'
	run_case in_fakes run_rehearsal
	unset FAKE_CODESIGN_DV
	check "a Developer ID signature on the rehearsal app refuses" \
		eval '[ "$CASE_RC" = 3 ] && out_has "does not report Signature=adhoc" && out_has "signed by a certificate authority" && out_has "names a Team ID: TeamIdentifier=ABCDE12345" && not_logged "^make-dmg"'
	rehearsal_case teamonly
	export FAKE_CODESIGN_DV='Signature=adhoc\nTeamIdentifier=ABCDE12345'
	run_case in_fakes run_rehearsal
	unset FAKE_CODESIGN_DV
	check "an ad-hoc signature naming a Team ID refuses" \
		eval '[ "$CASE_RC" = 3 ] && out_has "names a Team ID" && not_logged "^make-dmg"'
	rehearsal_case nl
	export FAKE_MANIFEST_NO_NL=1 FAKE_APP_TAMPER=edit
	run_case in_fakes run_rehearsal
	unset FAKE_MANIFEST_NO_NL FAKE_APP_TAMPER
	check "a rehearsal manifest without a final newline still checks its last file" \
		eval '[ "$CASE_RC" = 3 ] && out_has "share/notes.txt: sha256 differs" && not_logged "^make-dmg"'

	rehearsal_case bundle
	export FAKE_APP_BUNDLE_ID=io.k3sm.app
	run_case in_fakes run_rehearsal
	unset FAKE_APP_BUNDLE_ID
	check "a rehearsal app with the release bundle id refuses" \
		eval '[ "$CASE_RC" = 3 ] && out_has "CFBundleIdentifier is .io.k3sm.app., not .io.k3sm.app.rehearsal." && not_logged "^make-dmg"'
	rehearsal_case pinned
	export FAKE_APP_STAMP="$team"
	run_case in_fakes run_rehearsal
	unset FAKE_APP_STAMP
	check "a rehearsal app holding a Team ID stamp refuses" \
		eval '[ "$CASE_RC" = 3 ] && out_has "holds 1 Team ID stamps" && not_logged "^make-dmg"'
	rehearsal_case tamper
	export FAKE_APP_TAMPER=edit
	run_case in_fakes run_rehearsal
	unset FAKE_APP_TAMPER
	check "a rehearsal payload differing from the manifest refuses" \
		eval '[ "$CASE_RC" = 3 ] && out_has "share/notes.txt: sha256 differs" && not_logged "^make-dmg"'
	rehearsal_case version
	export FAKE_TREE_VERSION=9.9.9
	run_case in_fakes run_rehearsal
	unset FAKE_TREE_VERSION
	check "a rehearsal tree reporting another version refuses" \
		eval '[ "$CASE_RC" = 3 ] && out_has "REFUSE: version-mismatch" && not_logged "^build-app"'
	rc=0; env PATH="$FPATH" bash "$0" --rehearsal --version "$tag" --k3sm-dir "$K" --identity "$id" </dev/null >"$T/out" 2>&1 || rc=$?
	check "the rehearsal takes no identity flag" eval '[ "$rc" = 1 ] && out_has "takes no signing or upload flag"'

	echo "release self-test: $passes passed, $fails failed"
	[ "$fails" -eq 0 ] || { echo "release self-test: FAILED"; return 1; }
	echo "release self-test: all passed"
}

# ---- main -------------------------------------------------------------------------
case "${1:-}" in
--self-test)
	[ "$#" -eq 1 ] || { echo "release: --self-test takes no other arguments" >&2; exit 2; }
	self_test
	exit $?
	;;
--rehearsal)
	shift
	parse_rehearsal "$@"
	run_rehearsal
	exit 0
	;;
esac
check_attended
parse_full "$@"
run_full
