# k3sm app

`k3sm.app` is the desktop front end for [k3sm](https://k3sm.io). It lives in
`/Applications`, installs k3sm on first run, shows a status item in the menu
bar while this Mac's k3sm node daemon is running, and opens a window for
everything else.

The source in this repository is private. The published app is free to use.

## Two ways to install k3sm

| channel | for | what you get |
|---|---|---|
| curl | headless Macs, scripted installs, SSH sessions | `curl -fsSL https://k3sm.io/install.sh \| sh` fetches a release tarball of signed, notarized binaries and runs `k3sm install` |
| app | desktop users | a notarized disk image holding `k3sm.app`, dragged to `/Applications`; a Homebrew cask that installs the same image will follow |

Both channels carry the same k3sm build at the same version and end in the
same installed layout: `/Library/k3sm`, the `io.k3sm.*` LaunchDaemons and the
`/usr/local/bin/k3sm` launcher. A Mac installed one way can be managed the
other way: the app on a curl-installed Mac shows status and offers updates,
and `sudo k3sm uninstall` in a terminal removes an app-installed cluster.

## How the app installs k3sm

The app bundle carries the k3sm build in `Contents/Resources/payload`. It never
runs that copy as root, because anything in `/Applications` can be rewritten
by an admin user. Instead, under one administrator authorization, a short root
script:

1. copies the whole app bundle into a fresh root-owned directory under
   `/Library/k3sm.staging`, dropping extended attributes and quarantine;
2. refuses the copy if it holds a symlink, a special file, a setuid or setgid
   file, or anything writable by group or others;
3. verifies the copy's signature against the k3sm Developer ID;
4. runs `k3sm install` from the verified copy, which installs into
   `/Library/k3sm`;
5. removes the staging directory however the run ends.

Its output goes to `/Library/Logs/k3sm/copy-out.log`, which the window shows
while the step runs. If the window closes, nothing is lost: the next launch
opens on the log of an unfinished or failed run.

## First run

With no `/Library/k3sm` on the Mac, the window asks one question:

- **Start a cluster on this Mac** installs a k3sm server.
- **Join a cluster** takes the server's address and a join token from
  `k3sm token create` on the server. The token is passed to the root step on
  stdin and written only to a root-owned file that is deleted when the step
  ends; it never appears in a command line. Tokens expire in minutes, so a
  failed join asks for a fresh one.

The app registers itself as a login item for each user on their first launch.
It appears under System Settings > General > Login Items, where it can be
turned off.

## Everyday use

- The **status item** appears in the menu bar while this Mac's node daemon is
  running and disappears when it stops. A quick restart does not make it
  flicker. If you remove it from the menu bar, the app leaves it removed until
  the next launch.
- The **window** opens whenever you open the app from `/Applications`,
  Spotlight or the Dock, even when k3sm is stopped, so there is always a way
  back in. A launch at login shows only the status item.

The app reads state only from `k3sm status -o json`, the machine interface the
k3sm CLI documents. It runs `/Library/k3sm/k3sm` by absolute path with an
environment it builds itself.

## Updating

When the app carries a newer k3sm than the one installed, it offers to update.
Updates follow the documented rollout order: worker Macs first, the
control-plane Mac last. On a worker the update is always available. On a server
with joined workers it is available only once every worker runs the new
version or later, and until then the app names the workers still to update.
An older build replaces a newer one only if you choose an explicit downgrade.

New versions of the app arrive as a new disk image (or, later, through
`brew upgrade --cask`). The app has no built-in downloader.

## Uninstalling

The window's uninstall action runs `k3sm uninstall` through the same verified
copy-out, with an option to also delete k3sm's data.

Dragging `k3sm.app` to the Trash removes only the app. k3sm keeps running,
because the cluster does not depend on its front end. To remove k3sm itself,
use the app's uninstall action before deleting the app, or run
`sudo k3sm uninstall` in a terminal.

## Build

Requires macOS 26 or later on Apple silicon and Swift 6. The package has no
third-party dependencies.

```sh
swift build
swift test
hack/build-app.sh out/                          # ad-hoc signed out/k3sm.app, no payload
hack/build-app.sh --version 0.2.0 \
    --payload <staged-tree> out/                # with a k3sm staged tree as its payload
hack/release/make-dmg.sh out/k3sm.app out/k3sm.dmg
hack/ci.sh                                      # the full gate
```

`hack/release/README.md` describes the release signing order. The bundle id
is `io.k3sm.app`, and the app logs to the unified log under the same
subsystem. With only the Command Line Tools installed, `swift test` may need
the swift-testing macro plugin path; `hack/ci.sh` adds it for you.

`docs/ARCHITECTURE.md` maps the source targets.

## Licensing

The source of this app is private. The k3sm CLI and runtime it installs are
Apache-2.0 and developed in the public k3sm repositories. The governance files
in this repository (`LICENSE`, `CONTRIBUTING.md` and the rest) are the shared
k3sm set, kept identical across the k3sm repositories.
