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
# pre-release) reachable from HEAD in this checkout or in the k3sm checkout
# beside it, or v0.0.0-0.<time>-<sha12> with none. The app's releases are
# named by k3sm's tags (an app release carries that release's payload), so the
# k3sm checkout is where they are: K3SM_DIR when set, else <source-dir>/../k3sm,
# counted only when it is the top of its own git checkout. The time and the
# commit are always the app's own. The result ranks above that release and
# below every rc and release of the next patch, as k3sm's own build does. A
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

# release_tags <checkout>: the release tags reachable from its HEAD, without v.
release_tags() {
	git -C "$1" tag --merged HEAD 2>/dev/null \
		| grep -Ex 'v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})' \
		| sed 's/^v//' || true
}

k3sm="${K3SM_DIR:-$dir/../k3sm}"
tags="$(release_tags "$dir")"
if [ -d "$k3sm" ]; then
	k3sm="$(cd "$k3sm" && pwd -P)"
	ktop="$(git -C "$k3sm" rev-parse --show-toplevel 2>/dev/null || true)"
	if [ -n "$ktop" ] && [ "$(cd "$ktop" && pwd -P)" = "$k3sm" ]; then
		tags="$(printf '%s\n%s\n' "$tags" "$(release_tags "$k3sm")")"
	fi
fi

base=v0.0.0
latest="$(printf '%s\n' "$tags" | grep -v '^$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true)"
if [ -n "$latest" ]; then
	IFS=. read -r major minor patch <<<"$latest"
	base="v$major.$minor.$((patch + 1))"
fi

version="$base-0.$when-${sha:0:12}"
if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
	version="$version+dirty"
fi
echo "$version"
