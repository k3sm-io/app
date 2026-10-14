# Architecture

A one-page map of the source. The A-numbers are the binding resolutions of
the k3sm app plan (Amendment A); R-numbers are the earlier resolutions it
keeps; L-numbers are the resolutions of the k3sm lifecycle plan (stop, start
and restart, and the menu).

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
| `K3smCLI` | R4, R6 | the absolute CLI path, fixed argument lists (status, version, and the kubectl calls behind the console: pod list, logs, events, manifest), the built environment |
| `PollSchedule` | R6 | 5 s visible, 15 s hidden, 4 s kill deadline |
| `StatusDisplay` | R5 | flattens control characters, clips fields, caps rows |
| `SemanticVersion`, `PayloadRelation` | A8, A9 | semver precedence; payload newer, same or older than installed |
| `Workloads`, `Pod`, `PodHealth`, `WorkloadKind` | console | decodes `kubectl get pods -A -o json` (the API's `PodList` or kubectl's `List` of pods) into the rows a workloads view shows: how each pod runs, its health word and severity, owner, ports, requests |
| `LifecycleState` | L6, L9 | running, stopped, not installed or unreadable, from one report; an unknown verdict, state or role word never fails it |
| `StoppedNotice` | L6 | the login-time title, "k3sm is stopped (by you)" or "(auto on <network>)", only for a login launch with a recorded stop; unknown actor and phase words get the plain form |
| `K3smLogs` | L6 | the fixed log paths the menu opens: the node daemon's for the role, netd's, the copy-out log |
| `ResourceName`, `Quantity` | console | the only way a pod or namespace name reaches a kubectl command line (RFC 1123 subdomain, nothing else); cores and bytes from resource quantities |

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
| `LifecycleVerb`, `LifecycleScriptBuilder`, `LifecycleExit` | L9 | the closed verb set (stop, start, restart) and its separate root script: no staging and no lock; `env -i`, `cd /`; refuses unless `/Library/k3sm/k3sm` and every directory above it are root-owned, not group or other writable, not symlinks and carry no ACL, and the binary passes `codesign --verify -R` against the compiled Team ID; then runs the verb as a literal. `arguments(for:)` is the one definition of its argv |
| `LifecyclePrecondition`, `LifecycleConfirmation`, `StopWarning` | L5, L9 | a live state that differs from the one the user acted on refuses; the confirmation names the verb; Stop warns on a server with joined nodes, and when the `workers` list is unknown |
| `LifecycleDriver` | L6, L9 | one verb from click to outcome: live read, confirmation, a second live read, then a fresh administrator prompt |
| `LifecycleOutcome` | L1, L9 | one sentence per outcome; a partial stop's exit code names what was left behind |
| `InstalledCLITrust`, `LifecycleSupport`, `TrustedCLI` | L6, L9 | the app's own ownership, ACL and signature check of the installed CLI, made again immediately before every unprivileged run from the window, the lifecycle flow and the menu's Terminal actions (never a cached verdict); feature detection of `k3sm stop` by version, run only through that check |
| `BugReport`, `StatusCommand`, `CommandFile` | L6 | the static Terminal `.command` files behind Write a Bug Report and Open Status, written into a fresh 0700 directory; the collector reads an allowlist through a redaction pass |
| `PrivilegedRunner`, `PrivilegedAvailability` | A5, A15, R8 | the one-method path to root; enables privileged actions only with a Team ID, a valid self-signature and an admin user |

## K3smApp

| file | serves | what it does |
|---|---|---|
| `AppDelegate` | A15 | wiring; login-item launch shows only the status item; reopen shows the window; activity assertion against App Nap; pauses polling off the active console session |
| `StatusPoller`, `CLIProcess` | R6 | serial probe runs with a SIGKILL deadline and a scrubbed environment |
| `StatusItemController` | R7, L6 | inserts and removes the `NSStatusItem`; logs `status item: visible` only when on screen; respects a user removal; the menu: verdict, summary and status rows (the full report on open), Stop, Restart, Open Status, Open Logs, Write a Bug Report, Open k3sm, Quit |
| `MenuActions` | L6 | logs through `NSWorkspace` on fixed paths; the status and bug report `.command` files opened in Terminal; never a shell from the app |
| `StoppedNotifier` | L6 | the login-time stopped notification and its Start action |
| `MainWindowController`, `Views`, `AppModel` | A9, A15, A16, L6 | SwiftUI in an `NSWindow`; first run (start or join), status with `stoppedBy`, Stop, Restart and Start (or the note when the installed k3sm lacks them), Update (by `UpdatePolicy`) and Uninstall (with the purge checkbox); `.regular` while open, `.accessory` after; tails the copy-out log |
| `LoginItem` | A15 | `SMAppService.mainApp`, registered once per user from `/Applications`; `.requiresApproval` links to Login Items |
| `SelfCheck` | A15, R4, R8, L9 | the compiled Team ID, `SecStaticCode` self-verification, admin check, the console user, the passwd-based CLI environment, and `lstat` plus `SecStaticCode` of the installed CLI |
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

The lifecycle verbs run the installed CLI, never the app's copy, and take no
lock. `LifecycleScriptBuilder.arguments(for:)` is pinned against `k3sm`
`cmd/k3sm/lifecycle.go` and `main.go`:

| verb | argv after `/Library/k3sm/k3sm` |
|---|---|
| stop | `stop --actor user --reason 'from the k3sm app'` |
| start | `start --actor user --reason 'from the k3sm app'` |
| restart | `restart --actor user --reason 'from the k3sm app'` |

The lifecycle script's own refusals exit 100 (an unsafe path) and 101 (the
signature), above the CLI's codes (0 to 3, and 33 to 95 for a partial stop).

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

- The CLI has no machine-readable list of the verbs it supports. The app
  decides that `k3sm stop` exists by version: every release after 0.1.7 has
  it. A CLI that reports no version (an unstamped build) is treated as not
  having it.
- `stoppedBy` has no network field. For an automatic stop, the notification
  shows the stop's reason as the network.
- `k3sm stop` counts a server's joined workers itself but prints the count
  only as text. The app's Stop warning reads the `workers` list of a live
  `k3sm status -o json` instead, and warns when that list is absent.

## What the later builds fill in

The app build:

- the server's Copy Join Command menu item, release notes and docs links in
  the menu, and the k3sm template icon;
- an explicit downgrade from the window, over `install --allow-downgrade`;
- the lab confirmation that a login-item launch is detected and that the
  status item's on-screen log line holds on each macOS version.

The release build (in k3sm and the release pipeline):

- the payload manifest format shared with `stage.sh` (A10), the signed payload
  tree, and the A19 fallback (manifest hash instead of a Team ID) if it is
  ever needed;
- the Homebrew cask (A16).
