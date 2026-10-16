#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# build-version.sh [<source-dir>]
#
# Prints the version a development build of the app carries (the
# K3smBuildVersion key hack/build-app.sh writes into Info.plist when it runs
# without --version), in the Go pseudo-version form k3sm's own development
# builds report:
#
#   v<X.Y.(Z+1)>-0.<commit time, UTC yyyymmddhhmmss>-<12-hex commit prefix>
#
# where vX.Y.Z is the highest release tag (vX.Y.Z, digits only, no
# pre-release) reachable from HEAD, or v0.0.0-0.<time>-<sha12> with none. A
# tree with changes (tracked or untracked, as git status reports them) adds
# +dirty. A build at a tagged commit still gets the pseudo-version: only a
# release build (build-app.sh --version) carries a release version.
#
# <source-dir> (default: the repository this script is in) must be the top of
# its own git checkout; anything else (a source tarball, a copy inside some
# other repository, no git at all) prints v0.0.0-unknown.
set -euo pipefail

dir="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
dir="$(cd "$dir" && pwd -P)"

unknown() {
	echo "v0.0.0-unknown"
	exit 0
}

command -v git >/dev/null 2>&1 || unknown
top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || unknown
[ "$(cd "$top" && pwd -P)" = "$dir" ] || unknown
sha="$(git -C "$dir" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" || unknown
ct="$(git -C "$dir" log -1 --format=%ct HEAD 2>/dev/null)" || unknown
printf '%s\n' "$ct" | grep -Eqx '[0-9]+' || unknown
when="$(TZ=UTC date -r "$ct" +%Y%m%d%H%M%S)"

base=v0.0.0
latest="$(git -C "$dir" tag --merged HEAD 2>/dev/null \
	| grep -Ex 'v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})' \
	| sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true)"
if [ -n "$latest" ]; then
	IFS=. read -r major minor patch <<<"$latest"
	base="v$major.$minor.$((patch + 1))"
fi

version="$base-0.$when-${sha:0:12}"
if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
	version="$version+dirty"
fi
echo "$version"
