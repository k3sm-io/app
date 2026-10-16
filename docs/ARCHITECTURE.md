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
| `RowState`, `RowTone` | R1 | a row's `state` word as the app reads it: healthy words, `needs-admin` (not checked, never a fault), the `update` row's `behind` (attention), `ahead` and `rolling` (both ok), `down` and `unhealthy` (attention; the `dns` row's no answer and bad answer, whose `warn` severity is what degrades the CLI's verdict), other committed words as printed, and any other word unknown; each with its glyph tone; a row also decodes its `wide` map, string values only |
| `StoppedBy` | R1 | the additive `stoppedBy` object (who stopped k3sm, why, when, which phase); a missing or malformed value decodes as nil and never fails the report |
| `NodeRole` | R4 | the closed two-case table from role to daemon label |
| `Flap` | | the wordmark butterfly's wing beat: the hinge angle at each frame of one beat (two strokes toward the viewer, the second lower, ending flat) and the random rest between beats |
| `Waiting`, `WaitingMark`, `WaitingTracker` | console, menu | when the waiting butterfly shows: `shows` puts a tab's mark in its content (first read) or beside its label (a later read) once the read runs past `debounce` (0.3 s), and keeps it `minimumShown` (0.5 s) after, so a fast read never flashes; `menuAnimates` is the same for the status item while the menu is open, ending at once when it closes; `menuFrame` cycles the status item's wing angles 0, 35, 70, 35 degrees every `menuFrameInterval` (0.12 s), pinned to 0 under Reduce Motion; `WaitingTracker` follows one tab's `TabLoad` through `shows` |
| `Tour`, `TourTarget` | | the guided tour's six stops and copy, the keys that step it, the console layout every stop can be seen in, the window-to-view coordinate conversion, where the lit box, the caption card and the guide go (always inside the window), and the guide's wing beat |
| `DockFrame` | | what the Dock shows for each frame: the bundle icon outside the console, a newly rendered frame, or the last frame when a render failed |
| `Reading`, `VisibilityTracker` | R6, R7 | classifies one CLI run; show after one running read, hide after two misses |
| `K3smCLI` | R4, R6 | the absolute CLI path, fixed argument lists (status, version, the managed update's status read and its root-only apply and cancel, and the kubectl calls behind the console: pod list, node list, the build engine's pods and claims, services and ingresses, claims and volumes, MLXModels and the MLX API discovery read, every event, a pod's logs, events and manifest; and `datavol status -o json`, all of them reads; one write, `deletePodArguments`, the inspector's Restart, preceded by `podUIDArguments`, the pod's UID read), the built environment |
| `PollSchedule`, `PollGate` | R6 | 5 s visible, 15 s hidden, 4 s kill deadline; a 10 s deadline for the console's pod and node lists; the full report every 30 s while the console is open; per console tab, Workloads 5 s, Images 15 s, Builds 5 s until the engine is ready and 15 s after, Services, Storage and Models 15 s (`objectsInterval`) (`interval(for:engineReady:)`); the Events view 5 s (`eventsInterval`); the pod list at `backgroundInterval` (30 s) while another tab is selected (`podsInterval(selected:)`), and `panelAge`, the pod read's age the panel shows once it is older than that; `PollGate` keeps one run in flight and coalesces the runs asked for meanwhile into one more |
| `OutputLimit`, `CappedOutput` | R6 | the most standard output one CLI run may produce (1 MiB status, 16 MiB pod and node lists, 64 KiB inspector detail) and the buffer that keeps the first `limit` bytes and records an overflow |
| `StatusDisplay` | R5 | flattens control characters, clips fields, caps rows; `errorText` removes control and format characters from CLI error text and truncates it |
| `SemanticVersion`, `PayloadRelation` | A8, A9 | semver precedence; payload newer, same or older than installed |
| `Workloads`, `Pod`, `PodHealth`, `WorkloadKind` | console | decodes `kubectl get pods -A -o json` (the API's `PodList` or kubectl's `List` of pods) into the rows a workloads view shows: how each pod runs, its health word and severity, owner, ports, requests, the node it is bound to |
| `WorkloadsReading`, `WorkloadsDisplay`, `SelectionChange` | console | one list run classified (listed, CLI error, missing), its error text through `errorText`; the list's strings; the search (the shown name, image or node, each clipped, case ignored); `PodNodeLabel`, the row's node column (a dash before scheduling, "this Mac" for the report's own node, else the clipped node name) and what a poll does to the selection (first pod when none, kept while listed, cleared otherwise) |
| `Nodes`, `ClusterNode` | console | decodes `kubectl get nodes -o json` (`NodeList` or kubectl's `List` of nodes): name (valid names only), Ready, kubelet version, internal IP, the control-plane label, capacity and allocatable cores and memory; any field that is absent, mistyped or an unparseable quantity is unknown, never a failure |
| `NodeListRead` | console | one node-list run decoded once into the panel's nodes and the Images tab's images |
| `ImagesList`, `NodeImage`, `ImagesReading` | console | the Images tab from the node list's `status.images` (each entry's `names` and `sizeBytes`): one image per digest across nodes (a digest is only `sha256:` and 64 lowercase hex; any other name keys its row whole, by a hash when the list cuts it off), its names (tags first) clipped, its size, the nodes holding it; no node carrying the field reads as not reported, never as no images; the search matches a shown name; a read keeps the selected image only while it is listed |
| `BuildEngine`, `BuildEngineState`, `BuildCache` | console | the Builds tab's card from the engine namespace's pods and claims, counting only the engine's own (named `k3sm-builder`, or carrying its name label with k3sm's ownership mark, as k3sm's builder spec sets them): absent with no such pod, ready only when the pod runs and its `buildkitd` container is ready, failed on a failed pod or a waiting reason that does not clear by itself, pending otherwise, each with its clipped reason; only the `buildkitd` container's readiness counts; the cache claim's phase and size |
| `ConsoleSection`, `ConsoleTabs`, `WorkloadsView` | console | the console's tabs (Workloads, Images, Builds, Services, Storage, Models) and their user-defaults keys (`consoleSection`, `consoleQuery.<tab>`, `consoleSelected.<tab>`); a stored tab id this build does not know restores Workloads, and a stored query or row key is clipped when read back; `WorkloadsView`, the Workloads tab's Pods or Events sub-tab (`consoleWorkloadsView`, an unknown id restores Pods) and the events namespace filter (`consoleEventsNamespace`, empty for all) |
| `KubeList`, `KubeListError` | console | what the Services, Storage, Models and Events decoders share: the items of kubectl's `List` (or a typed list) checked against the kinds the tab asked for, any other kind failing the read with its name clipped; tolerant field reads (absent or mistyped is absent; a boolean is never a number); RFC 3339 times with or without fractional seconds; one run as a tab result (a non-zero exit, a malformed list or another kind fails with the app's own sentence) |
| `ServicesList`, `ServiceRow` | console | the Services tab from `kubectl get svc,ingress -A -o json`: each Service's namespace, name, type (ClusterIP when unset), cluster IP and ports as kubectl prints them (`80/TCP`, `80:30080/TCP`), and the hosts of the Ingresses in its namespace whose rules or default backend name it (`*` for a rule with no host); an Ingress is not a row; the search matches a namespace, name or host |
| `StorageList`, `StorageRow`, `DataVolume` | console | the Storage tab from `kubectl get pvc,pv -A -o json`: every claim by namespace and name with its bound volume, its capacity (the claim's, else the volume's, else its request) and phase, then every volume no listed claim holds; the card from `k3sm datavol status -o json`: none (a plain directory), mounted or not mounted, the volume, mount point, quota (none at 0), usage only when k3sm names its source (`statfs` or `apfs`), free space, encryption, and a pre-volume copy left by a migration |
| `ModelsList`, `ModelRow` | console | the Models tab from `kubectl get mlxmodels.mlx.k3sm.io -A -o json`: name, model, phase, ready of asked replicas (1 when unset), endpoint; a failed list is followed by `kubectl api-resources --api-group=mlx.k3sm.io -o name`, and when that answers without naming the resource the tab is unavailable ("the MLX API is not served on this cluster"), never failed; any other failure, including a failed discovery, is failed |
| `EventsList`, `ClusterEvent` | console | the Events view from `kubectl get events -A -o json`: type, reason, message, the object as "Kind name", count, and the time (last timestamp, else the series' last observation, else the event time, else the first timestamp, else creation); newest first, timeless events last, the key between equals; the namespace filter before the cap of 200, so a quiet namespace is never crowded out; the filter's choices keep the chosen namespace |
| `StatusInterconnect`, `InterconnectCard` | console | the full report's additive `interconnect` block, decoded tolerantly (a block that is not an object is nil and never fails the report; `armed` counts only as a JSON true); the panel's card only while it is armed: nodes up of members, segments, attached pods, the out-of-range nodes, and the plaintext warning |
| `TabReader` | console | a tab's read loop, independent of how a read is made: one read at `start()`, then one per its interval until `stop()`; every read, the loop's and each `refresh()`, runs in a task it owns, so `stop()` cancels them all and discards their results (a CLI read kills its child); serial through `PollGate`; the last value kept across a stop and cleared by a failed read |
| `TabLoad`, `TabResult` | console | what a tab is doing with its read (idle, first read, refreshing, loaded at a time, failed, unavailable) and how a read moves it: begin, finish (CLI text cleaned there) and stop (a cancelled read returns to the last value); the footer's "read 40 s ago" |
| `StartTimeBound` | start | `k3sm start --print-time-bound` classified: a whole number of seconds from 1 to 3600 on a 0 exit, else the 600 s fallback with the app's own reason (never CLI text); the start's wait is the bound plus 30 s |
| `LifecycleState` | L6, L9 | running, stopped, not installed or unreadable, from one report; an unknown verdict, state or role word never fails it |
| `StoppedNotice` | L6 | the login-time title, "k3sm is stopped (by you)" or "(auto on <network>)", only for a login launch with a recorded stop; unknown actor and phase words get the plain form |
| `LANAccess`, `LANSetting`, `LANRecordState`, `LANApplied` | LAN access | the additive `network` object, in the full report and the daemons probe: an absent field is on with nothing recorded, an unrecognized value or a field that is not an object is unknown (never off); `recordState` is ok when absent, `unreadable` for a record that cannot be used (the setting is then off), and unknown for any other word (never ok); `appliedReadable: false` says the daemon's applied state exists but the caller cannot read it; the applied report and error when present; `hasLANSwitch` is false for a role with no switch |
| `NodesDisplay`, `NodesView`, `NodeLine`, `VersionAgreement` | console | the panel's nodes block from one report: this Mac first, then `workers` sorted by name with each k3sm release, shown once ("k3sm 0.1.7") when every node runs the same one and per node with "versions differ" or "versions: some unknown" otherwise; an absent list reads as unknown, never none, an empty one as no other nodes; on a worker the server from `joinTarget`; every string clipped |
| `ClusterDisplay`, `ClusterSummary`, `PanelTile`, `PanelMode` | console | the panel's cluster view from the report, the node list and the pod list: the title ("This Mac is the cluster" with no workers, "Cluster" with some, its stats opening with the Mac count, "This Mac" with a note when `workers` is absent, "Joined a cluster" on a worker); nodes ready, running pods, cores and memory requested of the summed allocatable, vm pods; one row per node, this Mac's first, with the requests and the running pods bound to it, and "versions differ" when the rows show their own; `PanelTile`s, the panel's big figures (`tiles(for:)`: the Mac count, or the nodes ready when not all are, the running pods, cores and memory requested of the total; `macTiles`: this Mac's cores, memory and data root, and its pods); `PodRequests`, the This Mac meters' cores and bytes summed over its pods, the bytes saturating at Int64; with an unknown list the stats are the `node` and `workloads` rows as printed; `PanelMode` shows the Cluster/This Mac switch only above one node; every string clipped |
| `PanelLayout`, `PanelContent` | console | the navy panel's width in the console's split view: `widthRange(content:)` runs from `minimum` (250, the panel's width before the split) to what the content could use, the wider of every tile in one row at its natural width and the longest node row (Cluster view rows with both meters on one line, nodes-block lines with their versions), never past `ceiling` (720); widths are estimated from character counts at a conservative per-point advance; `clamp` keeps a width in the range (a non-finite one is the minimum); `columns(width:tiles:)` gives the tile grid every tile in one row once they fit, two columns otherwise; the user-defaults keys `consolePanelWidth` and `consolePanelCollapsed`, read back by `restoreWidth` (clamped to `minimum...ceiling`, the minimum for anything not a number) and `restoreCollapsed` |
| `TabStripLayout` | console | the console strip's width: `minimumWidth(labels:fontSize:buttonWidth:searchWidth:spacing:padding:)` sums the tab labels (each estimated from its character count at `PanelLayout`'s per-point advance, so it errs wide), the gaps between tabs, the spacer at its least, the update button when one is offered (`buttonWidth(title:)`), the search field's minimum, the three icon buttons and the strip's padding; `display` keeps a label whole up to `labelCap` (24) characters and shortens a longer one at its tail; `contentMinimumWidth(strip:inspectorShown:)` and `windowMinimumWidth(strip:inspectorShown:panelCollapsed:)` take the larger of the 1180 pt window floor and the strip plus the panel's minimum, the dividers and the inspector when shown, so the window cannot be narrowed until a label wraps |
| `MenuStatus`, `MenuHealth` | menu | the status item's two status lines: This Mac from the verdict (running ok, degraded degraded, stopped, not installed or a failed read down, no report or an unknown word unknown), Cluster from the `node` row's leading "a/b nodes ready" (all ready ok, some degraded, none or `apiserver unreachable` down, anything else unknown); the title and accessibility text carry the word |
| `UpdateOffer` | update | whether the menu's "Update to <tag>…" item and the console's Update button show: "Updating…", disabled, while the full report's `update` row is `rolling` with a `wide.phase` that is not an end phase (`rowRolling`, read with the same `UpdatePhase` as the update status read); otherwise shown only for the `update` row in `behind` with a latest tag (`wide.latest`, else the tag the detail names; it must parse as a release version, ASCII, at most 40 characters); `ok`, `ahead`, `unknown` and no row show nothing; "Updating…", disabled, while `UpdateProgress` says an update is under way; shown disabled with `developerBuildReason` on a developer build, or with the caller's blocked reason; not repeated for the release a roll was seen to finish |
| `UpdateStatus`, `UpdatePhase`, `UpdateNode`, `UpdateCondition` | update | decodes `k3sm update status -o json`: the name (absent with no Update, whose fixed answer has an empty phase and version), the display phase (Pending, Rolling, Succeeded, Failed, Cancelled; empty before the controller reconciles, read as pending; another word is kept), the version, `resolved`, each node, the conditions and `finished`, the controller's end predicate: a roll ends only on `finished`, as its end phase, else the Progressing reason, else failed; only the phase is required, any other missing or mistyped field reads as empty |
| `UpdateProgress`, `UpdatePanel`, `UpdateNodeLine`, `UpdateApplyResult` | update | the app's view of the roll: idle, applying (the root step), rolling, then succeeded, failed or cancelled until dismissed; an apply that started a roll or found one already rolling follows it; from idle an unfinished read is followed and a finished one is not brought up; no Update at all (an abort removed it) leaves nothing to follow; `readsStatus` (always while following, while idle with the offer on screen or the row saying it rolls); the panel's clipped title, detail, the failed remedy, one line per node, Cancel while it rolls and Dismiss after |
| `K3smLogs` | L6 | the fixed log paths the menu opens: the node daemon's for the role, netd's, the copy-out log |
| `PodAction`, `PodActions`, `PodActionRequest`, `PodActionConfirmation`, `PodActionRun`, `PodActionReport` | console | the console's writes: which actions a pod offers (Restart only for a pod whose owner kind, parsed from `Pod.owner`, is ReplicaSet, StatefulSet or DaemonSet, the controllers that recreate a deleted pod; nothing for a name `ResourceName` refuses), the request fixed at the click (the names, UID and owner of the pod as listed then, its argument lists from `K3smCLI`; a pod listed without a UID offers nothing), the confirmation's wording (Restart names `namespace/pod` and says the owner recreates it; destructive), `verify`, the UID read before the action (the same UID runs it; another UID or a gone pod is refused, "the pod changed since you clicked; nothing was deleted"; any other outcome deletes nothing), and the one-line report of a run (accepted, "kubectl said:" and kubectl's own text through `errorText`, no answer, not installed, or the trust check's refusal) |
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
| `LifecycleVerb`, `LifecycleScriptBuilder`, `LifecycleExit` | L9 | the closed verb set (stop, start, restart, the two LAN access verbs, and the managed update's apply and cancel) and its separate root script: no staging and no lock; `env -i`, `cd /`; refuses unless `/Library/k3sm/k3sm` and every directory above it are root-owned, not group or other writable, not symlinks and carry no ACL, and the binary passes `codesign --verify -R` against the compiled Team ID; then runs the verb as a literal. `arguments(for:)` is the one definition of its argv |
| `LifecyclePrecondition`, `LifecycleConfirmation`, `StopWarning` | L5, L9 | a live state that differs from the one the user acted on refuses; the confirmation names the verb; Stop warns on a server with joined nodes, and when the `workers` list is unknown |
| `LifecycleDriver` | L6, L9 | one verb from click to outcome: live read, confirmation, a second live read, then a fresh administrator prompt; Start alone first reads the CLI's time bound and waits at most that plus the margin (`Deadline.race`), and re-runs a still-cordoned start once with no fresh status check |
| `StartRetry`, `Deadline` | start | the start's next step from one run: exit 1 with `k3sm: node is still cordoned` on standard error re-runs once, then shows the not-schedulable state with the `sudo k3sm start` remedy; any other exit is the outcome; the wait that gives up on a root step without killing it (an administrator prompt cannot be cancelled) |
| `LifecycleOutcome` | L1, L9 | one sentence per outcome; a partial stop's exit code names what was left behind |
| `InstalledCLITrust`, `LifecycleSupport`, `TrustedCLI` | L6, L9 | the app's own ownership, ACL and signature check of the installed CLI, made again immediately before every unprivileged run from the window, the lifecycle flow and the menu's Terminal actions (never a cached verdict); feature detection of `k3sm stop` by version, run only through that check |
| `LANToggle`, `LANConfirmationText`, `LANPrecondition`, `LANDriver`, `LANOutcome` | LAN access | the tri-state checkbox (disabled with the reason on a failed, stale or untrusted read or an unknown value; notes for a missing record, a recorded and applied mismatch, a refused change; the indicator while on); the question before turning access on, from the report's `covers` and `alwaysOn`, Cancel the default; one LAN verb from click to outcome: live read, the question (on only), a second live read, the administrator prompt, then a read that confirms the value |
| `UpdateDriver`, `UpdatePrecondition`, `UpdateConfirmationText` | update | the managed update from click to outcome: the apply reads the status live and refuses unless its `update` row still offers the release chosen, asks (naming it), reads and checks again, then runs `update apply --yes` through the lifecycle script; the cancel asks ("Keep Updating" answers no), then runs `update cancel`; `classify` reads the run: exit 0 started the roll, exit 1 with the CLI's refusal for an unfinished Update ("…; follow it with `k3sm update status --watch`…") follows that roll, anything else started nothing and shows the CLI's text through `errorText` |
| `BugReport`, `StatusCommand`, `CommandFile` | L6 | the static Terminal `.command` files behind Write a Bug Report and Open Status, written into a fresh 0700 directory; the collector reads an allowlist through a redaction pass |
| `PrivilegedRunner`, `PrivilegedRun`, `PrivilegedAvailability` | A5, A15, R8 | the path to root (a runner may also return the step's error output, which the app shows only through `errorText`); enables privileged actions only with a Team ID, a valid self-signature and an admin user |

## K3smApp

| file | serves | what it does |
|---|---|---|
| `AppDelegate` | A15 | wiring; login-item launch shows only the status item; reopen shows the window; activity assertion against App Nap; pauses polling off the active console session |
| `StatusPoller`, `CLIProcess` | R6 | serial probe runs with a scrubbed environment; the child is killed (SIGKILL) at the deadline, once its output passes the run's `OutputLimit` (`.truncated`, the first bytes kept), or when the awaiting task is cancelled; the signal reaches the direct child only, so a `kubectl` the wrapper forked may outlive it; standard error is discarded unless the caller passes `keepErrors` (the console's actions), which puts it on the output pipe under the same limit |
| `StatusItemController` | R7, L6 | inserts and removes the `NSStatusItem`; logs `status item: visible` only when on screen; respects a user removal; the menu: the Cluster and This Mac status lines (`MenuStatus`, a coloured circle and the word; read from the full report on open, This Mac also from each probe), then the update item as `UpdateOffer` decides (disabled ones carry the reason as their tooltip; on open, with an update offered, one update status read finds a roll started in Terminal), then Stop and Restart (shown only when lifecycle support is available, never disabled-but-visible), Open Status, Open Logs, Write a Bug Report, Dashboard, Quit; the icon carries the LAN dot, following each daemons probe; from `menuWillOpen` until the full read ends, a common-mode timer (it fires while the menu tracks) swaps the icon to `ButterflyImage.statusIcon` at the `Waiting.menuFrame` wing angle while `Waiting.menuAnimates` holds, the badges drawn on every frame, and restores the still icon when the read ends or `menuDidClose` |
| `FlapModel` | | plays a `Flap` beat after each rest while the console is up (started and stopped by the window controller with the console's polls); skips the beat under Reduce Motion and while the window is miniaturized, ordered out or the app hidden (`Flap.plays`, the window state read when the beat comes due); `poke` plays one at once when the pointer enters the mark, by `Flap.hoverStartsBeat` (not during a beat, not within `Flap.hoverCooldown` of the last beat's end, and only when `Flap.plays` allows one); `FlappingButterfly` in `MacPanel` turns each half of the mark about the centre line by its angle |
| `WaitingModel`, `WaitingButterfly`, `TabWaitingMark` | console | each tab's waiting mark: `AppModel` hands it each tab's `TabLoad` (the pod list, the shared node list for Images, the engine read) and forwards their changes; a `WaitingTracker` per tab decides the mark, re-checked on a 50 ms tick only while a tab reads or shows its mark; a second `FlapModel` beats continuously (`startContinuous`, flat under Reduce Motion) while any mark is shown; the 14 pt mark is an overlay centred on the tab's content and the 10 pt one an overlay just after the tab's label in `TabStrip`, so neither moves or replaces anything |
| `TourModel`, `TourOverlay` | | the tour's state (no view state): builds its stops when it starts from `ClusterDisplay.shape`, so the first one says what the panel's heading says; applies `Tour.shown` and restores the user's layout on the last stop, Escape, a click outside, closing the window or quitting (the layout settings are written while the tour runs, so an app killed mid-tour, not quit, opens next time on the tour's layout); measures each stop in window coordinates through a `TourReporter` view behind it, since the panel and the content are hosted separately and a preference cannot cross them; scrolls the panel to its stops; the overlay dims, lights the stop, places the card, and flies the wordmark's mark between stops on `Tour.guideAngle` |
| `DockIcon` | | the Dock image while the console is on screen: a navy tile of its own (Palette colours) that stays still, with the mark on it flapping at `FlapModel`'s angle; `MainWindowController` follows the screen and the angle through `DockFrame`, keeps the bundle icon on every other screen, and restores it on close after cancelling the subscription |
| `MenuActions` | L6 | logs through `NSWorkspace` on fixed paths; the status and bug report `.command` files opened in Terminal; never a shell from the app |
| `StoppedNotifier` | L6 | the login-time stopped notification and its Start action |
| `MainWindowController`, `Views`, `AppModel` | A9, A15, A16, L6 | SwiftUI in an `NSWindow`; first run (start or join) under the standard title bar; once installed, the console under a transparent full-size title bar (`setChrome`), with the status panel as a popover from its info button and `Settings…`: status with `stoppedBy`, Stop, Restart and Start (or the note when the installed k3sm lacks them), the LAN access checkbox, Update (by `UpdatePolicy`) and Uninstall (with the purge checkbox); `.regular` while open, `.accessory` after; tails the copy-out log |
| `ConsoleView`, `ConsoleSplit`, `TabStrip`, `MacPanel`, `WorkloadsTab`, `WorkloadsSection`, `EventsSection`, `ImagesSection`, `BuildsSection`, `ServicesSection`, `StorageSection`, `ModelsSection`, `Inspector`, `Palette` | console | the console: `ConsoleSplit` (an `NSSplitViewController` behind an `NSViewControllerRepresentable`, since `HSplitView` has no collapse or restored width) puts `MacPanel` and the content (`ConsoleContent`: the strip, the tab, the inspector) on either side of a thin divider; the panel item's minimum and maximum are `PanelLayout.widthRange` of what the panel shows, the content item's minimum is the window minimum less the panel's (`TabStripLayout.contentMinimumWidth`), the panel holds its width while the window resizes, a divider drag records the width on `AppModel.consolePanelWidth` (a window resize does not), and a double-click on the divider or View > Hide Panel collapses it through `AppModel.consolePanelCollapsed`; the window's minimum width is the panel's minimum (nothing while collapsed) plus the content's; `ConsoleSection` names the middle column's tabs and drives `TabStrip` (the navy panel's tab look on the light surface: text and a 2 pt underline on the strip's hairline; each label fixed-size on one line, `TabStripLayout.display`); the strip shows the selected tab's search field; `MacPanel` is the Cluster or This Mac view chosen by `PanelMode`, scrolled, its figures as `PanelTile`s in a grid of `PanelLayout.columns` and one compact row per node, its meters beside the name when the panel is wide enough; `WorkloadsSection` the pods by namespace, each row naming the node it runs on (`PodNodeLabel`), column widths from one table; `ImagesSection` the images from the shared node list, or the one line saying no node reports them; `BuildsSection` the build engine card and the line saying no build history is recorded; `WorkloadsTab` the Pods or Events switch over `WorkloadsSection` or `EventsSection` (the events with a namespace menu); `ServicesSection`, `StorageSection` (the data volume card above the claims) and `ModelsSection` the decoded rows, each tab's search through its `visible`; `MacPanel` adds the Interconnect block from `InterconnectCard`; each tab's footer says how old its read is; `Inspector` the selected pod's facts, its `PodActions` buttons behind a `confirmationDialog` bound to `WorkloadsModel.pendingAction`, the last action's report line, and its logs, events or manifest; every CLI string verbatim and clipped; `Palette` holds every colour, named by role; the console follows the system appearance, its text colours at least 4.5:1 on the window background in both, and only the navy Mac panel keeps fixed colours |
| `TabLoader`, `TabLoading`, `TabLoaderGroup` | console | a `TabReader` the views observe, whose read runs a fixed argument list through `CLIProcess` with `listDeadline` and `OutputLimit.list` and decodes it with a `K3smStatus` decoder (the Models read is two such runs, the discovery only after a failed list); `TabLoaderGroup` starts, stops and refreshes Storage's two loaders together; `AppModel` keeps one per tab, created on the tab's first selection, starts the selected one while the console is on screen and stops it when the tab is left or the window goes; the pod list is created and started with the console and keeps reading at the background cadence off its tab, for the panel; the selected tab is kept as `consoleSection`; the Events loader runs only while the console is on screen with Workloads selected and its Events sub-tab chosen |
| `WorkloadsModel` | console | the Workloads tab's pod list (its `TabLoader`), the shared node list (one read for the panel's nodes and the Images tab, at the selected tab's cadence, while the console is on screen), search and selection (kept per tab in the user defaults) and detail, applying the `WorkloadsDisplay` decisions; detail through the fixed argument lists; the pod actions: `ask` fixes a `PodActionRequest` for the confirmation, `runPendingAction` reads the pod's UID and, only when `verify` passes, runs the action, each through `TrustedCLI` (a fresh trust check) and `CLIProcess` with `listDeadline`, `OutputLimit.status` and `keepErrors`, keeps the report for that pod, and reads the pod list again |
| `UpdateProgressPanel` | update | the managed update's progress under the console strip, rendering `UpdatePanel`, with Cancel Update… and Dismiss; the Update button beside the search field renders `UpdateOffer`; `AppModel` runs the update status read (a `TabLoader` at `PollSchedule.updateStatusInterval`) while `UpdateProgress.readsStatus` says so, whether or not the window is open while a roll is followed, and the apply and cancel through `UpdateDriver` |
| `HostFacts`, `HostLoad` | console | the machine (model from the device tree, chip, cores, memory; read once) and what moves (memory in use from Mach host statistics, the data root's volume; read per poll); nothing touches the cluster |
| `MainMenu` | | the menu bar while the window is open: `Settings…` opens the status panel, `Refresh`, `Hide Panel`/`Show Panel` (Command-Option-L, titled by the collapsed state and offered only on the console), Edit for the search field, Window; the status item keeps its own menu; Help with Take the Tour, offered only on the console |
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
| `acceptance/B571.sh` | | the Start flow against a fake `k3sm` first on PATH (bound 1 s, a first start that runs past it and exits still cordoned, a second that succeeds): the bound read, the retrying and final texts, exactly two starts; then the start bound and retry suites |
| `ci.sh` | | the gate: build, tests, bundle builds, shellcheck, payload and refusal checks, headers, workflow dormancy, fixture drift (the status fixtures against k3sm's `pkg/status/testdata`, the datavol fixtures against its `cmd/k3sm/testdata`, byte for byte) |

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
| allow connections from other devices | `network lan on` |
| stop allowing them | `network lan off` |
| start the managed update | `update apply --yes` |
| cancel it | `update cancel` |

The two LAN access argv are compile-time constants, pinned against `k3sm`
`cmd/k3sm/network.go`; nothing decoded from the status reaches them.

The lifecycle script's own refusals exit 100 (an unsafe path) and 101 (the
signature), above the CLI's codes (0 to 3, and 33 to 95 for a partial stop;
`network lan` adds 4, a failed change whose previous setting could not be
restored).

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

- The `update` row says `rolling` while a managed update is in progress, but
  the server refreshes it only every 30 seconds and drops it after five
  minutes without a refresh. The app also knows of a roll from its own
  apply, and follows it with `k3sm update status -o json`, which it reads
  while it follows one, and while idle when the row says one is rolling or,
  with the window open, when an update is offered (and once each time the
  menu opens with either).
- The `update` row is recomputed only at the next check, so it can still name
  a release a roll has just installed. The app does not offer that release
  again after it has seen the roll succeed.
- Whether the cluster serves the MLX API is not in any report. The Models
  tab asks discovery (`kubectl api-resources`) after a failed list, rather
  than reading kubectl's error text, which the app does not capture.

- `network.applied` is present only when the caller can read it (root). The
  app runs the status as the user, so k3sm sets `appliedReadable: false` and
  the app says that an administrator can see what is served with `sudo k3sm
  network lan status`. A mismatch between the recorded and the applied setting,
  or a refused change, shows only when the report is readable.

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
