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
- Every `.swift` file starts with the Apache-2.0 header in `hack/boilerplate/boilerplate.swift.txt`
  (after the tools-version line in `Package.swift`); `ci.sh` checks it.

## Commits
Conventional Commits per `CONTRIBUTING.md`. Scopes are the target directories, lowercased
(`k3smstatus`, `k3smapp`, `k3sminstall`), or `hack` and `docs`. Sign off every commit
(`git commit -s`).
