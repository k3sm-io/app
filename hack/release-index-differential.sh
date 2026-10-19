#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# release-index-differential.sh -- run the same seeded mutants of the release
# index golden through this repo's decoder and through k3sm's Go
# ParseReleaseIndex, and fail on any mutant the two decide differently: one
# accepts and the other refuses, or both accept with different fields.
#
#   K3SM_DIR=<k3sm checkout> hack/release-index-differential.sh [count] [seed]
#
# The mutants come from Tests/K3smStatusTests/ReleaseIndexMutator.swift, the
# generator the fuzz test uses (count 5000, the test's seed by default). The
# Go half builds k3sm's pkg/update with a Go workspace over the k3sm checkout
# and its apis, runtimed and darwin-net siblings, so it needs a Go toolchain
# and k3sm's module dependencies; that is why hack/ci.sh does not run it.
set -euo pipefail
cd "$(dirname "$0")/.."

count="${1:-5000}"
seed="${2:-7724644699239695448}" # 0x6B33736D52494458, the fuzz test's seed
k3sm_dir="${K3SM_DIR:-../k3sm}"
[ -f "$k3sm_dir/pkg/update/releaseindex.go" ] || { echo "FAIL: no k3sm checkout at $k3sm_dir (set K3SM_DIR)"; exit 1; }
k3sm_dir="$(cd "$k3sm_dir" && pwd)"
parent="$(dirname "$k3sm_dir")"
for r in apis runtimed darwin-net; do
	[ -f "$parent/$r/go.mod" ] || { echo "FAIL: no $r checkout beside $k3sm_dir; the k3sm module needs it"; exit 1; }
done
command -v go >/dev/null || { echo "FAIL: no go on PATH"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/mutants" "$tmp/checker"

echo "==> build the Swift decoder with the mutator"
swiftc -O -module-name K3smStatus -D RELEASE_INDEX_DIFFERENTIAL -o "$tmp/swift-verdicts" \
	Sources/K3smStatus/ReleaseIndex.swift Sources/K3smStatus/Version.swift \
	Tests/K3smStatusTests/ReleaseIndexMutator.swift hack/release-index-differential/main.swift
"$tmp/swift-verdicts" Tests/K3smStatusTests/Fixtures/release-index/index.json "$count" "$seed" "$tmp/mutants" > "$tmp/swift.txt"

echo "==> run k3sm's ParseReleaseIndex on the same mutants"
cp hack/release-index-differential/checker.go "$tmp/checker/main.go"
gover="$(sed -n 's/^go //p' "$k3sm_dir/go.mod" | head -n 1)"
printf 'module local/releaseindexdifferential\n\ngo %s\n' "$gover" > "$tmp/checker/go.mod"
printf 'go %s\n\nuse (\n\t%s\n\t%s\n\t%s\n\t%s\n\t%s\n)\n' "$gover" \
	"$parent/apis" "$parent/darwin-net" "$k3sm_dir" "$parent/runtimed" "$tmp/checker" > "$tmp/go.work"
(cd "$tmp/checker" && GOWORK="$tmp/go.work" CGO_ENABLED=1 go run . "$tmp/mutants") > "$tmp/go.txt"

accepted="$(grep -c $'\taccept\t' "$tmp/swift.txt" || true)"
if ! diff "$tmp/go.txt" "$tmp/swift.txt" > "$tmp/diff.txt"; then
	head -n 40 "$tmp/diff.txt" | sed 's/^/    /'
	echo "FAIL: k3sm (<) and the app (>) decide $(grep -c '^<' "$tmp/diff.txt") of $count mutants differently (seed $seed)"
	exit 1
fi
echo "    ok: $count mutants, $accepted accepted by both, the rest refused by both, same fields (seed $seed)"
