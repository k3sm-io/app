# k3sm app

`k3sm.app` is the desktop front end for [k3sm](https://k3sm.io). It lives in
`/Applications`, installs k3sm on first run, shows a status item in the menu
bar while this Mac's k3sm node daemon is running, and opens a window for
everything else.

The source in this repository is public under the Apache-2.0 licence in
`LICENSE`. The released app is signed and notarized by the k3sm maintainers
and is free to use.

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
4. runs `k3sm install --from-staging` from the verified copy, which installs
   into `/Library/k3sm` and writes the admin kubeconfig to the account running
   the app;
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

After the administrator prompt, the window streams the step's log as it runs
and, when the step ends, switches to the status of the new install.

Installing, updating and uninstalling need an administrator account and a
release build of the app. A build from source pins no Developer ID team, so
it shows status but keeps these actions disabled and says why.

The app registers itself as a login item for each user on their first launch.
It appears under System Settings > General > Login Items, where it can be
turned off.

## Everyday use

- The **status item** appears in the menu bar while this Mac's node daemon is
  running and disappears when it stops. It is the butterfly mark, with a
  triangle badge when k3sm is degraded and a dot when connections from other
  devices are allowed. A quick restart does not make it flicker. If you remove
  it from the menu bar, the app leaves it removed until the next launch.
- The **window** opens whenever you open the app from `/Applications`,
  Spotlight or the Dock, even when k3sm is stopped, so there is always a way
  back in. A launch at login shows only the status item. The left panel is
  headed by what this Mac is part of ("This Mac is the cluster", "Cluster"
  with the number of Macs first in its stats, or "Joined a cluster" on a
  worker). When the cluster has more than one node, a switch at the top of the
  panel picks between two views: **Cluster** shows nodes ready, running pods,
  the cores and memory pods request of what the nodes offer, and each node
  with its role, readiness and its own requests; **This Mac** shows this Mac's
  cores, memory and data root and the cluster's nodes with their roles. When
  every node runs the same k3sm release, both views name it once ("k3sm
  0.1.7"); otherwise each node shows its own version and the panel says
  "versions differ", or "versions: some unknown" when a node's version cannot
  be read. The app remembers the choice; a single-node cluster always shows
  This Mac. The panel scrolls in a short window. While the window is open the
  node list and the selected tab's list are re-read every 5 seconds (every 15
  seconds on Images, and on Builds once the build engine is ready) and the
  status report is re-read every 30 seconds, so the panel follows nodes as
  they join and leave. The pod list keeps being read every 30 seconds while
  another tab is selected, so the panel's pod figures stay current; the panel
  shows their age beside its state when that read is late. No other tab is
  read while it is not selected; when you come back to it, it shows what it
  last read and how long ago.
- The **tabs** above the list are Workloads (every pod, with the Mac it runs
  on), Images (the images the nodes report holding, one row per digest; until
  a node reports them the tab says so) and Builds (the build engine's state).
  The app remembers the tab, and each tab's search and selection.
- The **details button**, beside the info button above the pod list, collapses
  the pod details on the right (logs, events and manifest) and shows them
  again; Command-Option-I does the same, and the app remembers the choice.
- The **left panel** is resizable: drag the divider between it and the list.
  It goes no narrower than its original width and no wider than its content
  can use (every tile in one row, or the longest node row with its meters
  beside it). Wider, the tiles take one row and each node's meters move up
  beside its name, so node names stop being shortened. Double-click the
  divider, or choose View > Hide Panel (Command-Option-L), to collapse the
  panel; do it again, or View > Show Panel, to bring it back. The window's
  minimum width follows: the panel's minimum plus the list's, or the list's
  alone while the panel is hidden. The app remembers the width and whether
  the panel is hidden.

The app reads state only from `k3sm status -o json`, the machine interface the
k3sm CLI documents. It runs `/Library/k3sm/k3sm` by absolute path with an
environment it builds itself. A newer CLI may print status words this app does
not know; they are shown as printed and never stop the app from reading the
rest.

## The menu

The status item's menu opens with two status lines, **Cluster** and **This
Mac**, each with a coloured circle and a word: ok (green), degraded (amber),
down (red) or unknown (grey). This Mac follows k3sm's verdict on this Mac.
Cluster reads the nodes-ready count: ok when every node is ready, degraded
when some are, down when none is or the API server cannot be reached. Both
come from the full status read each time the menu opens, and This Mac also
follows the regular probe. The full status and the setting for connections
from other devices are in the window. Then come the actions:

- **Stop k3sm** stops k3sm on this Mac completely, pods included, and keeps it
  stopped across restarts until you start it (`sudo k3sm stop`). Before it
  asks, the app reads the status again. On a server with joined nodes it names
  them and warns that stopping halts the cluster's control plane for them. When
  it cannot tell whether any node has joined, it says so and warns anyway.
- **Restart k3sm** restarts the k3sm daemons; pods keep running.

  Stop and Restart appear only on a release build of the app with a k3sm that
  supports them (see below); otherwise the menu does not show them.
- **Open Status in Terminal** runs `k3sm status` in a Terminal window.
- **Open Logs** opens the node daemon's and netd's logs in Console.
- **Write a Bug Report** opens a Terminal window that collects the k3sm and
  macOS versions, the status JSON, the daemons' launchd state and the tail of
  each k3sm log into one file, with tokens, keys and passwords redacted, and
  opens that file for you to read. Nothing is uploaded, and it reads no
  kubeconfig, token, Secret, environment or pod manifest. Share the file
  yourself if you want to.
- **Dashboard** and **Quit k3sm**.

After a stop the status item disappears, because k3sm is no longer running.
At your next login the app posts a notification, "k3sm is stopped (by you)",
with a **Start** button. **Start k3sm** is also in the window whenever k3sm is
stopped.

Stop, Start and Restart each ask first, naming the action, and then show the
standard administrator prompt, every time. If the status changed since you
chose the action (k3sm stopped or started in the meantime), nothing is run.
The root step runs only `/Library/k3sm/k3sm stop`, `start` or `restart`, and
only after checking that the binary and every folder above it are owned by
root, not writable by anyone else, not symlinks and free of ACLs, and that
the binary is signed by the k3sm Developer ID. It never uses the app's own copy of k3sm.

Before Start runs, the app asks the installed k3sm how long a start may take
(`k3sm start --print-time-bound`) and waits that long plus 30 seconds. A k3sm
that cannot say gets 10 minutes, and the app logs why. A start can bring the
daemons up while the node is still cordoned, so the cluster schedules nothing
on it yet. The window then shows "k3sm started, node not schedulable yet;
retrying." and the app runs the start once more by itself. If the node is
still cordoned after that, the window says so and leaves the rest to you:
`sudo k3sm start` in Terminal finishes it. Any other failure is shown as a
failed start, with no second try.

These actions need a k3sm release that has `k3sm stop` (any release after
0.1.7). With an older k3sm, or one that fails those checks, the menu does not
show them and the window says why; `sudo k3sm stop` and `sudo k3sm start` work
in Terminal either way. Like installing, they need an administrator account
and a release build of the app.

## Connections from other devices

The window carries a checkbox, **Allow connections from other
devices**, with the note "Off: only this Mac and your cluster mesh". It is the
setting `k3sm network lan` records: with it on, the NodePort, LoadBalancer and
(on a server) ingress listeners of your workloads answer on every network
this Mac is on, so any device there can reach them. With it off they answer
only on this Mac and over the cluster mesh. While it is on, the status item's
icon carries a small dot.

The checkbox shows the recorded setting from the newest status read, and has
three states: on, off and unknown. The status item's regular probe (`k3sm
status daemons -o json`) carries the setting, so the checkbox and the dot
follow a change made in Terminal within a few seconds. The full report the
window reads adds what the node daemon serves. It cannot be clicked
when the status could not be read, when that read is out of date, when the
installed k3sm failed the app's trust checks, or when k3sm reports a value the
app does not know; the reason is shown under it. A k3sm from before this
setting existed reports none, and serves every network, so the checkbox
shows on with a note that nothing is recorded. If the saved setting cannot be
used, k3sm serves it as off, and the checkbox shows off with a note that names
`sudo k3sm network lan on` or `off` to set it again. When k3sm says the daemon
still serves a different value, or that its last change was refused, the
window says so; when only an administrator can read what the
daemon serves, the note points to `sudo k3sm network lan status`. A Mac with no server or worker installed shows
no checkbox.

Turning it on first asks, naming what becomes reachable and what the setting
does not change (the API server, the worker join port and the mesh port, as
k3sm reports them); Cancel is the default. Turning it off asks nothing. Either
way the app then reads the status again, shows the standard administrator
prompt, and runs `/Library/k3sm/k3sm network lan on` or `off` through the same
checked root step as Stop and Start. The checkbox changes only when the status
read after the change confirms it. If the change fails, the window shows
k3sm's own message, cleaned of control characters and shortened.

In Terminal the same setting is `sudo k3sm network lan on`, `off` and
`k3sm network lan status`.

## Updating

When the app carries a newer k3sm than the one installed, the window offers
**Update k3sm**. Updates follow the documented rollout order: worker Macs
first, the control-plane Mac last.

- On a worker the update is always available. The window names the
  control-plane Mac the worker joins, and the update keeps it joined there.
  The control-plane address comes from `joinTarget` in `k3sm status -o json`
  (the host only; the CLI adds the join port). A CLI that does not report it
  falls back to the worker's installed LaunchDaemon. Either way the address
  must pass the same strict check as one typed into the join form.
- On the control-plane Mac the window first lists the checks to make before
  updating (take a snapshot with `sudo k3sm snapshot save`, leave free space
  for the datastore migration, and note that a datastore engine change is one
  way). The app reads the workers and their versions from the `workers` list
  in `k3sm status -o json`. The update is offered once every worker reports
  a k3sm version at or above the new one. While any worker is behind, the
  window names the workers to update first and offers nothing. When the list
  is missing, or a worker reports no version, the app cannot vouch for it: the
  update waits until you confirm that every worker already runs the new
  version.

The app does not downgrade. When it carries an older k3sm than the one
installed, or the installed version cannot be read, it offers no update; a
downgrade runs in a terminal.

New versions of the app arrive as a new disk image (or, later, through
`brew upgrade --cask`). The app has no built-in downloader.

## Uninstalling

The window's **Uninstall k3sm** action asks for confirmation, then runs
`k3sm uninstall` through the same verified copy-out. It stops k3sm and removes
it, and keeps the cluster's data.

Tick **Also delete k3sm's data** to remove the cluster's data as well. The
confirmation names the choice, and the root step runs
`k3sm uninstall --purge --yes --user <your account>`. The account name tells
the CLI whose `~/.kube/config` to clean, since the administrator prompt does
not pass sudo's environment. The same command works in a terminal:

```sh
sudo k3sm uninstall --purge --yes
```

Dragging `k3sm.app` to the Trash removes only the app. k3sm keeps running,
because the cluster does not depend on its front end. To remove k3sm itself,
use the app's uninstall action before deleting the app, or run
`sudo k3sm uninstall` in a terminal.

## Build

Requires macOS 26 or later on Apple silicon and Swift 6. The package has no
third-party dependencies.

The app icon, `Resources/AppIcon.icns`, is generated from the k3sm butterfly
mark in `Resources/k3sm-mark.svg` by `hack/make-icon.sh`; rerun it after the
mark changes and commit the result.
Candidate icons with a tile of their own are in `docs/icon-concepts/`,
rendered by `hack/icon-concepts.sh`.

```sh
swift build
swift test
hack/build-app.sh out/                          # ad-hoc signed out/k3sm.app, no payload
hack/build-app.sh --team-id <ID> out/           # compiles the Developer ID Team ID the app pins
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

The source of this app is Apache-2.0, like the k3sm CLI and runtime it
installs, which are developed in the other public k3sm repositories. The
governance files in this repository (`LICENSE`, `CONTRIBUTING.md` and the
rest) are the shared k3sm set, kept identical across the k3sm repositories.
