# Architecture

A one-page map of the source. The A-numbers are the binding resolutions of
the k3sm app plan (Amendment A); R-numbers are the earlier resolutions it
keeps.

```
K3smStatus   (library, Foundation only)   reads k3sm, decides visibility
K3smInstall  (library, Foundation only)   the root step as data and text
K3smApp      (executable, AppKit/SwiftUI) wires both to the screen and to root
hack/        build, release and gate scripts
```

`K3smInstall` depends on `K3smStatus`; `K3smApp` depends on both. Neither
library imports AppKit, so every decision is unit-tested without a GUI.

## K3smStatus

| piece | serves | what it does |
|---|---|---|
| `StatusReport`, `Verdict`, `StatusRow` | R1 | decodes `k3sm status -o json` and the `status daemons` probe (schemaVersion 1) |
| `NodeRole` | R4 | the closed two-case table from role to daemon label |
| `Reading`, `VisibilityTracker` | R6, R7 | classifies one CLI run; show after one running read, hide after two misses |
| `K3smCLI` | R4, R6 | the absolute CLI path, fixed argument lists, the built environment |
| `PollSchedule` | R6 | 5 s visible, 15 s hidden, 4 s kill deadline |
| `StatusDisplay` | R5 | flattens control characters, clips fields, caps rows |
| `SemanticVersion`, `PayloadRelation` | A8, A9 | semver precedence; payload newer, same or older than installed |

## K3smInstall

| piece | serves | what it does |
|---|---|---|
| `CopyOutPlan`, `CopyOutAction` | A2, A8 | the staging root, the mktemp template `<version>.XXXXXXXX`, the lock and log paths, the action |
| `TeamID`, `DesignatedRequirement` | A8, A15 | the Developer ID Application requirement built from a validated Team ID; `TeamID.infoPlistKey` |
| `RootScriptBuilder`, `RootScript` | A8, A14, A15 | renders the root script: log, sweep, no-xattr copy, unsafe-entry refusal, chown, codesign verify, staged CLI, trap cleanup; every value shell-quoted |
| `ShellQuote`, `AppleScriptText` | A14 | the two quoting functions every interpolation goes through |
| `CopyOutOutcome`, `CopyOutExit`, `OutcomeSummary` | A14, A15 | reads the log's final status line; names the script's own exit statuses; one sentence for the window |
| `ServerAddress` | A14 | strict ASCII host[:port] grammar; the CLI argument is the bare host |
| `UpdatePolicy` | A9 | worker always; server only when every worker is at or above the payload; names the workers behind |
| `PrivilegedRunner`, `PrivilegedAvailability` | A5, A15, R8 | the one-method path to root; enables privileged actions only with a Team ID, a valid self-signature and an admin user |

## K3smApp

| file | serves | what it does |
|---|---|---|
| `AppDelegate` | A15 | wiring; login-item launch shows only the status item; reopen shows the window; activity assertion against App Nap; pauses polling off the active console session |
| `StatusPoller`, `CLIProcess` | R6 | serial probe runs with a SIGKILL deadline and a scrubbed environment |
| `StatusItemController` | R7 | inserts and removes the `NSStatusItem`; logs `status item: visible` only when on screen; respects a user removal |
| `MainWindowController`, `Views`, `AppModel` | A15, A16 | SwiftUI in an `NSWindow`; first run (start or join) and status; `.regular` while open, `.accessory` after; tails the copy-out log |
| `LoginItem` | A15 | `SMAppService.mainApp`, registered once per user from `/Applications`; `.requiresApproval` links to Login Items |
| `SelfCheck` | A15, R4, R8 | stamped Team ID, `SecStaticCode` self-verification, admin check, the passwd-based CLI environment |
| `AppleScriptRunner` | A14 | the concrete `PrivilegedRunner`: `do shell script ... with administrator privileges` on its own thread, stdin through a 0600 FIFO; never run by tests or ci |

## hack/

| script | serves | what it does |
|---|---|---|
| `build-app.sh` | R10, A10 | arm64 release build, ad-hoc signed; `--payload` copies and checks a staged tree and writes `payload.sha256`; `--version` stamps Info.plist |
| `release/make-dmg.sh` | A11 | the UDZO disk image with an `/Applications` symlink |
| `release/sign-and-notarize.sh` | A5, A11, A18 | attended Developer ID signing, notarization and stapling of the app and the image; refuses agent, loop and non-terminal runs |
| `ci.sh` | | the gate: build, tests, bundle builds, shellcheck, payload and refusal checks, headers, workflow dormancy, fixture drift |

## What the later builds fill in

The app build:

- the status item menu (actions, release notes, docs links), the k3sm template
  icon, and the full report on menu open;
- Update and Uninstall in the window, driven by `UpdatePolicy` and
  `CopyOutAction.update` and `.uninstall`, with the server datastore checks
  shown before a server update (A9);
- worker versions for `UpdatePolicy`, which today's status JSON does not
  carry, from a field the k3sm status contract adds;
- the lab confirmation that a login-item launch is detected and that the
  status item's on-screen log line holds on each macOS version.

The release build (in k3sm and the release pipeline):

- `k3sm install --from-staging <dir>` and `--token-file` in the copy-out, and
  the shared lock A8 asks for: `k3sm install` takes its own flock on
  `/Library/k3sm.lock`, so the copy-out cannot hold that same lock across the
  install it runs and uses `/Library/k3sm.staging.lock` until `--from-staging`
  can inherit it;
- a resolution of the staging path: `k3sm install` already uses
  `/Library/k3sm.staging` as the sibling directory it builds the new install
  root in and swaps into place, which collides with A8's copy-out root of the
  same name;
- the payload manifest format shared with `stage.sh` (A10), the signed payload
  tree, and the A19 fallback (manifest hash instead of a Team ID) if it is
  ever needed;
- the Homebrew cask (A16).
