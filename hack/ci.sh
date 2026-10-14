#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# ci.sh -- the k3sm app repo's gate. Run from anywhere; it works on a lone clone.
#
#   0. the package declares no dependencies
#   1. swift build
#   2. swift test (the status decoder, the visibility rule, role detection)
#   3. hack/build-app.sh into a temp dir (builds, signs and verifies the bundle)
#   4. shellcheck over every hack/**/*.sh
#   5. hack/build-app.sh --payload with a fake payload: the refusals, the
#      manifest, the version stamp; then make-dmg.sh on the result
#   6. sign-and-notarize.sh refuses to run unattended
#   7. every .swift file carries the Apache-2.0 header
#   8. every file under .github/workflows/ is dormant (fully commented out)
#   9. the vendored status fixtures match a sibling k3sm checkout, when one exists
#  10. the dependency supply-chain check: its self-test, then the live tree
set -euo pipefail
cd "$(dirname "$0")/.."

# The Command Line Tools ship the swift-testing macro plugin in a directory
# SwiftPM does not search on its own; point the compiler at it. A full Xcode
# toolchain finds it without help, so this applies only when the plugin exists.
TEST_FLAGS=()
devdir="$(xcode-select -p 2>/dev/null || true)"
plugdir="$devdir/usr/lib/swift/host/plugins/testing"
if [ -n "$devdir" ] && [ -f "$plugdir/libTestingMacros.dylib" ]; then
	TEST_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$plugdir")
fi

echo "==> no third-party dependencies"
# The package depends on nothing outside the toolchain, which is also why there
# is no Package.resolved to commit: SwiftPM writes one only when it has pins.
deps="$(swift package show-dependencies 2>&1)"
printf '%s\n' "$deps" | grep -q '^No external dependencies found' \
	|| { echo "FAIL: the package must not declare dependencies:"; printf '%s\n' "$deps"; exit 1; }
[ ! -e Package.resolved ] || grep -q '"pins" : \[\s*\]' Package.resolved \
	|| { echo "FAIL: Package.resolved carries pins"; exit 1; }
echo "    ok"

echo "==> swift build"
swift build

echo "==> swift test"
# ${arr[@]+"${arr[@]}"} expands to nothing for an empty array; macOS bash 3.2
# treats a bare "${arr[@]}" on an empty array as unbound under set -u.
swift test ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"}

echo "==> hack/build-app.sh (temp dir)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bash hack/build-app.sh "$tmp/out"
[ -d "$tmp/out/k3sm.app" ] || { echo "FAIL: bundle not produced"; exit 1; }
[ ! -e "$tmp/out/k3sm.app/Contents/Resources/payload" ] || { echo "FAIL: a payload appeared without --payload"; exit 1; }

echo "==> shellcheck (hack/**/*.sh)"
command -v shellcheck >/dev/null || { echo "FAIL: shellcheck is not installed (brew install shellcheck)"; exit 1; }
find hack -name '*.sh' -print0 | xargs -0 shellcheck
echo "    ok"

echo "==> hack/build-app.sh --payload (fake payload)"
# A tiny stand-in for the stage.sh tree: an executable k3sm and one data file.
make_payload() {
	mkdir -p "$1/share"
	printf '#!/bin/sh\necho "k3sm v1.2.3"\n' > "$1/k3sm"
	printf 'fixture\n' > "$1/share/notes.txt"
	chmod 0755 "$1" "$1/share" "$1/k3sm"
	chmod 0644 "$1/share/notes.txt"
}
# Each refusal must fail before anything is built and leave no bundle.
expect_refused() {
	local name="$1"; shift
	local out="$tmp/refused-$name"
	if bash hack/build-app.sh "$@" "$out" > "$tmp/refused.log" 2>&1; then
		echo "FAIL: build-app accepted: $name"; cat "$tmp/refused.log"; exit 1
	fi
	grep -q 'refused' "$tmp/refused.log" || { echo "FAIL: no refusal message: $name"; cat "$tmp/refused.log"; exit 1; }
	[ ! -e "$out/k3sm.app" ] || { echo "FAIL: a bundle was produced: $name"; exit 1; }
	echo "    refused: $name"
}
for case in symlink setuid group-writable other-writable-dir no-k3sm; do
	bad="$tmp/bad-$case"
	make_payload "$bad"
	case "$case" in
	symlink) ln -s /etc/hosts "$bad/share/hosts" ;;
	setuid) chmod 4755 "$bad/k3sm" ;;
	group-writable) chmod 0664 "$bad/share/notes.txt" ;;
	other-writable-dir) chmod 0757 "$bad/share" ;;
	no-k3sm) rm "$bad/k3sm" ;;
	esac
	expect_refused "$case" --payload "$bad"
done
expect_refused "version-not-xyz" --version 1.2
expect_refused "version-injection" --version '1.2.3;id'

fx="$tmp/payload"
make_payload "$fx"
bash hack/build-app.sh --version 1.2.3 --payload "$fx" "$tmp/payload-out" > "$tmp/payload-build.log" 2>&1 \
	|| { echo "FAIL: build-app --payload"; cat "$tmp/payload-build.log"; exit 1; }
papp="$tmp/payload-out/k3sm.app"
[ "$(plutil -extract CFBundleShortVersionString raw "$papp/Contents/Info.plist")" = 1.2.3 ] \
	|| { echo "FAIL: CFBundleShortVersionString is not 1.2.3"; exit 1; }
[ "$(plutil -extract CFBundleVersion raw "$papp/Contents/Info.plist")" = 1.2.3 ] \
	|| { echo "FAIL: CFBundleVersion is not 1.2.3"; exit 1; }
diff -r "$fx" "$papp/Contents/Resources/payload" || { echo "FAIL: the payload copy differs from its source"; exit 1; }
want="$( (cd "$fx" && /usr/bin/shasum -a 256 k3sm share/notes.txt) )"
got="$(cat "$papp/Contents/Resources/payload.sha256")"
[ "$want" = "$got" ] || { echo "FAIL: payload manifest"; echo "want:"; echo "$want"; echo "got:"; echo "$got"; exit 1; }
codesign --verify --strict --deep "$papp" || { echo "FAIL: the payload bundle does not verify"; exit 1; }
echo "    ok (manifest, version stamp, signature)"

echo "==> hack/release/make-dmg.sh"
bash hack/release/make-dmg.sh "$papp" "$tmp/k3sm.dmg" > /dev/null
[ -s "$tmp/k3sm.dmg" ] || { echo "FAIL: no disk image"; exit 1; }
rm -f "$tmp/k3sm.dmg"
echo "    ok"

echo "==> hack/release/sign-and-notarize.sh refuses unattended runs"
# The app path does not exist, so even a broken refusal would stop at
# argument checking before any codesign call. Exit 3 is the refusal itself.
expect_sign_refusal() {
	local name="$1"; shift
	local status=0
	"$@" bash hack/release/sign-and-notarize.sh "$tmp/none.app" "$tmp/none.dmg" none ABCDE12345 \
		< /dev/null > "$tmp/sign.log" 2>&1 || status=$?
	[ "$status" = 3 ] || { echo "FAIL: $name: exit $status, want 3"; cat "$tmp/sign.log"; exit 1; }
	grep -q '^sign-and-notarize: refused' "$tmp/sign.log" || { echo "FAIL: $name: no refusal message"; exit 1; }
	! grep -q '^==> ' "$tmp/sign.log" || { echo "FAIL: $name: ran past the refusal"; exit 1; }
	echo "    refused: $name"
}
expect_sign_refusal "CLAUDECODE set" env CLAUDECODE=1
expect_sign_refusal "K3SM_AUTO set" env -u CLAUDECODE K3SM_AUTO=1
expect_sign_refusal "stdin not a terminal" env -u CLAUDECODE -u K3SM_AUTO

echo "==> license headers (.swift)"
header="hack/boilerplate/boilerplate.swift.txt"
n="$(wc -l < "$header" | tr -d ' ')"
missing=0
while IFS= read -r -d '' f; do
	start=1
	# Package.swift must keep the tools-version comment on line 1.
	if head -n 1 "$f" | grep -q '^// swift-tools-version'; then start=2; fi
	if ! tail -n "+$start" "$f" | head -n "$n" | cmp -s - "$header"; then
		echo "    missing header: $f"; missing=1
	fi
done < <(find . -name '*.swift' -not -path './.build/*' -not -path './.git/*' -print0)
[ "$missing" = 0 ] || { echo "FAIL: add the header in $header to the files above"; exit 1; }
echo "    ok"

echo "==> workflows dormant (.github/workflows)"
# A workflow file is dormant iff it has no line that is neither blank nor a
# comment. Every file counts, whatever its name or extension. Deliberately
# strict: a stray '---' or a byte-order mark makes a file active.
active=0
if [ -d .github/workflows ]; then
	while IFS= read -r -d '' f; do
		if grep -qEv '^[[:space:]]*(#|$)' "$f"; then
			echo "    ACTIVE: $f"; active=1
		fi
	done < <(find .github/workflows -type f -print0)
fi
[ "$active" = 0 ] || { echo "FAIL: workflows must stay fully commented out"; exit 1; }
# Red-path check, so the predicate above cannot pass vacuously.
printf '# off\non: push\n' > "$tmp/active.yml"
printf '# off\n\n  # still off\n' > "$tmp/dormant.yml"
grep -qEv '^[[:space:]]*(#|$)' "$tmp/active.yml" || { echo "FAIL: predicate missed an active file"; exit 1; }
! grep -qEv '^[[:space:]]*(#|$)' "$tmp/dormant.yml" || { echo "FAIL: predicate flagged a dormant file"; exit 1; }
echo "    ok"

echo "==> status fixtures (vendored from k3sm)"
# k3sm owns the status JSON contract and its golden fixtures. The copies under
# Tests/K3smStatusTests/Fixtures must match byte for byte. K3SM_DIR names a k3sm
# checkout; a sibling ../k3sm is used when present. A lone clone skips this.
k3sm_dir="${K3SM_DIR:-../k3sm}"
golden="$k3sm_dir/pkg/status/testdata"
if [ -d "$golden" ]; then
	drift=0
	for f in Tests/K3smStatusTests/Fixtures/status_*.json; do
		if ! cmp -s "$f" "$golden/$(basename "$f")"; then
			echo "    DRIFT: $f differs from $golden/$(basename "$f")"; drift=1
		fi
	done
	[ "$drift" = 0 ] || { echo "FAIL: re-copy the fixtures from $golden"; exit 1; }
	echo "    ok (against $golden)"
else
	echo "    skipped: no k3sm checkout at $k3sm_dir (set K3SM_DIR)"
fi

echo "==> dependency supply-chain (hack/verify-deps.sh)"
bash hack/verify-deps.sh --self-test
bash hack/verify-deps.sh

echo "app ci: green"
