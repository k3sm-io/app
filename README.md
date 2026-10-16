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

Each time the window opens, and on the console's report loop, the app checks
k3sm on this Mac: whether `/Library/k3sm` and its command exist, whether the
command passes the app's trust check, what `k3sm status` reports, and whether
the installed release matches the one the app carries. The result is one of
not installed, stopped, partly running (netd or the node daemon down while the
other runs), command missing, command not trusted, status unreadable, version
mismatch (behind or ahead of the app) or healthy. Only "not installed" opens the
first run; every other state opens the console, whose status names the state
in one line.

With nothing installed on the Mac, the window asks one question:

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
  core grid and unified memory meter show both what this Mac's pods request
  and what is used: the use fills (the cores the node used, and the pods'
  memory), the request is an outline over it, so each stays readable when it
  passes the other, and the meter's dim part is what macOS and other apps
  use. The legends give the figures ("Used 1.80 cores", "Requested 0.60
  cores"), and the request tiles show the use beside them ("of 10 · 1.80
  used"). Without a usage sample the charts show the requests alone and say
  so; use is never shown as zero for want of a sample. When
  every node runs the same k3sm release, both views name it once ("k3sm
  0.1.7"); otherwise each node shows its own version and the panel says
  "versions differ", or "versions: some unknown" when a node's version cannot
  be read. The app remembers the choice; a single-node cluster always shows
  This Mac. The panel scrolls in a short window. While the window is open the
  node list and the selected tab's list are re-read every 5 seconds (Nodes
  included; every 15
  seconds on Images, Services, Storage and Models, and on Builds once the
  build engine is ready) and the
  status report is re-read every 30 seconds, so the panel follows nodes as
  they join and leave. The pod list keeps being read every 30 seconds while
  another tab is selected, so the panel's pod figures stay current; the panel
  shows their age beside its state when that read is late. No other tab is
  read while it is not selected; when you come back to it, it shows what it
  last read and how long ago. When the cluster has an interconnect (the
  cable network between Macs) and an administrator has armed it, the panel
  shows an Interconnect block: how many cabled nodes are up, the segments,
  how many pods hold an interconnect address, the nodes past its address
  range, and that pod traffic on the cable is not encrypted.
- **Live load** comes from metrics-server when the cluster runs it. While
  the window is on screen the app reads `k3sm kubectl get --raw` of the
  `metrics.k8s.io` node and pod lists at most every 15 seconds, one read at
  a time, and keeps the last sample. Each node in the Cluster view, and this
  Mac's node in the This Mac view, gets CPU and memory bars with the amount
  used of what the node offers and the percentage, beside a small line of the
  last few CPU samples; the pod details add the pod's CPU used (and its share
  of the request), memory used and the sample's age. A line under the bars
  says how old the sample is ("12 s ago"). A node or pod metrics-server has
  no sample for reads "no metrics yet", never zero. When the cluster serves
  no metrics API, or its APIService is not available, the bars are hidden
  and the line says why (from the APIService's condition, or the read's
  error); the app then looks again every minute. Nothing is stored.
- The **Update** button appears at the top right of the console, beside the
  search field, when k3sm reports a newer release for the cluster. It runs
  the cluster's managed update (see [The managed update](#the-managed-update)).
- The **info button** opens the status popover: the state of this Mac (and
  who stopped k3sm, when it is stopped), only the checks that need
  attention, or "All N checks are ok." when none does, the installed
  version with an **Update** button while k3sm reports a newer release, and
  Stop, Restart or Start. **All checks**, closed at first, holds every check
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
    for it. A dev build, a pseudo-version or a build from a modified tree is
    unknown, as in `k3sm status`. A line over the list sums it up ("2 nodes
    on 0.1.8", "1 node behind 0.1.8", "Updating to 0.1.8 · 1 of 3 nodes on
    it"), and the node inspector shows the node's state with both versions
    and the latest release. It renders the same node list the panel and
    Images read, so it makes no read of its own.
  - **Images**: the images the nodes report holding, one row per digest;
    until a node reports them the tab says so.
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

  The tabs only read. The changes the console makes are a pod's
  **Restart** and **Delete**, a node's **Cordon** and **Uncordon**, a
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
  or that was listed without a UID, offers neither. Draining a node is not
  in the app.
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
- Each **build** in the history offers, from its row's Control-click menu or
  its details: **Show Log**, a sheet with the build's stored log
  (`k3sm build logs <id>`, following it with `-f` while the build runs; the
  sheet shows at most 1 MiB, and closing it stops the read); **Cancel
  Build** while it runs (`k3sm build cancel <id>`); and **Delete Record**
  once it has finished (`k3sm build rm <id>`, which removes the record and
  its log, not the image), which is also on the Delete key. Both ask first,
  and run as your own account. A build's id reaches a command only as the
  twelve hexadecimal characters `k3sm build ls` gives it; a row with any
  other id offers no action.
- The **details** on the right follow the tab. Click a row on any tab (on
  Builds, the engine card or a build) and its details show there: a pod's facts
  and its logs, events or manifest; a node's role, readiness, whether it
  takes new pods, kubelet and k3sm versions, addresses, capacity and
  allocatable, its live CPU and memory bars with the last few CPU samples and
  the sample's age ("no metrics yet" before metrics-server has sampled it),
  its conditions (Ready first) with how long ago each last changed and why,
  its taints, and the pods on it that have not finished with what each uses
  now; an image's reference, digest, size, the
  nodes holding it and the pods using it; the build engine's state, pod,
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
  flies in from the upper left, beating fast, and settles on the letter with
  its wings folded upright, opening them slowly now and then; when the read
  is done it opens its wings and flies off to the upper right, fading out.
  On the tab you are looking at, every refresh lands the butterfly on the
  name and keeps it there at least 0.8 seconds, however quick the read. A
  first read that ends within 0.3 seconds shows nothing, and once the big
  butterfly appears it stays at least half a second, so a quick read never
  flashes. With Reduce Motion on, both are shown still and the perched one
  appears and goes without flying.
- The **details button**, beside the info button above the list, collapses
  the details on the right and shows them again; Command-Option-I does the same, and the app remembers the choice.
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
- The **tab names** above the list stay whole on one line. The window goes
  no narrower than the row above the list needs for every tab name, the
  Update button while one is offered, the search field at its narrowest and
  the buttons beside it; only a tab name longer than 24 characters would be
  shortened, at its end. With the panel and the details shown that is at
  most 1440 points, so the window fits the narrowest Mac laptop display.
- The **window** reopens where you left it, at its size and on its display, after a relaunch too; if that display is gone or the window would sit off the screen, it is moved onto the main display, never smaller than its minimum.

The app reads state only from `k3sm status -o json`, the machine interface the
k3sm CLI documents. It runs `/Library/k3sm/k3sm` by absolute path with an
environment it builds itself. A newer CLI may print status words this app does
not know; they are shown as printed and never stop the app from reading the
rest.

The app runs as you, not as root, so some checks are ones only an
administrator can run (the runtime daemon's owner-only socket, for one). The
CLI reports those rows as `needs-admin`, and the app shows them with a grey
glyph and "needs an administrator; run sudo k3sm status". Nothing was checked
and nothing is wrong, so these rows never count against the verdict; the
status line says how many there are ("1 check needs an administrator"). Run
`sudo k3sm status` in a terminal to see them checked.

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

- **Update to v0.1.8…** (naming the release k3sm found) appears when k3sm
  reports a newer release for the cluster, and runs the managed update
  (below). While an update rolls it reads **Updating…** and cannot be
  clicked.
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
- **Settings…** (Command-comma), **Dashboard** and **Quit k3sm**.

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
- **Animate the Dock icon while the window is open** beats the wings of the
  mark on the Dock icon. With Reduce Motion on in Accessibility settings the
  icon is always still, and the checkbox says so.
- **Take the Tour** brings the window forward and starts the tour, once k3sm
  is installed.
- **Reset Window Layout…** asks, then puts the console's left panel back to
  its first width and view, shown, and shows the details column. Tabs,
  searches and selections stay as they are.

The **Network** pane holds **Allow connections from other devices** (see
[Connections from other devices](#connections-from-other-devices)), with
the setting now, the listeners it controls, those it never closes, and the
address this node answers on once the console has read the node list.
Opening the pane reads the status again. A Mac with no k3sm node says it has
no network settings.

The **Advanced** pane:

- **Write a Bug Report…**, **Live Status** and **Open Logs**, the same
  actions as in the status item's menu.
- **Uninstall k3sm…**, with **Also delete k3sm's data** (see
  [Uninstalling](#uninstalling)).
- **Reset to Defaults…** asks, then puts every preference above back to its
  first value, and closes the status popover's All checks. Open at login,
  the window layout and k3sm itself stay as they are.

## The managed update

A server checks for a new k3sm release at most once an hour (`sudo k3sm
update check` checks now), and its status report says when a node runs an
older release than the latest. The app reads only that report: it never
contacts the network itself. While the report names a newer release, the
menu offers **Update to <release>…** and the console shows the **Update**
button. When every node runs the latest release, runs a newer one, or the
check has no answer, neither appears.

Update asks first, naming the release, then shows the standard
administrator prompt and runs `/Library/k3sm/k3sm update apply --yes`
through the same checked root step as Stop and Start. k3sm then updates the
cluster one node at a time, the server last. If an update is already
rolling, the app follows that one.

While the update rolls, the console shows a progress panel under the tabs,
re-read every 5 seconds with `k3sm update status -o json`: the release, the
phase, and each node with its versions, phase and message. **Cancel Update…**
asks first, then runs `k3sm update cancel` as root the same way. When the
update succeeds, the panel says so and offers **Dismiss**. When it fails, it
shows the failed node's message and "Run k3sm update abort in Terminal, then
try again." A roll started in Terminal or from another Mac is found through
the status report, which says when an update is rolling, and is followed the
same way.

Like Stop and Restart, Update and Cancel need an administrator account and
a release build of the app. A build from source shows them disabled, with
the reason as their help text.

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
Every control's tooltip follows the help tag standard in its § Help tags.

## Licensing

The source of this app is Apache-2.0, like the k3sm CLI and runtime it
installs, which are developed in the other public k3sm repositories. The
governance files in this repository (`LICENSE`, `CONTRIBUTING.md` and the
rest) are the shared k3sm set, kept identical across the k3sm repositories.
