# k3sm app

The k3sm macOS app (SwiftPM package `K3smApp`): the menu bar status item, the window, and the
installer that puts k3sm on a Mac. It is a leaf. It reads state only from `k3sm status -o json`
(and the `k3sm status daemons -o json` probe), the machine interface the k3sm CLI documents, and
imports no code from the other k3sm repositories.

> User-facing behavior: `README.md`. Source map: `docs/ARCHITECTURE.md`. Release signing: `hack/release/README.md`.

## Targets
- **`K3smStatus`** (library, Foundation only): decodes the status JSON, decides visibility, builds
  the CLI argument lists and every display string. Tested without a GUI.
- **`K3smInstall`** (library, Foundation only): the root step as data and text (the copy-out and
  lifecycle scripts, their argv, quoting, the Team ID pin, update policy). Tested without a GUI.
- **`K3smApp`** (executable, AppKit and SwiftUI): wires both libraries to the screen and to root.

## Build / test
```sh
swift build
swift test
hack/build-app.sh out/                   # ad-hoc signed out/k3sm.app
K3SM_DIR=<k3sm checkout> hack/ci.sh      # the full gate
```
- `hack/ci.sh` is the gate. `K3SM_DIR` points at a k3sm checkout so the vendored status fixtures
  under `Tests/K3smStatusTests/Fixtures` are compared with k3sm's golden copies; a sibling
  `../k3sm` is used when it exists, and a lone clone skips that stage.
- A caller that already runs inside a sandbox sets `K3SM_SWIFTPM_DISABLE_SANDBOX=1`: SwiftPM's own
  sandbox cannot nest inside another, so `ci.sh` and `build-app.sh` then pass `--disable-sandbox`.
- With only the Command Line Tools, `swift test` needs the swift-testing macro plugin path;
  `hack/ci.sh` adds it.
- **No third-party dependencies, ever.** The package depends on nothing outside the toolchain.
  `hack/verify-deps.sh` (run by `ci.sh`) fails on any `.package(` not listed in `hack/deps.allow`
  with an exact revision, and the allow file is empty.

## Conventions
- **No SwiftUI macros and no `@State` in views.** The Command Line Tools toolchain has no SwiftUI
  macro plugin, so view state lives on `AppModel` as `@Published` properties. Decisions live in
  `K3smStatus` or `K3smInstall`, where they are unit-tested; views only render them.
- **Cluster-supplied strings are untrusted.** Every string from the CLI or the cluster passes
  `StatusDisplay.clip` (one line, fixed length) or `StatusDisplay.errorText` (error output) before
  it reaches the screen. Unknown status words are shown as printed and never fail a read.
- **The CLI runs by absolute path with an environment the app builds itself, never through a
  shell.** Argument lists are fixed in `K3smCLI` and pinned by its tests; a pod or namespace
  name reaches a command line only through `ResourceName`.
- **Privileged actions go only through the checked root step**: the copy-out script or the
  lifecycle script, each built by `K3smInstall`, every value shell-quoted, the installed CLI
  checked for ownership and signature first.
- **A needed status field is requested from the k3sm CLI, never guessed.** If the JSON lacks
  something, the app treats it as unknown and the field is added to k3sm's status contract.
- **Every control gets a help tag from the catalog.** The tooltip macOS shows after the pointer
  rests on a control is written only in `Sources/K3smStatus/Help.swift` (`Help.<area>.<name>`,
  each a `HelpTag` that records its control and visible label) and attached with
  `.help(Help.<area>.<name>)`, or an AppKit item's `toolTip = ....text`. The standard, after
  Apple's guidance for help tags (`docs/ARCHITECTURE.md` § Help tags is the public copy):
  - **What it says.** What the control does, or what a value means, in one short sentence of
    12 words or fewer. An action begins with its verb ("Delete the pod so its owner recreates
    it"); a value names its unit or where it comes from ("CPU used now, from metrics-server,
    against allocatable"). A keyboard shortcut follows in parentheses ("(Command-Option-I)").
  - **How it reads.** Sentence case, no closing period unless it is two sentences, never the
    visible label again, never the obvious, and never status or an error: those are the view's
    job. The only dynamic text a tag carries is a disabled control's reason and the whole of a
    line the view truncates, both built by catalog functions.
  - **Where it goes.** Every Button, Toggle, Picker, Menu, Stepper, slider and icon-only control
    (an icon-only one keeps its accessibility label too); every meter, bar, badge, dot or tile
    whose label does not say what it means; a column header whose unit is not shown. Plain text
    and a labelled text field get none. SwiftUI context-menu items, alert and dialog buttons show
    no help tag on macOS and are listed in `hack/help.allow` with the reason; AppKit menu items
    show theirs, so app-specific ones set `toolTip` (the system's About, Edit and Window items do not).
  - **How it is held.** `helpCatalogFollowsTheStandard` checks every catalog entry (length, case,
    closing punctuation, never its label); a new tag goes into its area's `all` list.
    `hack/verify-help.sh` (run by `ci.sh`) fails on a help string written outside the catalog and
    on a control with no `.help(` in its modifier chain, unless `hack/help.allow` names it with a reason.
- **`--background` is a launch contract with the k3sm CLI** (`LaunchPolicy.backgroundArgument`): the CLI
  passes it after install, join and start, and the app then takes a login launch's window policy.
- Every `.swift` file starts with the Apache-2.0 header in `hack/boilerplate/boilerplate.swift.txt`
  (after the tools-version line in `Package.swift`); `ci.sh` checks it.

## Commits
Conventional Commits per `CONTRIBUTING.md`. Scopes are the target directories, lowercased
(`k3smstatus`, `k3smapp`, `k3sminstall`), or `hack` and `docs`. Sign off every commit
(`git commit -s`).
