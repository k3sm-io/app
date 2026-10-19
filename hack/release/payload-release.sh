#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# payload-release.sh -- the exact payload tag and the sealed payload.release
# record of a release build of k3sm.app. hack/build-app.sh runs it; the
# release.sh self-test runs it on fixtures.
#
#   payload-release.sh check-tag <tag> <x.y.z>
#   payload-release.sh write <seal> <tag> <payload-manifest> <out>
#
# check-tag exits 0 when <tag> is a release tag, vMAJOR.MINOR.PATCH with an
# optional -rc.N (no leading zeros, at most nine digits a number, N at most
# four), whose core version is exactly <x.y.z>. It is the grammar
# AppVersion.payloadTag reads back from K3smPayloadTag, so a tag the app would
# refuse is never stamped.
#
# write reads <seal>, the key=value file k3sm's hack/release/publish.sh
# --through-verify leaves beside its stage tree, and writes <out>
# (Contents/Resources/payload.release) with three lines after a comment:
#
#   tag=<tag>
#   tarball_sha256=<the seal's tarball_sha256>
#   payload_manifest_sha256=<the seal's payload_manifest_sha256>
#
# It refuses, writing nothing, unless the seal is a regular file (not a
# symlink) holding each of tag, payload_manifest_sha256 and tarball_sha256
# exactly once, its tag equals <tag> and passes check-tag, both digests are 64
# lowercase hex characters, and payload_manifest_sha256 equals the SHA-256 of
# <payload-manifest> (the copy of PAYLOAD-SHA256 the bundle carries). Other
# seal keys (head, team_id) are not copied. <out> must not exist; it is written
# through a temporary file, mode 0644.
set -euo pipefail

die() { echo "payload-release: refused: $*" >&2; exit 1; }

# valid_tag <tag>: the release tag grammar.
valid_tag() {
	[[ "$1" =~ ^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-rc\.(0|[1-9][0-9]{0,3}))?$ ]]
}

# tag_core <tag> -> MAJOR.MINOR.PATCH
tag_core() { local v="${1#v}"; printf '%s' "${v%%-*}"; }

check_tag() {
	local tag="$1" version="$2"
	valid_tag "$tag" || die "the payload tag must be vMAJOR.MINOR.PATCH[-rc.N], got: $tag"
	[ "$(tag_core "$tag")" = "$version" ] ||
		die "the payload tag $tag is not a tag of the version $version"
}

# seal_get <seal> <key>: the one value of <key>; refuses a missing or repeated key.
seal_get() {
	local n
	n="$(grep -c "^$2=" "$1" || true)"
	[ "$n" = 1 ] || die "the seal holds $n $2 lines, not exactly one: $1"
	sed -n "s/^$2=//p" "$1"
}

write_release() {
	local seal="$1" tag="$2" manifest="$3" out="$4" sealed_tag manifest_sum tarball_sum tmp
	valid_tag "$tag" || die "the payload tag must be vMAJOR.MINOR.PATCH[-rc.N], got: $tag"
	if [ -L "$seal" ] || [ ! -f "$seal" ]; then die "no seal (a regular file) at $seal"; fi
	if [ -L "$manifest" ] || [ ! -f "$manifest" ]; then die "no payload manifest (a regular file) at $manifest"; fi
	[ ! -e "$out" ] && [ ! -L "$out" ] || die "$out already exists"
	sealed_tag="$(seal_get "$seal" tag)"
	manifest_sum="$(seal_get "$seal" payload_manifest_sha256)"
	tarball_sum="$(seal_get "$seal" tarball_sha256)"
	[ "$sealed_tag" = "$tag" ] || die "the seal is for $sealed_tag, not $tag"
	[[ "$manifest_sum" =~ ^[0-9a-f]{64}$ ]] || die "the seal's payload_manifest_sha256 is not 64 lowercase hex characters"
	[[ "$tarball_sum" =~ ^[0-9a-f]{64}$ ]] || die "the seal's tarball_sha256 is not 64 lowercase hex characters"
	[ "$(/usr/bin/shasum -a 256 "$manifest" | cut -d' ' -f1)" = "$manifest_sum" ] ||
		die "the seal's payload_manifest_sha256 is not the SHA-256 of $manifest"
	tmp="$out.tmp.$$"
	{
		echo "# k3sm payload release v1: the payload this bundle carries, from the k3sm publish seal"
		echo "tag=$tag"
		echo "tarball_sha256=$tarball_sum"
		echo "payload_manifest_sha256=$manifest_sum"
	} >"$tmp" || { rm -f "$tmp"; die "could not write $out"; }
	chmod 0644 "$tmp"
	mv "$tmp" "$out"
}

case "${1:-}" in
check-tag)
	[ "$#" -eq 3 ] || { echo "usage: payload-release.sh check-tag <tag> <x.y.z>" >&2; exit 2; }
	check_tag "$2" "$3"
	;;
write)
	[ "$#" -eq 5 ] || { echo "usage: payload-release.sh write <seal> <tag> <payload-manifest> <out>" >&2; exit 2; }
	write_release "$2" "$3" "$4" "$5"
	;;
*)
	echo "usage: payload-release.sh check-tag <tag> <x.y.z> | write <seal> <tag> <payload-manifest> <out>" >&2
	exit 2
	;;
esac
