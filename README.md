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
| curl | headless Macs, scripted installs, SSH sessions | `curl -fsSL https://k3sm.io/install.sh \| sh` fetches a release tarball of Developer ID signed and notarized programs and runs `k3sm install` |
| app | desktop users | a notarized disk image holding `k3sm.app`, dragged to `/Applications`; Developer ID signed, downloaded from the GitHub release page; it does not update itself, so a new version is a new disk image |

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

Each time the window opens, and on the console's report loop, the app checks
k3sm on this Mac: whether `/Library/k3sm` and its command exist, whether the
command passes the app's trust check, what `k3sm status` reports, and whether
the installed release matches the one the app carries. The result is one of
not installed, stopped, partly running (netd or the node daemon down while the
other runs), command missing, command not trusted, status unreadable, version
mismatch (behind or ahead of the app) or healthy. The window is always the
console, with its left panel. Only "not installed" puts the first run in the
console's content pane, where the tabs go, with the tab strip hidden and the
left panel reading "Not installed"; every other state shows the tabs, and the
console's status names the state in one line.

While the state is not healthy, a banner across the top of the console says it
in one sentence, with a button that names the next step. The button opens a
guided panel: a short numbered list of steps and one button that runs the
step the app already has, through the same confirmation and administrator
prompt as the menu:

| state | the panel's step |
|---|---|
| stopped | Start k3sm |
| partly running | Restart k3sm while the node daemon runs (netd is down); Start k3sm while the node daemon is down; Repair k3sm beside either |
| behind the app | Update k3sm, which runs the one update plan (see [Updating](#updating)) |
| ahead of the app | none: the app never installs an older k3sm over a newer one, and the panel says where to get the matching app |
| command missing or not trusted | Repair k3sm (see Repairing below) |
| status unreadable | Refresh, and Open Logs |

While the step runs, the panel shows its progress, and it ends on a plain
"Done" or "Failed" line with the step's own message. A build that is not
Developer ID signed cannot run the administrator step, so its panel shows the
exact Terminal command instead (`sudo k3sm start`, `sudo k3sm restart`, or the
install for an update or a repair: the k3sm the app carries when it has one,
else the install script pinned to the app's release), with Copy Command and
Open Terminal, and no Repair button. For an install on a Mac known to run the
control plane, **Run in Terminal** replaces Open Terminal and runs that
install in a new Terminal window, where `sudo` asks for your password. A
worker, or a Mac whose role the app cannot read, keeps the command to read,
since a plain install there could start a second cluster.

With nothing installed on the Mac, the console's content pane walks through a
short guided first run, one step at a time, with the steps listed across its top:

1. **Choose**: start a cluster on this Mac (it installs a k3sm server), or
   join a cluster another Mac runs (this Mac installs as a worker).
2. **Join details** (join only): one field takes the server's address and the
   token from `sudo k3sm token create` (paste them into this field, not
   Terminal); a pasted `--server <address> --token <token>` line is read too.
   The app reads the address and token out of it: extra spaces, line
   breaks, quotes, `\` line continuations and a URL such as
   `https://server.example.com:9345/` are fine, and anything a shell would act on
   (`;`, `|`, `&`, `$`, backquotes, redirections) is refused. Nothing in the
   paste is ever run. The field is a secure field, the token is never shown or
   logged, and the window shows only the server and "Token: received".
3. **Review**: what will happen, then one administrator prompt. The token is
   passed to the root step on stdin and written only to a root-owned file
   that is deleted when the step ends; it never appears in a command line.
4. **Install**: the install runs through the same checked root step as
   before, and each phase is named as it starts (authenticate, clear old
   staging files, copy k3sm out of the app, check its signature, install and
   start or join), with the step's log beneath.
5. **Done**: the content pane shows the tabs for the new install, in the same
   window, and the left panel fills with its figures. If the install failed, the
   window says so plainly, with the app's reason, the command's own last
   message and the log, and **Try Again** goes back to the review (for a join,
   to the join step, since tokens expire in minutes and a fresh one is needed).

Installing, updating and uninstalling need an administrator account and a
release build of the app. A build from source pins no Developer ID team, so
it shows status but keeps these actions disabled and says why. Its first run
ends at the review, which shows the exact Terminal commands for the chosen
path with Copy Command and **Install in Terminal**. Install in Terminal writes
those commands to a script in a private folder and opens it in a new Terminal
window, where `sudo` asks for your password; the app itself runs nothing as
root. When the app carries a k3sm, that k3sm is installed (`sudo <app>/Contents/Resources/payload/k3sm install`);
otherwise the install script is downloaded and run (`curl -fsSL https://k3sm.io/install.sh | sh`,
pinned to the app's release, unpinned for a development build), and a failed
download stops the script. For a join, Terminal asks for the join token with
echo off and pipes it to a single `sudo` step that writes it to a root-only
file, runs `k3sm install --agent --server <address> --token-file <path>` and
removes the file however that step ends; the token is never in the script or
a command line. The script's private folder, with anything it downloaded, is
removed when it ends. While the window waits, a small butterfly flies a dotted
path under the buttons and checks for k3sm each time it reaches the right end,
every 5 seconds (Check Again checks at once; with Reduce Motion it stands
still at the end). Once a check finds k3sm up, the content pane flips to the
tabs and the left panel fills with the cluster's figures, in place: the window
is not replaced.

The app registers itself as a login item for each user on their first launch.
It appears under System Settings > General > Login Items, and **Open k3sm at
login** in the app's Settings turns it off or on again (see
[Settings](#settings)).

## Everyday use

- The **status item** appears in the menu bar while this Mac's node daemon is
  running and disappears when it stops. It is the butterfly mark, with a
  triangle badge when k3sm is degraded and a dot when connections from other
  devices are allowed. A quick restart does not make it flicker. If you remove
  it from the menu bar, the app leaves it removed until the next launch.
- The **window** opens whenever you open the app from `/Applications`,
  Spotlight or the Dock, even when k3sm is stopped, so there is always a way
  back in. A launch at login shows only the status item, unless Settings asks
  for the window at login too. The left panel is
  headed by what this Mac is part of ("This Mac is the cluster", "Cluster"
  with the number of Macs first in its stats, or "Joined a cluster" on a
  worker). When the cluster has more than one node, a switch at the top of the
  panel picks between two views: **Cluster** shows nodes ready, running pods,
  the cores and memory pods request of what the nodes offer, and each node
  with its role, readiness and its own requests; **This Mac** shows this Mac's
  cores, memory and data root and the cluster's nodes with their roles. Its
  tiles, core grid and unified memory meter show what is used: the cores the
  node used and the pods' memory, each of what the Mac has ("3.20 of 8
  cores", "5.1 GB of 16 GB"), the meter's dim part being what macOS and other
  apps use. Without a usage sample a tile shows no figure and the charts say
  so; use is never shown as zero for want of a sample. When
  every node runs the same k3sm release, both views name it once ("k3sm
  0.1.7"); otherwise each node shows its own version and the panel says
  "versions differ", or "versions: some unknown" when a node's version cannot
  be read. The app remembers the choice; a single-node cluster always shows
  This Mac. The panel scrolls in a short window. While the window is open the
  pods and the nodes are followed live: the app holds one `k3sm kubectl get
  -w` per kind and shows each change as it comes, re-reading the whole list
  about every 5 minutes. Only those two kinds are watched, so the app holds
  at most two watches at once, whatever tab is shown. If a watch cannot be
  held the app reads that list on a timer instead, retrying the watch after
  a growing, randomized wait of at most a minute; if the cluster refuses
  the admin kubeconfig in the watch, the tab says so, and the watch waits
  until the window opens again. The selected tab's list is re-read every 5 seconds (every 15
  seconds on Images, Services, Storage, Models, Alerts and Stats (whose storage chart
  uses the Storage tab's reads), and on Builds once the
  build engine is ready). The
  status report is re-read when k3sm changes one of its status records
  (`/var/lib/k3sm/status`) or a launchd job file in
  `/Library/LaunchDaemons` changes: the app watches those two directories
  for changes and reads nothing from them, then runs `k3sm status -o json`
  a quarter second after the changes stop (at most 3 seconds after the
  first). Otherwise the report is re-read every 5 minutes, which also bounds
  how stale its cluster rows (read from the API server) can get; while either
  directory cannot be watched (k3sm not yet installed, the data volume not
  mounted) it is re-read every 30 seconds instead, so the panel follows
  nodes as they join and leave. When the installed k3sm offers its status
  stream (`watch-json` in the report's `capabilities`, checked once each
  time the app starts), the app instead holds one `k3sm status --watch -o
  json`, with the window open or closed, and the status item and the window
  both take each report it sends: k3sm checks again when a node or pod
  changes and every 30 seconds whatever happens, and sends a report only when
  it says something new. The directory watches and their timer stop while
  the stream sends reports, so a change to a status record shows within those
  30 seconds. The stream ends itself about
  every 30 minutes and the app starts a new one at once; if it ends any other
  way, the app goes back to the reads above until a new stream, started
  after a growing, randomized wait of at most a minute, sends a report. If
  the cluster refuses the admin kubeconfig, the stream is not retried and
  the status says so; if k3sm cannot watch the cluster (the API server
  unreachable, no kubeconfig, or the watch forbidden), the stream carries on
  with its 30-second check and the status names the cause. The status item
  keeps its own daemon check either way, since a stopped or crashed daemon
  changes no file. The pods stay followed while another tab is selected
  (without a watch, the pod list is read every 30 seconds), so the panel's
  pod figures stay current; the panel shows their age beside its state when
  that read is late. No other tab is
  read while it is not selected; when you come back to it, it shows what it
  last read and how long ago. When the cluster has an interconnect (the
  cable network between Macs) and an administrator has armed it, the panel
  shows an Interconnect block: how many cabled nodes are up, the segments,
  how many pods hold an interconnect address, the nodes past its address
  range, and that pod traffic on the cable is not encrypted.
- **Live load** comes from metrics-server when the cluster runs it. While
  the window is on screen the app reads the `metrics.k8s.io` node and pod
  samples in one `k3sm kubectl get`, one read at a time, and keeps the last
  sample: every 15 seconds while the Stats tab, or a selected pod's or
  node's load rows in the details column, are shown, every minute on any
  other view (Low power doubles both), and not at all while the window is
  hidden. Opening Stats or a pod's or node's details reads at once when the
  last sample is older than 15 seconds. Each node in the Cluster view, and this
  Mac's node in the This Mac view, gets one CPU and one memory bar: what its
  pods request as a light band, what it uses now drawn solid over it, the
  figures under the bar ("1.43 used of 19 cores", "3.5 requested"), and one
  key for the block that names only the parts drawn; the pod details add the pod's CPU used (and its share
  of the request), memory used and the sample's age. A line under the bars
  says how old the sample is ("12 s ago"). A node or pod metrics-server has
  no sample for reads "no metrics yet", never zero. When the cluster serves
  no metrics API, or its APIService is not available, the bars show the
  requests alone; the app then looks again every minute. Nothing is written to
  disk; the Stats tab keeps the last hour of samples in memory.
- The **Update** button is on the Alerts tab's first card ("2 nodes behind
  v0.1.9", or "Updating…" while a roll runs), when the update plan has an update for this Mac: the
  app-carried update or the cluster's managed update (see
  [Updating](#updating)).
- The **status** at the top of the left panel and of the status popover is
  one state with a coloured dot: Running (green), Degraded or Unknown
  (amber), Stopped or Not installed (grey), or a newer CLI's word as it
  prints it. The pod count is a figure in the panel's tiles, and a lock
  beside the state marks checks that only an administrator can run.
  VoiceOver reads the state with the cluster's summary,
  the pod count and how many checks need an administrator.
- The **info button** opens the status popover: the state of this Mac (and
  who stopped k3sm, when it is stopped), only the checks that need
  attention, or "All N checks are ok." when none does, two version cards
  (the k3sm installed on this Mac, and the release this app carries or the
  app's own build) with the same **Update** button and the plan's line
  under them, and Stop, Restart or Start. **All checks**, closed at first, holds every check
  and Refresh; the app remembers whether you left it open. The log of an
  install, update or uninstall shows there only while one runs or after one
  failed. Connections from other devices and Uninstall are in Settings.
- The **tabs** above the list are:
  - **Workloads**: every pod, with the Mac it runs on. Its **Events** switch
    shows the cluster's events instead, newest first and at most 200, with a
    menu that picks one namespace or all of them. Events are read only while
    that switch is on.
  - **Nodes**: every node of the cluster, this Mac's first, with its role,
    whether it is Ready (and "cordoned" when it takes no new pods), its k3sm
    release with how it compares with the cluster's target ("0.1.7 ·
    behind": current, behind, ahead, updating or unknown), and its live load
    as shares of what it offers ("8% CPU · 20% memory", or "no metrics
    yet"). The target is the release a managed update in progress moves to,
    else the latest release the server's last update check found, else the
    release the control-plane node runs; the app asks no one on the network
    for it. A build of an untagged commit (a pseudo-version) is compared by
    the release it follows and reads "ahead, untagged" or "behind, untagged";
    a dev build or a build from a modified tree is unknown. A line over the list sums it up ("2 nodes
    on 0.1.8", "1 node behind 0.1.8", "Updating to 0.1.8 · 1 of 3 nodes on
    it"), and the node inspector shows the node's state with both versions
    and the latest release. It renders the same node list the panel and
    Images read, so it makes no read of its own. On the server's app a node
    that is behind offers **Update…** in its context menu and its details,
    and the summary line carries one **Update…** for every node behind
    (see [A node behind the server](#a-node-behind-the-server)).
  - **Images**: the images in the cluster's one registry, from
    `k3sm image ls -o ndjson` (no administrator needed): each image's
    reference over its short digest, its size, the number of pods using it
    and the nodes holding a cached copy. Rows appear as the registry is
    read, and a bar under the header shows how far the read has got
    ("Reading the registry: 340 of 1,153 images"); a refresh keeps the rows
    on screen until its read ends. The read is cut off after two minutes; a read
    that does not finish says so, over the images it read. A k3sm that does
    not stream the list is read with `k3sm image ls -o json` for the rest
    of the session. A registry that cannot be reached is
    one line with its error; a note names any node whose cache list was cut
    short, and a banner says when images stayed in a node's own store when
    they moved into the registry. Its header row names this Mac's node and
    offers **Mirror…** and **Prune…** (see below).
  - **Builds**: the build engine's state, then your build history, newest
    first (from `k3sm build ls -o json`, the builds your account ran on this
    Mac): each build's image, status, start time and duration.
  - **Services**: every service, with its namespace, type, cluster IP and
    ports, and the hosts of the ingresses that route to it (`*` for a rule
    that matches any host). After each service list the tab also reads every
    EndpointSlice (`k3sm kubectl get endpointslices -A -o json`) to count each
    service's ready endpoints; if that read fails the count says "not
    reported" and the list is still shown.
  - **Storage**: this Mac's data volume on top (from `k3sm datavol status`:
    mounted or not, its quota, usage and free space, and any copy a
    migration left behind), then every volume claim with its volume,
    capacity and phase, and the volumes no claim holds.
  - **Models**: every MLX model with its model name, phase, ready replicas
    and endpoint. On a cluster that does not serve the MLX API the tab says
    "Unavailable (the MLX API is not served on this cluster)", which is not a
    failure.
  - **Stats**: charts of what the console already reads, as cards (light by
    day, dark by night) with a headline figure where the data has one (pods
    running, nodes with pods, restarts in the last hour, free space on the
    data volume): CPU and memory per node over the last hour (as shares of
    what each node offers, one point per metrics sample, about 240 per node), pods by
    phase and by node, container restarts in the last hour (the rise in
    each pod's restart count between pod-list reads, in five-minute bars),
    image count and size by node, the bound claims' capacity against the
    data volume's free space, and the managed update's state over this
    session. The tab makes no new kind of read: while it is shown the app
    runs the Storage tab's reads at the Storage tab's cadence, so the
    storage chart says "Not read yet" only until their first read. The samples
    are kept in memory only, so the charts start empty after a relaunch. A
    chart with nothing to draw says why ("No samples yet", or "Metrics
    unavailable" with the reason) rather than drawing zero.
  - **Alerts**: the checks that are failing or need attention (click the status headline to open it), worst first, then the checks that could not tell and those only an administrator can read, then the report's next steps. Each card leads with the cause in plain words, with what the check saw under **Evidence**, the numbered steps that fix it and **Read the guide**, which opens the k3sm guide page about the problem. A step that runs a command shows it with **Copy**, which copies exactly the command k3sm printed; a command that is not one line of plain ASCII text of at most 1 KB is shown as text with no Copy, and the same rule applies to every Copy in the tab. A lock marks a step that needs an administrator, and **Check before running** marks one that deletes state or relaxes trust. The app never runs a step: paste it into Terminal and read it first. A card from an older k3sm, which prints no alert, shows the check's detail and fix as before. Checks skipped because there is nothing to check are not listed, and neither is the workloads check, which the Workloads, Nodes and Images tabs show. When all is well the tab says "Everything is healthy" with the check's age, over a small field where the butterfly flies and now and then lands on a flower to rest (it perches still under Reduce Motion), with any check that could not tell or needs an administrator listed below. It shows the status report the app already reads. When one read of that report fails (a busy Mac can make `k3sm status` slow), the tab keeps the last report for up to three reads, with a line that says the read failed and how old the report is, and the app reads it again on its own within about 10 seconds; only when the reads keep failing does it say the status could not be read, and it keeps trying every 30 seconds.

  The tabs only read. The changes the console makes are a pod's
  **Restart** and **Delete**, a workload's **Pause**, **Resume**, **Scale** and **Rollout Restart**, a node's **Cordon**, **Uncordon** and
  **Drain**, this Mac's own **Update**, **Restart** and **Stop** in its node
  details, a
  service's **Delete**, the Workloads cleanup,
  a model's **Unload**, **Load** and **Delete**, a claim's **Delete**, the
  Storage cleanup of unused volumes, and the Builds tab's engine, cache and
  build actions (below). The app remembers the tab, each tab's
  search and selection, the Workloads switch and the events namespace.
- **Restart…** and **Delete…** in the pod details are the console's writes.
  Restart is shown only for a pod whose owner recreates it (a ReplicaSet,
  which a Deployment's pods have, a StatefulSet or a DaemonSet); Delete is
  shown for every pod. The pod's row offers the same actions as the
  details when you Control-click it. The Delete key asks for Delete, behind
  the same question (never while you type in the search field); Restart is
  not on the key. Each question names the namespace and the pod. Restart's
  says the owner will recreate it; Delete's says what follows: "its owner,
  ReplicaSet web-5f6d, recreates it", "its owner, Job migrate, may not
  recreate it", or, for a pod with no owner, "nothing recreates it; this pod
  is gone for good". After you confirm, the app first
  reads the pod's UID with `k3sm kubectl get pod <pod> -n <namespace> -o
  jsonpath={.metadata.uid}` and stops, deleting nothing, when the pod is
  gone or is no longer the one you clicked; otherwise it runs `k3sm kubectl delete pod <pod> -n <namespace>
  --wait=false` as your own account, by the CLI's absolute path and only
  after checking, just then, that the installed k3sm and its directories are
  root-owned and not writable by others and that it carries the k3sm
  signature (a developer build of the app checks ownership only). `k3sm kubectl`
  uses the `k3sm` context of the admin kubeconfig that `k3sm install` wrote
  to your account (`~/.kube/config`), the same one every console read uses;
  the app adds no credential and no privilege. The pod's containers stop at
  once; an owner that recreates pods starts a replacement, which may have a
  new name and run on another node. One line under the buttons says whether the delete was
  accepted or why it failed, quoting kubectl's own message, and the pod list is read again;
  the line goes at the list's next good read after that one.
- **Pause…** in the pod details (and on the pod's Control-click menu)
  stops a workload without deleting it, by scaling its controller to zero;
  **Resume…** scales it back. Kubernetes has no stop for a pod, since its
  owner recreates a deleted one. Beside the pod list the app reads `k3sm
  kubectl get deployments,statefulsets,replicasets -A -o json` and follows
  the pod's controller (the owner reference marked as the controller): a
  ReplicaSet is followed one step to the Deployment that controls it,
  since scaling the ReplicaSet would be undone by the Deployment, and a
  StatefulSet is used as it is. A DaemonSet's pod shows "cannot pause a
  DaemonSet", and a pod with no such controller (a bare pod, a Job, a
  ReplicaSet no Deployment controls) offers no Pause. The question names
  the namespace and the controller and says what happens: its pods stop,
  the Deployment or StatefulSet stays, and Resume restores the replicas it
  has now. After you confirm, the app reads the controller's UID and
  replicas and recorded count (`k3sm kubectl get <kind>/<name> -n <namespace> -o
  jsonpath={.metadata.uid} {.spec.replicas} {.metadata.annotations.k3sm\.io/paused-replicas}`) and changes nothing when it
  is gone, was recreated or now asks for another count; then it records the
  count on the controller with `k3sm kubectl annotate <kind>/<name> -n
  <namespace> k3sm.io/paused-replicas=<count> --overwrite` and, only once
  that succeeded, runs `k3sm kubectl scale <kind>/<name> -n <namespace>
  --replicas=0`. The count lives on the controller, so Resume works after a
  relaunch or from another Mac. A paused controller's pods carry a
  **paused** badge, its pods' details name it as "paused; Resume restores
  N replicas", and once its pods are gone it keeps a row of its own in its
  namespace, with the badge and **Resume…**. Resume asks first, then runs
  `k3sm kubectl scale <kind>/<name> -n <namespace> --replicas=<count>` and,
  once that succeeded, removes the record with `k3sm kubectl annotate
  <kind>/<name> -n <namespace> k3sm.io/paused-replicas-`. Resume
  reads the controller again and runs only when the record is still the one
  you confirmed and the controller still asks for zero replicas; otherwise it
  says the workload changed since you clicked and changes nothing. A record
  that is not a whole number from 1 up restores 1 replica, and the question
  says the record was unreadable. A controller that carries a record but
  still asks for replicas (a Pause that recorded the count and failed to
  scale) shows a **stale** badge and offers **Pause…** again, which only
  scales it to zero and keeps the record. Only `apps/v1` controllers with a
  UID are followed. Every step reads the UID
  first, with the same trust check and account as Restart; the line under
  the buttons and on the paused row says the result, including a pause
  that recorded the count but did not scale (Resume clears it). Neither
  is on the Delete key.
- **Scale…** in the pod details sets the replica count of the pod's
  Deployment or StatefulSet, the controller Pause follows. A stepper from
  1 to 50 starts at the count the controller has now; Scale is enabled
  once you have moved the stepper to another one (a controller above 50
  opens at 50 with Scale off), and kubectl gets `--current-replicas` so a
  count that moved is refused. The question names the controller
  and both counts and, for a scale down, how many pods stop. After you
  confirm, the app reads the controller's UID, replicas and Pause record
  (the same read as Pause) and changes nothing when it is gone, was
  recreated, now asks for another count than the one you clicked on, or
  was paused since; otherwise it runs `k3sm kubectl scale <kind>/<name> -n
  <namespace> --replicas=<count>`. A paused controller shows "paused:
  Resume it first, then scale" in place of the stepper, and one whose Pause
  is half done says to finish it first. A DaemonSet runs one pod per node
  and has no Scale.
- **Rollout Restart…** in the pod details (and on the Control-click menu)
  replaces the pods of the pod's Deployment, StatefulSet or DaemonSet by
  the controller's own update strategy, one at a time by default, as a new
  version rolls out; the controller and its count stay. After you confirm,
  the app reads the controller's UID with `k3sm kubectl get <kind>/<name>
  -n <namespace> -o jsonpath={.metadata.uid}` and changes nothing when it
  is gone or was recreated; otherwise it runs `k3sm kubectl rollout restart
  <kind>/<name> -n <namespace>`. A controller with the OnDelete strategy
  replaces each pod only when it is deleted. Scale and Rollout Restart run
  with the same trust check and account as Restart, and their line shows
  under the buttons beside Pause's. Neither is on the Delete key.
- **Logs open in a pane along the bottom of the window**, under the list,
  the details and the left panel. **Open Log** in a pod's details shows its
  last 200 lines of every container there; the pane's title names the log,
  and its close button stops the read and puts the pane away. Opening
  another log, a pod's or a build's, replaces what the pane shows. Drag the
  pane's top edge to resize it, from 120 pt up; it opens at a third of the
  window, and the app keeps the height you drag to.
- **Follow** in the log pane streams the pod's log into it:
  `k3sm kubectl logs -f --tail=200 <pod> -n <namespace>`, with `-c
  <container>` from the Follow menu for a pod of several containers. The
  pane keeps the newest line in view and the line under it says how the
  follow stands. **Stop** ends it, keeping the lines read so far; so does
  closing the pane or opening another log. The pane holds
  64 KiB, the app's limit for a pod's log, and a follow stops there and
  says so, as it does after 30 minutes; Follow starts it again with the
  newest lines. It only reads.
- A **service**'s details and its Control-click menu offer **Copy Cluster
  IP** (not for a headless service) and **Copy DNS Name**
  (`<name>.<namespace>.svc.cluster.local`), which put the text on the
  pasteboard. When the service has a web address they also offer **Open in
  Browser** and **Copy URL**: an ingress host that routes to it (the first
  whole host name, not `*`), over https when the ingress lists that host
  under TLS and http otherwise; or, without one, a node port on a TCP port
  named `http` or `https` or numbered 80, 443 or 8080, opened as
  `http://127.0.0.1:<node port>` (https for a port named `https` or numbered
  443), since every node answers its node ports on its loopback address as
  on its network address. **Delete…** asks first, naming the service and the
  ingress hosts that stop answering, then reads the service's UID with
  `k3sm kubectl get service <name> -n <namespace> -o
  jsonpath={.metadata.uid}` and deletes nothing when the service is gone or
  is no longer the one you clicked; otherwise it runs `k3sm kubectl delete
  service <name> -n <namespace> --wait=false`, with the same trust check,
  account and result line as Restart. The Delete key asks for it too. The
  API server's own service (`kubernetes` in `default`) and every service in
  `kube-system` offer only the two copies: the cluster runs on them.
- A pod's details and its Control-click menu also offer **Copy Name** and
  **Copy Namespace/Name**, which put the text on the pasteboard, and, for a
  pod in phase Running, **Open Shell in Terminal**: after the same check of
  the installed k3sm it writes a `.command` file into a fresh private folder
  and opens it in Terminal, where it runs, as your account and with the
  same scrubbed environment as Open Status, `k3sm kubectl exec -it <pod> -n
  <namespace> -c <container> -- sh` in the pod's first container, and tries
  `/bin/sh` once when the container has no `sh` on its PATH (exec exits 126
  or 127).
- For a pod in phase Running, Succeeded or Failed, the details and the
  Control-click menu offer **Summarize Logs** (one per container, named,
  when the pod has several). It asks nothing first and changes nothing. The
  app checks that Apple's on-device model can run on this Mac; when it
  cannot, it says why in plain words (this Mac is not eligible for Apple
  Intelligence, Apple Intelligence is turned off, or the model is still
  downloading). Otherwise it reads `k3sm kubectl logs <pod> -n <namespace>
  -c <container> --tail=500 --timestamps`, and the same with `--previous`
  when the container has restarted, at most 256 KiB each. It sends the
  model as much as fits the model's context with room for the answer: the
  newest lines, every line that looks like an error, the first few lines,
  and the middle dropped, with the number of lines left out stated. The log
  is quoted as data, and the model is told it is untrusted text to
  summarize, never instructions. The model runs on this Mac through Apple's
  Foundation Models framework; nothing leaves the Mac. One summary runs at
  a time, with Cancel and a 60-second limit. The answer is shown as plain
  text with the time the log covers, how many lines reached the model, the
  line "Generated on this Mac by Apple's on-device model; check the log."
  and Copy. It is never turned into an action, a command or a link. The
  summary is kept per container until its log changes, so asking again
  for an unchanged log shows it without running the model.
- **Cordon…** and **Uncordon** in the node details (and on the node's row
  when you Control-click it) are offered by the node's state: Cordon while
  it takes new pods, Uncordon once it is cordoned. Cordon asks first: it
  marks the node unschedulable, so no new pods are placed on it, and the pods
  already there keep running. Uncordon only opens the node again, so it runs
  on the click. Either first reads the node's UID (`k3sm kubectl get node
  <name> -o jsonpath={.metadata.uid}`) and changes nothing when the node was
  recreated under the same name since it was listed; then it runs `k3sm
  kubectl cordon <name>` or `k3sm kubectl uncordon <name>` and leaves one
  line under the buttons. A node whose name is not a valid Kubernetes name,
  or that was listed without a UID, offers neither.
- **Drain…**, beside Cordon or Uncordon on every node, asks first: the
  node is cordoned and its pods are evicted, so they move to other nodes
  that can take them (a pod with nowhere to go waits as Pending); data in
  their emptyDir volumes is lost; DaemonSet pods stay. It reads the node's
  UID first like Cordon, then runs `k3sm kubectl drain <name>
  --ignore-daemonsets --delete-emptydir-data --timeout=120s` (never
  `--force`, so a pod no controller owns stops the drain with kubectl's own
  error) and reports how many pods were evicted, or the error after the
  count. A drained node is cordoned, so it then offers Uncordon.
- **Update k3sm…**, **Restart k3sm…** and **Stop k3sm…** are in the node
  details of this Mac's own node only. Update is offered whenever the update
  plan has an update for this Mac (see [Updating](#updating)), and runs it,
  enabled when Update Now is. Restart and Stop are the menu's, with
  the same question (Stop says what stops, and warns when other nodes have
  joined) and administrator prompt. While a managed update rolls they wait,
  since the update restarts each node itself. A worker behind the server
  with no newer release in the app says to update it from the server's
  managed update. Another Mac's node offers none of
  them: its details say to update it from the server's managed update or
  from the k3sm app on that Mac. On the server's app, another Mac's node
  that is behind offers **Update…** there (see
  [A node behind the server](#a-node-behind-the-server)).
- **Delete completed and failed pods…**, at the right end of the Pods /
  Events row while Workloads shows its pods and some pod has finished, deletes every pod in phase Succeeded
  or Failed, or evicted. The question names how many and in which
  namespaces. The app reads every pod's UID first and deletes nothing when
  one of those names now belongs to a new pod; otherwise it runs one `k3sm
  kubectl delete pod <names...> -n <namespace> --wait=false` per namespace
  and leaves one line beside the button: how many were deleted, how many were
  already gone, and where and why any were not.
- A **model**'s details and its Control-click menu offer **Unload…** while
  it asks for replicas and **Load…** while it asks for none, never both.
  The MLX API has no load verb and no scale subresource (`kubectl scale`
  answers NotFound), so both are one merge patch, `k3sm kubectl patch
  mlxmodels.mlx.k3sm.io <name> -n <namespace> --type=merge -p <patch>`.
  Unload sets `spec.replicas` to 0 and records the count it had in the
  model's `k3sm.io/replicas-before-unload` annotation; the operator scales
  the serving workload to zero and the model reads Ready=False,
  ScaledToZero. Load sets `spec.replicas` back to the recorded count (1
  when there is no record, or it is not a whole number from 1 up) and
  removes the annotation in the same patch. **Delete…** runs `k3sm kubectl
  delete mlxmodels.mlx.k3sm.io <name> -n <namespace> --wait=false`; the
  operator removes the serving pods, the Services and the cache claim, and
  the question says the weights volume is kept and appears in the Storage
  tab as Released, where deleting it removes only the object and the data
  stays on the node's disk until someone with root removes it. The Delete key asks
  for Delete, never for Unload. Each asks first, naming the model and the
  replica count, then reads the model's UID with `k3sm kubectl get
  mlxmodels.mlx.k3sm.io <name> -n <namespace> -o jsonpath={.metadata.uid}`
  and changes nothing when the model is gone or is no longer the one you
  clicked, with the same trust check, account and result line as Restart.
  A serving model also offers **Copy Endpoint** (its `status.endpoint`, the
  in-cluster address) and **Copy curl Example**, a call of its
  `/v1/chat/completions` API as the MLX quickstart makes it from the Mac:
  the Service's cluster IP read by `/Library/k3sm/k3sm kubectl get svc
  <name> -n <namespace> -o jsonpath='{.spec.clusterIP}'` inside the
  command, the port from the endpoint, and a short request naming the
  served model. The curl example is offered only when the endpoint names
  the model's own Service and the model is a plain repository id, since you
  paste it into a shell.
- **Delete…** on a volume claim, in its details, on its row's Control-click
  menu or with the Delete key, deletes the claim. The question names the
  pods still mounting it (the pods in its namespace whose spec mounts it,
  directly or as a generic ephemeral volume, that have not finished), and
  says that Kubernetes keeps the claim, as Terminating, until they are gone.
  It also says what happens to the data: k3sm's `local-path` class keeps
  volumes (reclaim policy Retain), so the claim's volume stays behind as
  Released and the data stays on the node's disk, in the directory the
  question shows. Before the pod list has been read the question says
  whether a pod mounts the claim is not known. After you confirm, the app
  reads the claim's UID with `k3sm kubectl get pvc <claim> -n <namespace> -o
  jsonpath={.metadata.uid}`, deletes nothing when the claim is gone or is
  not the one you clicked, and otherwise runs `k3sm kubectl delete pvc
  <claim> -n <namespace> --wait=false`, with the same trust check and
  account as Restart. A volume no claim holds offers no row action.
- **Delete released and unclaimed volumes…** at the right end of the
  Storage tab's header row, shown while a volume is Released (its claim was deleted) or Available with
  no claim reserving it, deletes those volume objects. The question gives
  their number and names and the data directories they record, and says
  the directories stay on disk: deleting a volume object does not remove
  its data, and removing a directory takes root on its node, which the app
  never does. After you confirm, the app reads every volume with `k3sm
  kubectl get pv -o json` and deletes nothing unless each one is still
  listed with the same UID and still unused; then it runs `k3sm kubectl
  delete pv <volume>... --wait=false`. Its line shows beside the button.
- On **Builds**, the buttons at the right end of the tab's header row act on
  the build engine: **Start Engine** (`k3sm builder up`) while it is not running, **Stop Engine**
  (`k3sm builder down`, which keeps the build cache) while it is, and
  **Reset Engine** (`k3sm builder delete`, then, once that succeeded,
  `k3sm builder up`: the engine and its cache start over), and **Prune
  Cache** while it serves. Stop and Reset ask first. Prune Cache first runs
  the dry run (`k3sm build prune`), then asks with what a prune would
  reclaim, and prunes (`k3sm build prune --force`) only if you confirm. Each
  runs as your own account, with the same check of the installed k3sm as
  Restart; k3sm uses the admin kubeconfig `k3sm install` wrote to your
  account, as `k3sm kubectl` does. A k3sm older than that fallback refuses
  without root, and the line under the engine card then shows its own
  message. That line says how each action ended, with the freed size after
  a prune.
- A **build** that pushed an image to the cluster's registry offers **Show
  in Images** in its details. It reads the registry's list again
  (`k3sm image ls`), switches to the Images tab and selects the
  image's row, by the reference `k3sm build ls` recorded and only while the
  registry still holds the digest the build recorded. When the image is
  gone, or the list could not be read, the Builds tab stays and the line
  under the button says so.
- Each **build** in the history offers, from its row's Control-click menu or
  its details: **Show Log**, the build's stored log in the log pane
  (`k3sm build logs <id>`, following it with `-f` while the build runs; the
  pane shows at most 1 MiB, and closing it stops the read); **Cancel
  Build** while it runs (`k3sm build cancel <id>`); and **Delete Record**
  once it has finished (`k3sm build rm <id>`, which removes the record and
  its log, not the image), which is also on the Delete key. Both ask first,
  and run as your own account. A build's id reaches a command only as the
  twelve hexadecimal characters `k3sm build ls` gives it; a row with any
  other id offers no action.
- The **Images** tab acts on the cluster registry and this Mac's image
  cache. Every `k3sm image` command it runs needs either the root-owned image
  daemon or the server's registry credential, so each runs as an
  administrator through the same checked step as Stop and Restart (the
  installed k3sm and every folder above it owned by root and not writable by
  others, and the k3sm Developer ID signature, are checked first). The
  administrator prompt names what it changes.
  - **Untag…**, in an image's details and its Control-click menu, deletes
    that tag from the cluster registry with
    `k3sm image untag <tag> --digest <digest>`, pinned to the digest the
    list read, so a tag moved to other content in between is left alone. It
    removes a name, not bytes: a manifest another tag names stays, the
    registry's garbage collection reclaims the rest, and nodes keep their
    cached copies. It is offered on the server's app only, since the server
    holds the registry's credential; elsewhere its reason says so.
  - **Mirror…** opens a field for an image reference and runs
    `k3sm image pull <reference>`: the daemon's own puller fetches it into
    this node's cache, checking every blob's digest, then k3sm copies a
    public image into the cluster registry as
    `registry-k3sm:6450/<registry>/<repository>:<tag>`, which nodes pull
    from when the public registry cannot be reached. A reference in the
    cluster registry, or in a registry with a port, gets no copy. The field
    accepts only a reference in the registry grammar (an optional registry
    host and port, lowercase path parts, then a tag, a `sha256:` digest or
    both, at most 456 characters), so nothing else can reach the command.
    It asks first, naming the node, whether a copy is written and, in its
    own sentence, the registry the image daemon contacts as root (the
    reference's registry host; for a name with none, this node's own
    registry if it has one, then Docker Hub), with no credential. The line
    after it names the copy, or says k3sm did not report one.
  - **Prune…** first runs `k3sm image prune`, whose default is a dry run,
    and shows what it would delete: the cluster registry's untagged
    manifests (on the server; an agent's prune says it skips them), the
    cache's blobs, their size and what it kept and why. The sheet opens
    when either half has something to delete, so an empty cache still
    offers the registry's half. Only if you confirm that list does it run
    `k3sm image prune --force`. The prune works out again what nothing
    references when it runs, so content a pull or a new pod picks up in
    between is kept. A dry run whose output k3sm cannot read, or that prints
    more than the 256 KiB k3sm holds, is refused, and nothing is deleted. Each step asks for the administrator password.
- The **details** on the right follow the tab. Click a row on any tab (on
  Builds, the engine card or a build) and its details show there: a pod's facts
  and its events or manifest, with Open Log for its log; a node's role, readiness, whether it
  takes new pods, kubelet and k3sm versions, addresses, capacity and
  allocatable, its live CPU and memory bars with the last few CPU samples and
  the sample's age ("no metrics yet" before metrics-server has sampled it),
  its conditions (Ready first) with how long ago each last changed and why,
  its taints, and the pods on it that have not finished with what each uses
  now; an image's reference, digest, size, the
  nodes holding it and the pods using it, with its Untag button for the
  registry tag; the build engine's state, pod,
  node and cache; a build's image, status, start time, duration, context,
  platform, digest or error, and record id; a service's type, cluster IP, ports, ready endpoints and
  ingress hosts; a
  claim's volume, capacity, access modes, class, phase, the volume's data
  directory and the pods mounting it; a model's model,
  replicas, ready replicas, phase and endpoint. The heading names the kind
  of row and the row. Each tab keeps its own selection: changing tab shows
  that tab's selected row, or "Select a service." (and so on) when it has
  none, and coming back shows the old row again only if it is still listed.
  A row that disappears from a tab's list clears its details.
- A tab that is **reading** says so with a small butterfly: beating in the
  middle of the tab while its first read runs, and perched on the first
  letter of the tab's name while a later read runs behind the list it
  already shows; the names never move to make room for it. The perched one
  turns side-on as it appears and flies in from the upper left in profile,
  beating fast, then closes its wings and sits on the letter the way a real
  butterfly does, body level, wings closed together above its back (the
  same butterfly, turned on its side with its wings folded up, as big as
  it was in flight), getting a little smaller on a beat of its closed
  wings and back once every 0.8 seconds; when the read is done it turns back to
  face you, opens its wings and flies off to the upper right, fading out.
  On the tab you are looking at, every refresh lands the butterfly on the
  name and keeps it there at least 0.8 seconds, however quick the read. A
  first read that ends within 0.3 seconds shows nothing, and once the big
  butterfly appears it stays at least half a second, so a quick read never
  flashes. With Reduce Motion on, both are shown still and the perched one
  appears and goes without flying.
- The **details button**, beside the info button above the list, collapses
  the details on the right and shows them again; Command-Option-I does the same, and the app remembers the choice.
  The button keeps one colour either way; its symbol shows whether the details are open.
- The **details column** opens 320 pt wide. Drag the divider between it and the list to
  resize it, from 240 pt up to the width that leaves the list its minimum. The app keeps
  the width you drag to; resizing the window does not change it.
- The **left panel** opens at its natural width: the narrowest at which
  nothing in the Cluster or This Mac view is squeezed (the tiles in their
  two-by-two grid, the longest node row with its meters beside it, the
  memory block's figures and legend, the live load bars), the wider of the
  two views. It keeps that fit as the figures change until you drag the
  divider between it and the list. You can make it narrower, down to its
  original width: each node's meters then move under its name. It goes no wider than its natural width; dragging it back there,
  or Reset Window Layout in Settings, lets it fit itself again. Dragging the
  divider stops at the panel's original width and never hides it (a
  double-click on it does nothing). While the panel is hidden, dragging the
  divider at the window's left edge shows it again. Choose
  View > Hide Panel (Command-Option-L) to hide the panel, and View > Show
  Panel (the same shortcut) to bring it back; while it is hidden the tabs
  start past the window's close, minimize and zoom buttons. The window's
  minimum width follows: the panel's minimum plus the list's, or the list's
  alone, with room for those buttons, while the panel is hidden. A width you drag narrower than the content
  lasts the session only; a saved width that is narrower than the content is
  replaced, and the panel opens fitted. The app remembers whether the panel
  is hidden.
- Every tab's **table columns** are resizable: drag the faint line between
  two column titles. The line on a column's far side from the name column
  moves with the pointer, so a column after the name widens as you drag
  left and one before it (the Events list's age, reason and object) as you
  drag right; the name column takes the width the others leave. A column
  goes no narrower than its title needs and no wider than its maximum, and
  never so wide that the name column drops below its own minimum.
  Double-click the line to put that column back to its first width. The app
  remembers the widths for each table; View > Reset Column Widths puts every
  table back.
- The **tab names** above the list stay whole on one line. The window goes
  no narrower than the row above the list needs for every tab name, the
  search field at its narrowest and the buttons beside it; only a tab name longer than 24 characters would be
  shortened, at its end. With the panel and the details shown that is at
  most 1440 points, so the window fits the narrowest Mac laptop display.
- The **window** reopens where you left it, at its size and on its display, after a relaunch too; if that display is gone or the window would sit off the screen, it is moved onto the main display, never smaller than its minimum.

The app reads the machine interface the k3sm CLI documents: the cluster's state
from `k3sm status -o json`, the console's lists through `k3sm kubectl` and the
`k3sm image`, `k3sm build`, `k3sm datavol` and `k3sm update status` read
commands. It runs `/Library/k3sm/k3sm` by absolute path with an
environment it builds itself. A newer CLI may print status words this app does
not know; they are shown as printed and never stop the app from reading the
rest.

The app runs as you, not as root, so some checks are ones only an
administrator can run (the runtime daemon's owner-only socket, for one). The
CLI reports those rows as `needs-admin`, and the app shows them with a grey
glyph and "needs an administrator; run sudo k3sm status". Nothing was checked
and nothing is wrong, so these rows never count against the verdict. While
there are any, a small lock sits beside the state; its help tag says how many
("Needs an administrator to read 1 check"). Run `sudo k3sm status` in a
terminal to see them checked.

## The menu

The status item's menu opens with two status lines, **Cluster** and **This
Mac**, each with a coloured circle and a word: ok (green), degraded (amber),
down (red) or unknown (grey). This Mac follows k3sm's verdict on this Mac.
Cluster reads the nodes-ready count: ok when every node is ready, degraded
when some are, down when none is or the API server cannot be reached. Both
come from the full status read each time the menu opens, and This Mac also
follows the regular probe. While that read runs past 0.3 seconds with the menu
open, the butterfly in the menu bar beats its wings (still with its badges)
until the read ends or the menu closes; with Reduce Motion on it stays still.
The full status and the setting for connections from other devices are in the
window. Then come the actions:

- **Update to v0.1.8…** (the managed update, naming the release k3sm
  found) or **Update This Mac to 0.1.8…** (the release the app carries)
  appears when the update plan has one (see [Updating](#updating)), and runs
  it. It shows disabled, with the reason as its help text, when the app
  cannot run it now. While an update rolls it reads **Updating…** and cannot
  be clicked.
- **Stop k3sm** stops k3sm on this Mac completely, pods included, and keeps it
  stopped across restarts until you start it (`sudo k3sm stop`). Before it
  asks, the app reads the status again. On a server with joined nodes it names
  them and warns that stopping halts the cluster's control plane for them. When
  it cannot tell whether any node has joined, it says so and warns anyway.
- **Restart k3sm** restarts the k3sm daemons; pods keep running.

  Stop and Restart appear only on a release build of the app with a k3sm that
  supports them (see below); otherwise the menu does not show them.
- **Live Status in Terminal** opens a Terminal window, titled k3sm status
  (live), that runs `k3sm status -o wide --watch=2s`: the full status, redrawn
  every 2 seconds. Press Control-C to stop it; the window then says it stopped.
- **Live Top in Terminal** does the same for `k3sm status top --watch=2s`, the
  nodes and pods by CPU and memory. It appears only when the installed k3sm
  has that view (`k3sm status top --help` succeeds).
- **Open Logs** opens the node daemon's and netd's logs in Console.
- **Write a Bug Report** opens a Terminal window that collects the k3sm and
  macOS versions, the status JSON, the daemons' launchd state and the tail of
  each k3sm log into one file, with tokens, keys and passwords redacted, and
  opens that file for you to read. Nothing is uploaded, and it reads no
  kubeconfig, token, Secret, environment or pod manifest. Share the file
  yourself if you want to.
- **Copy Join Command…** appears on a server only. It mints a fresh worker
  join token (valid for 15 minutes) and copies the join as one line, as a
  concealed clipboard item that stays on this Mac and is cleared after 60
  seconds; paste it into Terminal on the Mac that should join. It shows
  disabled, with the reason as its help text, while k3sm is not running on this
  Mac, another change is running, or the Mac has more than one join address.
- **Settings…** (Command-comma), **Dashboard** and **Quit k3sm**. Quitting
  the app leaves k3sm running, as k3s keeps running with nothing watching it,
  unless **Stop k3sm when I quit the app** is on in Settings > General.

The menu bar at the top of the screen has **View > Refresh** (Command-R),
which re-reads the status and the open tab, and **Help > Take the Tour**, which
starts the guided tour of the window.

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

## Settings

**Settings** opens from the gear at the right end of the console's strip,
from the app menu's **Settings…** (Command-comma) and from the status item's
menu. The window opens at the pane you last used, where you last left it.
While it is open k3sm is in the Dock, as it is while the main window is. The
status panel the app menu's Settings item used to open is now **View > Show
Status**, and still hangs from the info button.

Settings are yours and the app's alone: they take effect at once and need no
administrator. Anything that changes what k3sm itself does on this Mac stays
a k3sm setting, made through k3sm and shown as k3sm reports it.

The **General** pane:

- **Open k3sm at login** registers or removes the app's login item, and shows
  what macOS reports. When macOS needs your approval it says so, with a
  button that opens System Settings at Login Items; when macOS refuses a
  change it shows the reason. A copy of the app that does not run from the
  Applications folder cannot be added.
- **Open the window when k3sm opens at login** shows the window on a launch
  at login, not only the status item. It is off at first.
- **Notify me at login when k3sm is stopped** posts the "k3sm is stopped"
  notice with its Start button. It is on at first.
- **Stop k3sm when I quit the app** makes **Quit k3sm** stop k3sm first, while
  it is running, through the same Stop as the menu's: the same question, the
  same warning on a server with joined workers, and the administrator prompt.
  The app quits once the stop has finished. If the stop fails, or you answer
  no or cancel the prompt, the app says so and stays open; quit again, or turn
  the setting off. A quit because you log out, restart or shut down asks
  nothing and leaves k3sm running. It is off at first, so quitting the app
  leaves k3sm running.
- **Appearance** is **System** (as macOS is set), **Light** or **Dark** for the app's windows, popover and menus; the menu bar item follows the menu bar. It is System at first.
- **Animate the Dock icon while the window is open** beats the wings of the
  mark on the Dock icon. With Reduce Motion on in Accessibility settings the
  icon is always still, and the checkbox says so.
- **Status refresh** is **Normal** (the cadences this README states) or
  **Low power**, which waits at least twice as long between every read the
  app makes: the status item's poll (30 seconds while it is shown, 120 while
  it is hidden, against Normal's 15 and 60; a stopped or crashed daemon
  changes no file, so this poll is how the item notices one), each console tab, the status report, the update progress,
  live load and the update check. A change applies from each read's next
  wait. It is Normal at first.
- **Take the Tour** brings the window forward and starts the tour, once k3sm
  is installed.
- **Reset Window Layout…** asks, then puts the console's left panel back to
  its natural width and its first view (Cluster or This Mac, as a first
  launch chooses) and shows it if it was hidden, puts the details column
  back to 320 pt and shows it, opens logs at a third of the window again, and
  puts every table's columns back to their first widths. Tabs, searches and selections
  stay as they are.
- The pane's corner carries the k3sm mark and the app's own version,
  `k3sm.app v0.2.0` for a release build or the pseudo-version for a
  development build; the text can be selected and copied.

The **Cluster** pane shows this node's install settings as k3sm reports them
in its status: the node's role, then on a server the mesh address, the extra
names on the API server's certificate (TLS SANs), the NodePort addresses, the
node registry's port and the name the admin kubeconfig is merged under, and
on any node LAN access. A worker shows its NodePort addresses and LAN access
and says the rest is set on the server. The **Storage** pane shows the data
volume (none for a plain directory, else its name, quota and encryption),
whether the data root is mounted, and the release base the managed update
reads. Every value is selectable, and a value worth pasting has a **Copy**
button. A value only an administrator can read shows a lock and "needs an
administrator; run sudo k3sm status". A k3sm from before this report shows
each setting as "not reported by this k3sm". Both panes are read-only for
now: these settings are set by `k3sm install`, and changing them from the app
comes later. Opening either pane reads the status again.

The Cluster pane ends with **Kubeconfig**: the path of the admin kubeconfig,
`~/.kube/config` of your account (where `k3sm install` writes it for you),
or the path install recorded when the report names it. **Copy Path** puts
the path on the clipboard, never the file's contents, for `KUBECONFIG` or a
tool's settings; **Show in Finder** opens a Finder window with the file
selected. The app never opens the file. When your account cannot read it
(say, after `sudo k3sm kubeconfig --write` left it owned by root) the pane
says using it needs an administrator; when there is no file at the path,
both buttons are off and the pane says `sudo k3sm install` writes one.

The **Network** pane holds **Allow connections from other devices** (see
[Connections from other devices](#connections-from-other-devices)), with
the setting now, the listeners it controls, those it never closes, and the
address this node answers on once the console has read the node list.
Opening the pane reads the status again. A Mac with no k3sm node says it has
no network settings.

Under it, **Use the Thunderbolt interconnect** shows whether an administrator
has armed the cluster's interconnect (the cable network between Macs), with
the cabled nodes up, the segments and the pods attached while it is on, and
that pod traffic on the cable is not encrypted. It shows the state only: the
app has no step that changes it, so the pane says to run `k3sm interconnect
enable` or `disable` in Terminal. When the status names no interconnect (the
cluster has none, or the read could not see it) the box shows a dash.

The **Updates** pane (see [The managed update](#the-managed-update)):

- **Installed** and **Available**: the release the installed k3sm reports,
  and the newest one the server's update check found (while an update rolls,
  the release it rolls to), with what the check says in plain words: a newer
  release is available, the cluster runs the latest, a node runs a newer
  one, an update is rolling, or not known and why.
- **Update Now** runs the update plan, the same update as the menu and the
  console's Update button, with the plan's line under it: what it does, or
  why it cannot run. It is disabled, with the reason, when there is nothing
  to update or the app cannot run the update.
- While an update rolls, the same progress panel as in the console, with
  **Cancel Update…** and **Abort Update…**; after a failed update, with
  **Abort Update…**.
- **When updating**: **Drain each node before updating it** (off at first)
  evicts each node's pods before it updates; **Code signature** is either
  **Same signer as the installed k3sm** (the default) or the stricter
  **Developer ID signature required**. They are read when you click Update,
  and the question that follows names each one that is not the default; the
  update then runs with exactly what the question showed, as `k3sm update
  apply` flags, even if you change them here meanwhile. The release's
  checksum is always verified.
- **Notify me when an update is available** (on at first) posts a
  notification the first time the update plan offers an update the app can
  start, once for each release, never again for the same one, across
  launches too. macOS asks once whether k3sm may post notifications; if you
  say no, nothing is posted. A click on the notification opens this pane.
  While the console is closed and this is on, the app reads the status every
  30 minutes (an hour under Low power) to find a new release; the server
  itself checks hourly.

The release source the server checks is set when k3sm is installed and is
not shown here: `k3sm status` does not report it.

The **Advanced** pane:

- **Write a Bug Report…**, **Live Status** and **Open Logs**, the same
  actions as in the status item's menu.
- **Uninstall k3sm…**, with **Also delete k3sm's data** (see
  [Uninstalling](#uninstalling)).
- **Reset to Defaults…** asks, then puts every preference above back to its
  first value, and closes the status popover's All checks. The record of
  which release was last announced stays, so a reset does not announce it
  again. Open at login,
  the window layout and k3sm itself stay as they are.

## The managed update

A server checks for a new k3sm release at most once an hour (`sudo k3sm
update check` checks now), and its status report says when a node runs an
older release than the latest. The app reads only that report: it never
contacts the network itself. While the report names a newer release, the
menu offers **Update to <release>…**, the Alerts tab shows the **Update**
card, and Settings > Updates enables **Update Now**. When every node runs the latest release, runs a newer one, or the
check has no answer, neither appears.

Update asks first, naming the release, then shows the standard
administrator prompt and runs `/Library/k3sm/k3sm update apply --yes
--version <release>` through the same checked root step as Stop and Start,
adding `--drain` or `--signature required` when Settings > Updates asks for
them. `--version` names the release the question named, so a release
published while the question was open is not the one installed; the app
checks the tag with the same rule as `k3sm update apply` (letters, digits,
`.`, `+`, `_` and `-`, at most 128 bytes, not starting with `-`) and refuses
any other before it asks. When the
status report names a node that runs a release newer than the latest, the
question also carries **Allow a release older than a node runs**, off each
time it opens; ticked, that one update runs with `--allow-downgrade`. It is
never remembered. k3sm then updates the
cluster one node at a time, the server last. If an update is already
rolling, the app follows that one.

While the update rolls, the console shows a progress panel under the tabs,
re-read every 5 seconds with `k3sm update status -o json`: the release, the
phase, and each node with its versions, phase and message. **Cancel Update…**
asks first, then runs `k3sm update cancel` as root the same way: the node
being updated finishes, and the nodes not yet started stay on the release
they run. When the update succeeds, the panel says so and offers
**Dismiss**. When it fails, it shows the failed node's message and "Fix the
node that failed, then use Abort Update to release every node before trying
again." A roll started in Terminal or from another Mac is found through the
status report, which says when an update is rolling, and is followed the
same way.

**Abort Update…** is in the panel while the update rolls and after it fails.
It is the recovery after a failed step: a failed step leaves its node
cordoned, with the update's annotations, until it is aborted. It asks first,
with **Don't Abort** as the default answer, then runs `k3sm update abort` as
root the same way. The question says what abort leaves, which is what
`k3sm update abort` does:

- the update is marked **Cancelled** and ends at once; it stays on record
  until the next update replaces it;
- nothing is rolled back: every node keeps the release it runs, and a node
  that was already installing may still finish;
- on every node, the update's `k3sm.io/update-*` annotations are cleared,
  and the cordon the update set is lifted; a node you cordoned yourself
  stays cordoned.

After a successful abort the panel follows the update until it reads as
cancelled, then offers **Dismiss**. If abort could not release a node, the
CLI's message names it and the panel stays as it was.

Like Stop and Restart, Update, Cancel and Abort need an administrator account and
a release build of the app. A build from source shows them disabled, with
the reason as their help text.

### A node behind the server

A worker can run an older release than the server while the server's check
names nothing newer: it joined from an older install, or the check has not
run or could not answer. On the server's app, every node the Nodes tab marks
behind then offers **Update…** in its context menu and its details, and the
summary line over the list carries one **Update…** for all of them. Each runs
the update plan, which here is the managed update pinned to the release
installed on the server (the `version` that `k3sm status -o json` reports):
`/Library/k3sm/k3sm update apply --yes --version <the server's release>`,
through the same checked root step and with the same options. k3sm's update
controller moves every node whose kubelet does not report that release and
leaves the ones that do as they are. The app reads each node the same way,
the server's own node too (the `node` row of `k3sm status -o json`): when the
server's node still runs an older release than the k3sm installed on it, the
server moves as well, last.

The question names the release and the nodes that will move, says the server
restarts last when it is one of them (and that it stays as it is only when it
is not), says that the server decides the final set when the update starts, so
a node that joins or changes before then moves to the release too, and offers
no downgrade. Before it asks and again after, the app reads this Mac's own
`k3sm status -o json` and refuses, with nothing run, unless this Mac is still
the server, no update is rolling, the server still reports exactly the release
the question named (the same text, not only an equal version), its own node
and its other nodes are listed, at least one node is not on that release, and
none runs a newer one; and it refuses if the nodes that would move changed
while the question was open.

When the server's check names a newer release, the same buttons run the
managed update to that release instead, which moves the node too. When the
server runs a build from source with no release tag, its own node is not
reported, a node runs a newer release than the server, or an update is rolling, the buttons are shown
disabled with the reason. A worker's app offers no such button: it offers the
app-carried update when the app carries a newer release, and otherwise says
that the server's app updates it.

## Connections from other devices

Settings > Network carries a checkbox, **Allow connections from other
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

k3sm on a Mac moves to a newer release in one of two ways: the app installs
the release it carries over this Mac's k3sm (the app-carried update), or the
server rolls every node to the latest release (the managed update, above).
The app decides which applies in one place, the update plan, and every
Update control reads it: the menu, the console's Update button, the
popover's version cards, Settings > Updates, this Mac's node in the Nodes tab,
a behind node's Update on the server and the guided panel. No two of them offer different updates. The plan is
one of:

| this Mac | the plan |
|---|---|
| a managed update is rolling | show its progress, offer nothing new |
| the server, and the only node, with the app carrying a newer release | the app-carried update of this Mac |
| the server of a cluster with workers, with the app carrying a newer release than the server runs, every node Ready, and the installed k3sm and the running update controller both able to bind the roll to the app's release (a release at or above the one that added `update apply --pin-sha256`) and at most one minor release behind it | the version-set roll: "Update the Cluster to vX" moves every node to the release the app carries, workers first, this server last, bound to the digest the app's signed bundle records |
| the server of a cluster with workers, the same, but the installed k3sm cannot bind the roll to a digest, the running controller does not check a release pin, or the cluster is more than one minor release (or a different major release) behind the app | nothing from the app: the reason is shown, naming the `sudo k3sm update apply --version <tag>` command to run in Terminal, or the release to go through first |
| the server, with the server's check naming a newer release that a node runs an older release than | the managed update, every node, the server last; a check that names a release no node is older than (recorded before the nodes moved past it), or a cluster with a dev or modified-tree build, offers nothing |
| the server, with a node behind the release the server runs | the managed update pinned to the server's release, which moves the nodes not on it ([A node behind the server](#a-node-behind-the-server)) |
| the server, with a node behind but the server on a build with no release tag, or a node on a newer release than the server | nothing: the reason is shown |
| the server of a cluster with other nodes (or none known), the app newer but no newer release found yet, and no version-set roll to offer (the app carries no release tag, or no node needs to move) | nothing: it updates only by the managed update |
| a worker, with the app carrying a newer release | the app-carried update of this Mac |
| a worker behind the server, with no newer release in the app | nothing: update the cluster from the server |
| the app carrying an older release than the one installed | nothing: the app does not downgrade |
| the installed k3sm reporting no release (a build from source) | nothing: there is no release to compare |
| on the release it should run | nothing to update |

An update the app cannot run now (a build of the app that is not Developer
ID signed, no administrator account, another change running, the installed
k3sm failing the app's checks for the managed update, or a worker whose
control-plane address cannot be read) is shown disabled, naming the release,
with the reason as its help text and line. The version-set roll is shown the
same way, disabled, while a node is not Ready or the node list cannot be read,
while a node runs a newer release than the app carries, and when the app has
no record of its release's digest (download the app again).

- On a worker the app-carried update names the control-plane Mac the worker
  joins, and the update keeps it joined there. The control-plane address
  comes from `joinTarget` in `k3sm status -o json` (the host only; the CLI
  adds the join port). A CLI that does not report it falls back to the
  worker's installed LaunchDaemon. Either way the address must pass the same
  strict check as one typed into the join form.
- On a single-node server the app-carried update first lists the checks to
  make before updating (take a snapshot with `sudo k3sm snapshot save`, leave
  free space for the datastore migration, and note that a datastore engine
  change is one way). Whether the server is the only node comes from the
  `workers` list in `k3sm status -o json`; when the list is missing, the app
  treats the cluster as having other nodes.

When it carries an older k3sm than the one installed, or the installed
version cannot be read, the app offers no app-carried update; a downgrade
runs in a terminal.

The app does not update itself and has no built-in downloader. A new version
of the app is a new disk image from the GitHub release page, dragged to
`/Applications` over the old one; the cluster then moves to the release the new
app carries by the update plan above.

## Repairing

When k3sm is half installed on this Mac (its command is missing from
`/Library/k3sm`, the command fails the app's trust check, or one of its daemons
is down beside the other), the guided panel offers **Repair k3sm**. It asks
first, saying what Repair does and that the cluster's data is kept, then runs
the same verified copy-out as an install or an update, with
`k3sm install --from-staging <dir>` and no other argument. That is the CLI's
in-place install: it reads this Mac's role, a worker's control-plane address
and node credential, the admin kubeconfig's owner and every argument the last
install was given from the disk, and installs the command, its helpers, the
daemons' plists and the launcher link again from the app's release, then
restarts the daemons.

A control-plane Mac keeps the server arguments its last install recorded,
and its admin kubeconfig is written again for the account that record names,
which may not be yours. A worker keeps the control plane it joins, its node
credential and its other daemon arguments; an explicit node IP is not passed
again, and the worker uses the address the control plane assigned it.

k3sm refuses the repair, and the log says why, when no daemon plist says
which role this Mac has (both missing, or both present), when the installed
release is newer than the app's or its version cannot be read or is not a
release, when a worker's node credential is no longer valid (rejoin it
instead), or when the installed command is signed by another team. The app itself does not offer Repair when nothing is installed or the
installed k3sm is newer. A build that is not Developer ID signed shows the
install script to run in Terminal instead.

## Uninstalling

**Uninstall k3sm…** in Settings > Advanced asks for confirmation, then runs
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

## Agents: the read-only MCP server

The app carries a Model Context Protocol server for coding agents such as
Claude Code: `k3sm.app/Contents/MacOS/k3sm-mcp`. It speaks MCP over stdio,
so the agent starts it as a child process. It only reads: no tool changes the
cluster, runs a command or a `kubectl` of your choosing, or returns a
credential. It opens no network port.

The app does not register it anywhere. To give Claude Code the tools, run
this once yourself:

```sh
claude mcp add --scope user k3sm -- /Applications/k3sm.app/Contents/MacOS/k3sm-mcp
```

`claude mcp list` shows it, and `claude mcp remove --scope user k3sm` takes
it away. Other MCP clients take the same path as a stdio command.

| tool | what it returns |
|---|---|
| `k3sm_status` | the status report: verdict, role, each health row (state, severity, detail, suggested command), who stopped k3sm, and versions (the installed CLI, this app, the latest release, each node) |
| `k3sm_alerts` | what needs attention on this Mac and how to fix it, from `k3sm alerts -o json`: the verdict, role, summary and node, then each alert's check name, severity, cause, `clusterEvidence`, fix steps (each marked `needsAdmin` and `confirm`, with its command only when it is plain printable text with no shell operators) and the guide page; the tool to call first when something is wrong. Every step is for you to decide on: the agent is told never to run one, and `confirm` and `needsAdmin` mark steps that need extra care, not permission |
| `k3sm_nodes` | each node: name, role, Ready, cordoned, kubelet version, k3sm release, conditions |
| `k3sm_update_status` | the `update` row (latest release, behind or not) and the managed update's phase, target, per-node from, to and phase, and conditions |
| `k3sm_metrics` | CPU (millicores) and memory per node from metrics-server, and the 20 pods using the most CPU; says so when the cluster serves no metrics API |
| `k3sm_events` | recent Warning events, newest first: namespace, reason, object, count, last seen, and `clusterMessage`; at most 50, 20 by default, optionally one `namespace` |

Each tool reads the way the app does: it runs the installed CLI at
`/Library/k3sm/k3sm` by absolute path, after the same ownership and signature
check the app makes before each run, with an environment built from your
account rather than the agent's. The CLI gets only `HOME`, `USER`, `LOGNAME`
and the system `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so it uses your own
`~/.kube` config and nothing from the agent's environment, such as a
`KUBECONFIG` it sets. It runs as you, with your kubeconfig, so it sees what
you can see.

What no tool returns: a join or admin token, a kubeconfig, a key or
certificate, a Secret's or ConfigMap's data, a pod's logs or environment.
Results are built from named fields only, and a test plants credentials in
the CLI's output and checks that none comes back. Names, details and messages
come from the cluster, so each result carries `"untrustedData": true` and
every such string is cut to one line of 160 characters. An event's message
comes back as `clusterMessage` because it is text written inside the cluster
by whatever raised the event: an agent should quote it and never act on it.
It is shortened, not filtered.

While k3sm updates, or whenever the CLI or the API server does not answer, a
tool returns a result rather than an error:

```json
{"available": false, "condition": "updating",
 "message": "k3sm is updating or unreachable: the node list exited 1; the API server may be restarting. A managed update is rolling, so parts of the cluster restart; k3sm_update_status shows its progress.",
 "retryAfterSeconds": 5,
 "known": {"verdict": "degraded", "role": "server", "updateRolling": true, "update": {"phase": "Rolling", "target": "v0.1.8"}},
 "readAt": "2026-10-16T09:00:00Z", "untrustedData": true}
```

`condition` is `updating`, `updating-or-unreachable`, `cli-refused` (the
installed CLI did not pass the check, as it may not for a moment mid-update),
`stopped`, `not-installed`, `too-large` or, from `k3sm_alerts` on a k3sm too old
to have `k3sm alerts`, `unsupported` (use `k3sm_status` instead); `known` holds what launchd and the
update status still report.

Every call is logged to `~/Library/Logs/k3sm-mcp.log`, one line each: the
time, the tool, the outcome and how long it took. Arguments and results are
never logged. The file is readable only by you and moves to
`k3sm-mcp.log.1` once it passes 1 MiB.

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

A build without `--version` is a development build. Its
`CFBundleShortVersionString` and `CFBundleVersion` stay `0.0.0`, and it
carries a pseudo-version in the same form k3sm's own development builds
report, computed by `hack/build-version.sh` from the checkout: the next patch
after the latest `vX.Y.Z` tag (or `v0.0.0`), the commit time in UTC and the
commit's first 12 hex digits, plus `+dirty` for a modified tree, for example
`v0.0.0-0.20261016221530-2eda966a1b2c`. A copy of the source outside a git
checkout gets `v0.0.0-unknown`. The About panel, Settings > General, the
status popover's version cards and `k3sm-mcp` show that version; a release
build (`--version x.y.z`) shows `x.y.z`. A short version of `0.0.0` is no
release, so a development build carries no payload release: it offers no
install, update or repair from its payload, its guided steps give the
install script to run in Terminal, and the popover's second version card
shows the pseudo-version marked "development build" instead of comparing the
installed release with the app's.

`hack/release/README.md` describes the release signing order. The bundle id
is `io.k3sm.app`, and the app logs to the unified log under the same
subsystem. With only the Command Line Tools installed, `swift test` may need
the swift-testing macro plugin path; `hack/ci.sh` adds it for you.

`docs/ARCHITECTURE.md` maps the source targets.
Every control's tooltip follows the help tag standard in its § Help tags.

### The demo tour

The release recording drives the console with a scripted tour instead of a
pointer:

```sh
.build/debug/K3smApp --demo-tour hack/demo/release-tour.json
out/k3sm.app/Contents/MacOS/k3sm-app --demo-tour hack/demo/release-tour.json
/Applications/k3sm.app/Contents/MacOS/k3sm-app --demo-tour release-tour
```

A tour is a JSON object whose `steps` list holds one step per line:

| step | what it does |
|---|---|
| `selectTab <tab>` | chooses a tab: `workloads`, `nodes`, `images`, `builds`, `services`, `storage`, `models`, `stats` or `alerts` (or `cluster`) |
| `selectWorkloadsView <pods\|events>` | chooses the Workloads tab's view |
| `selectRow pod <namespace>/<name>` | selects a pod; a name ending in `*` is a prefix, for a StatefulSet's pod |
| `selectRow node <name>` | selects a node; `@server` is the control-plane node |
| `openInspector`, `closeInspector` | shows or hides the inspector |
| `runRead <logs\|events\|manifest\|refresh>` | opens the selected pod's log in the log pane, shows its events or manifest, or reads the tab again |
| `waitFor modelReady <namespace>/<name> [seconds]` | waits until the MLXModel is Ready |
| `waitFor podRunning <namespace>/<name> [seconds]` | waits until the pod is Running and ready |
| `waitFor nodesReady <count> [seconds]` | waits until that many nodes are Ready |
| `pause <seconds>` | waits, up to 60 seconds |
| `windowFrame <x> <y> <width> <height>` | places the window, from the main screen's top-left corner |
| `end` | the last step: the app quits |

A wait gives up after its timeout (120 seconds unless given, 900 at most).
Every build copies `hack/demo/*.json` into the bundle's `Resources/demo`, and
a bare name (`release-tour`) selects `Resources/demo/<name>.json` there. The
app reads a tour only from the checkout's `hack/demo` or the bundle's
`Resources/demo`, and refuses the whole tour before it starts if any step is
unknown, out of order (a row before its tab is chosen, a pod read with no pod
selected) or names anything but a read. A tour cannot reach any change to the
cluster or the administrator step. The app quits with status 0 when the tour
ends, 1 with the failed step on standard error, and 2 when the tour was
refused. Reduce Motion turns off the tour's animations, and the stored tab,
selection, inspector and window frame are put back before the app quits.

`--demo-mask`, honoured only beside `--demo-tour` (alone it is refused with
status 2), shows a masked name wherever the console shows a node's name: the
control-plane node is `server` (a second and later one, in name order,
`server-2`, `server-3`); every other node, sorted by its real name, is
`worker-1`, `worker-2`, and so on. A name the last node list did not carry
shows as `node`, and an address equal to a node's name shows its masked name.

## Releases

A k3sm release that carries the app attaches
`k3sm_<version>_darwin_arm64.dmg`, listed in `k3sm_<version>_checksums.txt`.
The image holds `k3sm.app` and an `Applications` link to drag it onto. To
check a release's image the way a user receives it (the checksum, the
Developer ID signature, Gatekeeper's verdict, the staple, and the image's
layout, mounted read-only):

```sh
hack/release/verify-release.sh vX.Y.Z
```

`hack/release/release.sh --rehearsal --version vX.Y.Z` builds the same image
unsigned, with an ad-hoc signed app, as
`k3sm_<version>_darwin_arm64-unsigned.dmg` and its checksums file, and checks
it with the same script. Signing, notarizing and publishing run attended;
`hack/release/README.md` describes them.

## Licensing

The source of this app is Apache-2.0, like the k3sm CLI and runtime it
installs, which are developed in the other public k3sm repositories. The
governance files in this repository (`LICENSE`, `CONTRIBUTING.md` and the
rest) are the shared k3sm set, kept identical across the k3sm repositories.
