#!/usr/bin/env bash
# Copyright The k3sm Authors.
# SPDX-License-Identifier: Apache-2.0
#
# B553.sh -- the gate for the "Allow connections from other devices" setting
# in the menu and the window, over `k3sm network lan on|off`.
#
#   1. swift test, and the suites and tests this build owns must have run and
#      passed: the decoder of the status report's network field (absent is
#      on with nothing recorded, an unrecognized value is unknown, never off,
#      a role with no switch has none), the two LAN verbs on the closed root
#      path (constant argv, the same checks, the refusals run for real, and
#      the cross-check of the verbs and status fields against the k3sm CLI
#      source, required, never skipped), the tri-state checkbox, the
#      confirmation before turning access on, and the driver (re-read, no
#      optimistic toggle, the CLI's error text cleaned and truncated)
#   2. the LAN verbs' argv are compile-time constants, and no second root
#      script exists
#   3. the LAN fixture is the app's own, not a vendored k3sm golden
#   4. the window's Network settings pane shows the checkbox with its
#      subtitle and an unknown state, and flips it only through
#      AppModel.performLAN; the pane, the menu and the window never reach
#      the root path themselves
#
# K3SM_DIR names the k3sm checkout whose cmd/k3sm, pkg/install and pkg/status
# the verbs and fields are checked against (default: the sibling ../k3sm).
# The gate fails when it cannot be found. Runs under macOS /bin/bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"
# shellcheck source=hack/acceptance/lib/test-passed.sh
. hack/acceptance/lib/test-passed.sh

K3SM_DIR="${K3SM_DIR:-../k3sm}"
for f in cmd/k3sm/main.go cmd/k3sm/lifecycle.go cmd/k3sm/network.go pkg/install/networklan.go pkg/status/network.go pkg/status/report.go; do
	if [ ! -f "$K3SM_DIR/$f" ]; then
		echo "FAIL: no k3sm CLI source at $K3SM_DIR/$f; set K3SM_DIR to a k3sm checkout"
		exit 1
	fi
done
K3SM_DIR="$(cd "$K3SM_DIR" && pwd)"
export K3SM_DIR

# The Command Line Tools keep the swift-testing macro plugin where SwiftPM
# does not look; ci.sh does the same.
# K3SM_SWIFTPM_DISABLE_SANDBOX=1 adds --disable-sandbox, for a caller already
# inside a sandbox: SwiftPM's own sandbox cannot nest inside another one.
SWIFT_FLAGS=()
if [ "${K3SM_SWIFTPM_DISABLE_SANDBOX:-}" = 1 ]; then
	SWIFT_FLAGS=(--disable-sandbox)
fi
TEST_FLAGS=()
devdir="$(xcode-select -p 2>/dev/null || true)"
plugdir="$devdir/usr/lib/swift/host/plugins/testing"
if [ -n "$devdir" ] && [ -f "$plugdir/libTestingMacros.dylib" ]; then
	TEST_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$plugdir")
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> swift test"
# One run of the suite: the stream hack/ci.sh hands every gate, or a run
# here when this gate runs on its own.
app_test_results "$tmp" || exit 1

for suite in \
	"LAN access decoder" \
	"LAN root script" \
	"LAN checkbox" \
	"LAN confirmation" \
	"LAN driver" \
	"lifecycle root script" \
	"lifecycle driver"; do
	suite_passed "$tmp/results.tsv" "$suite" || { echo "FAIL: suite \"$suite\" did not run and pass"; exit 1; }
	echo "    passed: $suite"
done

for name in \
	"an absent network field reads as on with no setting recorded" \
	"an unrecognized value is unknown, never off" \
	"a role with no switch has none" \
	"a refused change and its applied state decode from the app's fixture" \
	"the CLI's error text is stripped of control characters and truncated" \
	"the verb set is closed: stop, start, restart, LAN on, LAN off, update apply, cancel and abort" \
	"the LAN verbs' argv are the constants network lan on and off" \
	"each LAN prompt says allow or stop allowing connections from other devices" \
	"the LAN scripts run the stop script's checks under env -i" \
	"a LAN script's refusals stop before the CLI runs" \
	"the lifecycle driver and precondition refuse a LAN verb" \
	"every LAN verb and status field the app uses is one the CLI declares" \
	"the checkbox is tri-state: on, off, unknown" \
	"a failed, stale or untrusted read disables it with the reason and drives nothing" \
	"a role with no switch hides it" \
	"an absent field shows on, not recorded, with the indicator" \
	"the indicator shows only while LAN access is on" \
	"a recorded value the daemon does not serve, and a refused change, are noted" \
	"turning on names what becomes reachable and what the switch does not cover" \
	"an unknown alwaysOn is said, never guessed" \
	"an unknown covers or alwaysOn word is shown without control or format characters" \
	"a long covers or alwaysOn list is capped" \
	"a covers or alwaysOn change between the question and the prompt refuses" \
	"answering no is the default only for turning on and for aborting an update" \
	"on: live read, confirm, re-read, the lan-on script, then a confirming read" \
	"off runs without a question" \
	"a declined question runs nothing" \
	"a changed, unknown, unreadable or switchless status refuses before the prompt" \
	"the result shows the confirmed value, not the requested one" \
	"the CLI's error text is shown with control characters stripped and truncated" \
	"the verb set is closed: stop, start, restart" \
	"every lifecycle verb and flag passed is one the CLI declares"; do
	if ! test_passed "$tmp/results.tsv" "$name"; then
		echo "FAIL: test \"$name\" did not run and pass (CLI source: $K3SM_DIR)"
		exit 1
	fi
	echo "    passed: $name"
done

echo "==> the LAN verbs' argv are constants on the one root path"
lc="Sources/K3smInstall/Lifecycle.swift"
grep -qF 'case .lanOn: return ["network", "lan", "on"]' "$lc" || { echo "FAIL: $lc lost the constant lan-on argv"; exit 1; }
grep -qF 'case .lanOff: return ["network", "lan", "off"]' "$lc" || { echo "FAIL: $lc lost the constant lan-off argv"; exit 1; }
# The root scripts are the copy-out, the lifecycle script (which the LAN verbs
# use) and the join token mint, each built in one place; the LAN feature adds
# none of its own.
got="$(grep -rc 'RootScript(text:' Sources | grep -v ':0$' | sort | tr '\n' ' ')"
want="Sources/K3smInstall/JoinTokenMint.swift:1 Sources/K3smInstall/Lifecycle.swift:1 Sources/K3smInstall/RootScript.swift:1 "
[ "$got" = "$want" ] || { echo "FAIL: RootScript constructions in Sources are '$got'; want '$want' (the copy-out, the lifecycle script and the join token mint)"; exit 1; }
grep -qE 'LifecycleScriptBuilder\.render\([A-Za-z]+, teamID: teamID\)' Sources/K3smInstall/LANAccess.swift \
	|| { echo "FAIL: the LAN driver does not run the lifecycle script"; exit 1; }
echo "    ok"

echo "==> the LAN fixture is the app's own"
fx="Tests/K3smStatusTests/Fixtures/lan-access-refused.json"
[ -f "$fx" ] || { echo "FAIL: $fx is missing"; exit 1; }
[ ! -e "$K3SM_DIR/pkg/status/testdata/$(basename "$fx")" ] \
	|| { echo "FAIL: $(basename "$fx") shadows a k3sm golden; it must be the app's own"; exit 1; }
grep -q '"network"' "$fx" || { echo "FAIL: $fx carries no network field"; exit 1; }
echo "    ok"

echo "==> the Network settings pane shows the checkbox and flips it through the model"
# The status item's menu holds actions only, and the window keeps the setting
# in its Network settings pane (LANSection); none of them reaches root itself.
pane="Sources/K3smApp/NetworkPane.swift"
grep -q 'LANToggle.title' "$pane" || { echo "FAIL: $pane does not show the checkbox"; exit 1; }
grep -q 'LANToggle.subtitle' "$pane" || { echo "FAIL: $pane does not show the subtitle"; exit 1; }
grep -q 'model.performLAN(' "$pane" || { echo "FAIL: $pane does not flip through AppModel.performLAN"; exit 1; }
grep -q 'toggle.value == .unknown' "$pane" || { echo "FAIL: the checkbox has no unknown state"; exit 1; }
for f in "$pane" Sources/K3smApp/StatusItemController.swift Sources/K3smApp/Views.swift; do
	if grep -nE 'runAsRoot|LifecycleScriptBuilder|LANDriver\(' "$f"; then
		echo "FAIL: $f reaches the root path directly"; exit 1
	fi
done
echo "    ok"

echo "B553: green"
