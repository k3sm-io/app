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
| `StoppedBy` | R1 | the additive `stoppedBy` object (who stopped k3sm, why, when, which phase); a missing or malformed value decodes as nil and never fails the report |
| `NodeRole` | R4 | the closed two-case table from role to daemon label |
| `Reading`, `VisibilityTracker` | R6, R7 | classifies one CLI run; show after one running read, hide after two misses |
| `K3smCLI` | R4, R6 | the absolute CLI path, fixed argument lists, the built environment |
| `PollSchedule` | R6 | 5 s visible, 15 s hidden, 4 s kill deadline |
| `StatusDisplay` | R5 | flattens control characters, clips fields, caps rows |
| `SemanticVersion`, `PayloadRelation` | A8, A9 | semver precedence; payload newer, same or older than installed |

## K3smInstall

| piece | serves | what it does |
|---|---|---|
| `CopyOutPlan`, `CopyOutAction`, `UpdateRole` | A2, A8 | the staging root, the mktemp template `<version>.XXXXXXXX`, the lock and log paths, the user, the action; an update carries the role (a worker with its join target) |
| `ConsoleUser` | A8 | the app's own account, passed as `install --user` because `env -i` strips SUDO_USER; root and non-name strings refused |
| `TeamID`, `DesignatedRequirement` | A8, A15 | the Developer ID Application requirement built from a validated Team ID |
| `TeamIDPin`, `TeamIDStamp` | A8, A15 | the Team ID compiled into the binary, the only Team ID the app trusts; the committed stamp is empty (a developer build) and `build-app.sh --team-id` compiles a copy with the ID; never read from Info.plist |
| `RootScriptBuilder`, `RootScript`, `CLIArgument` | A8, A14, A15 | renders the root script: log, sweep, no-xattr copy, unsafe-entry refusal, chown, codesign verify, staged CLI, trap cleanup; every value shell-quoted. `arguments(for:)` is the one definition of the staged CLI's argv, pinned by golden tests |
| `AgentJoinTarget` | A9, A14 | resolves a worker's join server: the host of the status JSON `joinTarget`, or the `--server` of its installed `io.k3sm.agent` plist only when that field is absent, both through the strict `ServerAddress` grammar |
| `ShellQuote`, `AppleScriptText` | A14 | the two quoting functions every interpolation goes through |
| `CopyOutOutcome`, `CopyOutExit`, `OutcomeSummary` | A14, A15 | reads the log's final status line; names the script's own exit statuses; one sentence for the window |
| `ServerAddress` | A14 | strict ASCII host[:port] grammar; the CLI argument is the bare host |
| `UpdatePolicy` | A9 | worker always; server only when every worker in the status `workers` list is at or above the payload, naming the workers behind; with the list absent or a worker's version missing, server only after the user confirms; the datastore checks shown before a server update |
| `PrivilegedRunner`, `PrivilegedAvailability` | A5, A15, R8 | the one-method path to root; enables privileged actions only with a Team ID, a valid self-signature and an admin user |

## K3smApp

| file | serves | what it does |
|---|---|---|
| `AppDelegate` | A15 | wiring; login-item launch shows only the status item; reopen shows the window; activity assertion against App Nap; pauses polling off the active console session |
| `StatusPoller`, `CLIProcess` | R6 | serial probe runs with a SIGKILL deadline and a scrubbed environment |
| `StatusItemController` | R7 | inserts and removes the `NSStatusItem`; logs `status item: visible` only when on screen; respects a user removal |
| `MainWindowController`, `Views`, `AppModel` | A9, A15, A16 | SwiftUI in an `NSWindow`; first run (start or join), status with `stoppedBy`, Update (by `UpdatePolicy`) and Uninstall (with the purge checkbox); `.regular` while open, `.accessory` after; tails the copy-out log |
| `LoginItem` | A15 | `SMAppService.mainApp`, registered once per user from `/Applications`; `.requiresApproval` links to Login Items |
| `SelfCheck` | A15, R4, R8 | the compiled Team ID, `SecStaticCode` self-verification, admin check, the console user and the passwd-based CLI environment |
| `AppleScriptRunner` | A14 | the concrete `PrivilegedRunner`: `do shell script ... with administrator privileges` on its own thread, stdin through a 0600 FIFO; never run by tests or ci |

## hack/

| script | serves | what it does |
|---|---|---|
| `build-app.sh` | R10, A10 | arm64 release build, ad-hoc signed; `--payload` copies and checks a staged tree and writes `payload.sha256`; `--version` stamps Info.plist; `--team-id` compiles the Team ID pin from a source copy under `.build/pinned-src` |
| `release/make-dmg.sh` | A11 | the UDZO disk image with an `/Applications` symlink |
| `release/sign-and-notarize.sh` | A5, A11, A18 | attended Developer ID signing, notarization and stapling of the app and the image; refuses agent, loop and non-terminal runs, and an app not built with `--team-id` for its team |
| `acceptance/B458.sh` | | `swift test` (argv goldens, Team ID pin, update policy, `stoppedBy`), the developer and `--team-id` bundles built and verified with `codesign --verify --strict --deep` |
| `ci.sh` | | the gate: build, tests, bundle builds, shellcheck, payload and refusal checks, headers, workflow dormancy, fixture drift |

## The root step's command lines

`RootScriptBuilder.arguments(for:)` is pinned against `k3sm` `cmd/k3sm/install.go`:

| action | argv after the staged `k3sm` |
|---|---|
| start a cluster | `install --from-staging <dir> --user <user>` |
| join | `install --from-staging <dir> --user <user> --agent --server <host> --token-file <dir>/join-token` |
| update a server | `install --from-staging <dir> --user <user>` |
| update a worker | `install --from-staging <dir> --user <user> --agent --server <host>` |
| uninstall | `uninstall` |
| purge | `uninstall --purge --yes --user <user>` |

The copy-out holds `/Library/k3sm.staging.lock` (the outer lock) with
`lockf`; `k3sm install` takes `/Library/k3sm.lock` (the inner one) itself and
accepts the held outer lock once its staging-directory checks pass.

## Gaps in the k3sm contract

- `k3sm status -o json` reports a worker's version as its kubelet version,
  `v<kubernetes>+k3sm.<release>`. The app compares only the release after
  `+k3sm.`, never the Kubernetes version. The value is the node's own report
  and is advisory. A missing or unparseable version is unknown and never
  satisfies the minimum, and an absent `workers` field is unknown, not "no
  workers". An empty list means the server found no other nodes.
- A purge passes `--user` because the root step runs under `env -i` and the
  CLI would otherwise have no account whose kubeconfig to clean. A plain
  uninstall passes no flag.
- `joinTarget` is `host:port`. The app drops the port, because `install
  --agent` takes the host and adds the join port itself. A present but
  malformed `joinTarget` is refused and does not fall back to the plist.

## What the later builds fill in

The app build:

- the status item menu (actions, release notes, docs links), the k3sm template
  icon, and the full report on menu open;
- an explicit downgrade from the window, over `install --allow-downgrade`;
- the lab confirmation that a login-item launch is detected and that the
  status item's on-screen log line holds on each macOS version.

The release build (in k3sm and the release pipeline):

- the payload manifest format shared with `stage.sh` (A10), the signed payload
  tree, and the A19 fallback (manifest hash instead of a Team ID) if it is
  ever needed;
- the Homebrew cask (A16).
