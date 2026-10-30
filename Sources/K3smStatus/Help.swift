/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import Foundation

/// HelpTag is one help tag (the tooltip macOS shows after the pointer rests
/// on a control): its text, the control it belongs to, and the label that
/// control shows, so the standard can check the tag never repeats it.
public struct HelpTag: Equatable, Sendable {
    /// The control, as a reader of the code finds it ("console strip: gear").
    public let control: String
    /// The control's visible label, nil for an icon-only control or a value.
    public let label: String?
    /// What the help tag says.
    public let text: String

    public init(_ text: String, control: String, label: String? = nil) {
        self.text = text
        self.control = control
        self.label = label
    }
}

/// Help is every help tag the app shows, grouped by the area of the app it
/// belongs to. Views attach a tag with `.help(Help.<area>.<name>)` and set an
/// AppKit item's `toolTip` from `text`; no help string is written anywhere
/// else (`hack/verify-help.sh` fails the gate on one). Each area lists its
/// tags in `all`, and `Help.all` is every tag, which `HelpStandard` checks.
///
/// The standard, after Apple's guidance for help tags: one short sentence
/// (`HelpStandard.maxWords` words at most), sentence case, no closing period
/// unless there are two sentences; an action starts with a verb, a value
/// names its unit or source; a keyboard shortcut follows in parentheses; a
/// tag never repeats its label, never states the obvious and never carries
/// status or errors, which the view shows. The two kinds of dynamic text a
/// tag may carry are a disabled control's reason and the whole text of a
/// line the view truncates, both built here.
public enum Help {
    /// Every tag in the catalog, area by area.
    public static var all: [HelpTag] {
        Strip.all + Workloads.all + Nodes.all + Images.all + Builds.all + Services.all + Storage.all + Models.all + Stats.all + Alerts.all
            + Inspector.all + LogPane.all + Actions.all + Status.all + Panel.all + Popover.all + Guided.all + FirstRun.all + Update.all
            + Tour.all + General.all + Network.all + InstallSettings.all + Updates.all + Advanced.all + SettingsWindow.all + Menus.all + Columns.all
    }

    // MARK: Table columns

    /// The drag handle between two columns of every tab's table header.
    public enum Columns {
        public static let handle = HelpTag("Drag to resize the column; double-click to reset its width",
                                           control: "table header: column edge")

        public static let all = [handle]
    }

    // MARK: Console strip

    /// The row above the console's tab: the tabs, the
    /// details, tour, info and Settings buttons.
    public enum Strip {
        /// The details button while the inspector is collapsed.
        public static let showDetails = HelpTag("Show the details column (Command-Option-I)",
                                                control: "console strip: details button")
        /// The details button while the inspector is shown.
        public static let hideDetails = HelpTag("Hide the details column (Command-Option-I)",
                                                control: "console strip: details button")
        /// The question-mark button.
        public static let tour = HelpTag("Walk through the console, one stop at a time",
                                         control: "console strip: tour button")
        /// The info button, which opens the status popover.
        public static let status = HelpTag("Show k3sm's state on this Mac, with start, stop and update",
                                           control: "console strip: info button")
        /// The gear, which opens the Settings window.
        public static let settings = HelpTag("Open the Settings window (Command-Comma)",
                                             control: "console strip: gear button")
        /// The update button's tag when an update is offered with no tag to name.
        public static let updateAny = HelpTag("Update every node to the newest k3sm release",
                                              control: "alerts: update card button", label: "Update")

        /// The details button's tag.
        public static func details(shown: Bool) -> HelpTag { shown ? hideDetails : showDetails }

        /// One tab of the strip.
        public static func tab(_ section: ConsoleSection) -> HelpTag {
            let text: String
            switch section {
            case .cluster: text = "Show what the status found wrong and how to fix it"
            case .workloads: text = "Show the pods and the cluster's events"
            case .nodes: text = "Show the nodes, their load and their conditions"
            case .images: text = "Show the images in the cluster's registry"
            case .builds: text = "Show the build engine and the build history"
            case .services: text = "Show the services and the hosts routed to them"
            case .storage: text = "Show the data volume and the volume claims"
            case .models: text = "Show the MLX models the cluster serves"
            case .stats: text = "Chart the load, pods, restarts, images, storage and updates"
            }
            return HelpTag(text, control: "console strip: \(section.title.lowercased()) tab", label: section.title)
        }

        /// The app-carried update's wording without a version, kept in the catalog
        /// so the standard checks it; the update button itself shows `update(_:)`'s
        /// `.payload` text.
        public static let updateThisMac = HelpTag("Install the release this app carries on this Mac, as an administrator",
                                                  control: "alerts: update card button, this Mac", label: "Update")

        /// Every Update control's tag (the Alerts tab's update card, the popover's
        /// version row, the status item's menu, and through them the node
        /// inspector, the Updates pane and the guided panel), from the one
        /// `UpdatePlan`: why it is disabled, or what its path does.
        public static func update(_ plan: UpdatePlan) -> String {
            if let reason = plan.disabledReason { return reason }
            switch plan.path {
            case .managed(let tag)?:
                return "Update every node to k3sm \(StatusDisplay.clip(tag)), the server last"
            case .payload(let version)?:
                return "Install k3sm \(version) from this app on this Mac, as an administrator"
            case .catchUp(let tag, _)?:
                return "Move the nodes behind to the server's k3sm \(StatusDisplay.clip(tag))"
            case .bundled(let tag)?:
                return "Update every node to k3sm \(StatusDisplay.clip(tag)), this app's release, the server last"
            case nil:
                return updateAny.text
            }
        }

        public static var all: [HelpTag] {
            [showDetails, hideDetails, tour, status, settings, updateAny, updateThisMac] + ConsoleSection.allCases.map(tab)
        }
    }

    // MARK: Workloads tab

    /// The Workloads tab: its Pods and Events switch, the namespace menu and
    /// the pod list's columns.
    public enum Workloads {
        /// The Pods and Events segmented switch (its label is hidden).
        public static let view = HelpTag("Switch between the pods and the cluster's events",
                                         control: "workloads: view switch", label: "View")
        /// The Events view's namespace menu.
        public static let namespace = HelpTag("Show the events of one namespace, or of all",
                                              control: "workloads: events namespace menu", label: "Namespace")
        /// The pod list's Cores column header.
        public static let cores = HelpTag("CPU the pod requests, in cores",
                                          control: "workloads: Cores column", label: "Cores")
        /// The pod list's Memory column header.
        public static let memory = HelpTag("Memory the pod requests",
                                           control: "workloads: Memory column", label: "Memory")
        /// The pod list's Runs as column header.
        public static let runsAs = HelpTag("A native macOS process, or a Linux VM",
                                           control: "workloads: Runs as column", label: "Runs as")
        /// The Events list's Age column header.
        public static let eventAge = HelpTag("Time since the event last happened",
                                             control: "workloads: events Age column", label: "Age")

        /// The paused badge on a paused controller's row and on its pods' rows.
        public static let paused = HelpTag("Its controller is scaled to zero until you resume it",
                                           control: "workloads: paused badge", label: "paused")

        /// The stale badge on a controller whose record is left from a Pause that did not scale.
        public static let stale = HelpTag("An earlier pause recorded the count but never scaled it to zero",
                                          control: "workloads: stale badge", label: "stale")

        public static var all: [HelpTag] { [view, namespace, cores, memory, runsAs, eventAge, paused, stale] }
    }

    // MARK: Nodes tab

    /// The Nodes tab's columns and the node inspector's live load.
    public enum Nodes {
        /// The Status column header.
        public static let status = HelpTag("Whether the kubelet reports Ready, and whether new pods may land",
                                           control: "nodes: Status column", label: "Status")
        /// The Version column header.
        public static let version = HelpTag("The node's k3sm release, and how it compares with the cluster's target",
                                            control: "nodes: Version column", label: "Version")
        /// The summary line over the list.
        public static let versionSummary = HelpTag("Nodes on the cluster's target release, from the server's update check",
                                                   control: "nodes: version summary line")
        /// The inspector's k3sm fact.
        public static let versionFact = HelpTag("This node's release against the target the cluster moves to",
                                                control: "node inspector: k3sm fact")
        /// The inspector's latest-release fact.
        public static let latestFact = HelpTag("Newest k3sm release found by the server's last update check",
                                               control: "node inspector: Latest fact")
        /// The Load column header.
        public static let load = HelpTag("CPU and memory used now, from metrics-server, of allocatable",
                                         control: "nodes: Load column", label: "Load")
        /// The inspector's live CPU bar.
        public static let liveCPU = HelpTag("CPU the node uses now, from metrics-server, against allocatable",
                                            control: "node inspector: live CPU bar")
        /// The inspector's live memory bar.
        public static let liveMemory = HelpTag("Memory the node uses now, from metrics-server, against allocatable",
                                               control: "node inspector: live Memory bar")
        /// The inspector's CPU sparkline.
        public static let sparkline = HelpTag("The node's CPU over the last samples, oldest on the left",
                                              control: "node inspector: CPU sparkline")
        /// The inspector's per-pod usage.
        public static let podUsage = HelpTag("CPU and memory the pod uses now, from metrics-server",
                                             control: "node inspector: pod usage")

        /// This Mac's node: Update k3sm…
        public static let update = HelpTag("Update every node to the newest release, the server last",
                                           control: "node inspector: Update k3sm", label: NodeLifecycleAction.update.title)
        /// This Mac's node: Restart k3sm…
        public static let restart = HelpTag("Stop this Mac's k3sm daemons and start them again",
                                            control: "node inspector: Restart k3sm", label: NodeLifecycleAction.restart.title)
        /// This Mac's node: Stop k3sm…
        public static let stop = HelpTag("Stop this Mac's node and its pods until you start it again",
                                         control: "node inspector: Stop k3sm", label: NodeLifecycleAction.stop.title)

        /// A behind node's Update…, in its inspector and the Nodes header.
        public static let updateNode = HelpTag("Run the managed update, which moves this node, the server last",
                                               control: "nodes: Update for a node behind", label: NodeUpdateControl.title)

        /// The Nodes header's Update…, for every node behind.
        public static let updateBehind = HelpTag("Run the managed update, which moves the nodes behind, the server last",
                                                 control: "nodes: header Update for the nodes behind", label: NodeUpdateControl.title)

        /// A behind node's Update tag: why it is disabled, or what it does.
        public static func updateNode(_ control: NodeUpdateControl) -> String {
            control.reason ?? updateNode.text
        }

        /// The header's Update tag: why it is disabled, or what it does.
        public static func updateBehind(_ control: NodeUpdateControl) -> String {
            control.reason ?? updateBehind.text
        }

        /// A lifecycle button's tag: Update's is the update plan's, as the
        /// Updates pane's Update Now is: why it is disabled, or what it does.
        public static func lifecycle(_ action: NodeLifecycleAction, update control: UpdateNowControl, plan: UpdatePlan) -> String {
            switch action {
            case .update: return control.reason ?? Strip.update(plan)
            case .restart: return restart.text
            case .stop: return stop.text
            }
        }

        public static var all: [HelpTag] { [status, version, versionSummary, versionFact, latestFact, load, liveCPU, liveMemory, sparkline,
                                    podUsage, update, restart, stop, updateNode, updateBehind] }
    }

    // MARK: Images tab

    /// The Images tab's columns.
    public enum Images {
        /// The Size column header.
        public static let size = HelpTag("Size of the image, as the registry reports it",
                                         control: "images: Size column", label: "Size")
        /// The Cached on column header (the `.nodes` column).
        public static let nodes = HelpTag("Nodes that hold a cached copy of the image",
                                          control: "images: Cached on column", label: "Cached on")

        /// The Pods column header.
        public static let pods = HelpTag("Pods that run this image, as k3sm counts them",
                                         control: "images: Pods column", label: "Pods")
        /// The header row's Mirror button, which opens the Mirror sheet.
        public static let pull = HelpTag("Pull a public image and copy it into the cluster registry",
                                         control: "images: Mirror button", label: "Mirror…")
        /// The header row's Prune button, which runs the dry run first.
        public static let prune = HelpTag("List what a prune would delete from cache and registry, then ask",
                                          control: "images: Prune button", label: "Prune…")
        /// The image inspector's Untag button, for the selected registry tag.
        public static let untag = HelpTag("Delete this tag from the cluster registry, as an administrator",
                                          control: "image inspector: Untag button", label: "Untag…")
        /// The Mirror sheet's Mirror button.
        public static let pullConfirm = HelpTag("Pull the reference here and copy it, as an administrator",
                                                control: "mirror sheet: Mirror button", label: "Mirror")
        /// The prune preview sheet's Prune button: it deletes the node cache
        /// blobs and, on a server, the cluster registry's untagged manifests.
        public static let pruneConfirm = HelpTag("Delete the listed blobs and untagged registry manifests, as an administrator",
                                                 control: "prune sheet: Prune button", label: "Prune")
        /// The Mirror and prune sheets' Cancel button.
        public static let cancel = HelpTag("Close the sheet without changing anything",
                                           control: "image sheets: Cancel button", label: "Cancel")

        /// A write control's tag: its own, or the reason it is disabled.
        public static func write(_ tag: HelpTag, disabled reason: String?) -> String {
            reason ?? tag.text
        }

        public static var all: [HelpTag] { [size, nodes, pods, pull, prune, untag, pullConfirm, pruneConfirm, cancel] }
    }

    // MARK: Builds tab

    /// The Builds tab's columns.
    public enum Builds {
        /// The build history's Duration column header.
        public static let duration = HelpTag("How long the build ran, or has run so far",
                                             control: "builds: Duration column", label: "Duration")

        /// A recorded build's Show in Images button, in the inspector.
        public static let showInImages = HelpTag("Select this build's image in the registry's image list",
                                                 control: "builds: Show in Images", label: "Show in Images")

        public static var all: [HelpTag] { [duration, showInImages] }
    }

    // MARK: Services tab

    /// The Services tab's columns.
    public enum Services {
        /// The Hosts column header.
        public static let hosts = HelpTag("Host names that Ingresses route to the service",
                                          control: "services: Hosts column", label: "Hosts")
        /// The Cluster IP column header.
        public static let clusterIP = HelpTag("The service's virtual address inside the cluster",
                                              control: "services: Cluster IP column", label: "Cluster IP")

        public static var all: [HelpTag] { [hosts, clusterIP] }
    }

    // MARK: Storage tab

    /// The Storage tab's columns.
    public enum Storage {
        /// The Capacity column header.
        public static let capacity = HelpTag("Space the bound volume provides",
                                             control: "storage: Capacity column", label: "Capacity")
        /// The Phase column header.
        public static let phase = HelpTag("The claim's or volume's phase, as Kubernetes reports it",
                                          control: "storage: Phase column", label: "Phase")

        public static var all: [HelpTag] { [capacity, phase] }
    }

    // MARK: Models tab

    /// The Models tab's columns.
    public enum Models {
        /// The Ready column header.
        public static let ready = HelpTag("Replicas ready, of the replicas asked for",
                                          control: "models: Ready column", label: "Ready")
        /// The Endpoint column header.
        public static let endpoint = HelpTag("Address the model answers on inside the cluster",
                                             control: "models: Endpoint column", label: "Endpoint")

        public static var all: [HelpTag] { [ready, endpoint] }
    }

    // MARK: Stats tab

    /// The Stats tab's charts, one tag each.
    public enum Stats {
        public static let cpu = HelpTag("CPU used per node, from metrics-server, as a share of allocatable",
                                        control: "stats: CPU chart", label: StatsChart.cpu.title)
        public static let memory = HelpTag("Memory used per node, from metrics-server, as a share of allocatable",
                                           control: "stats: memory chart", label: StatsChart.memory.title)
        public static let podsByPhase = HelpTag("How many pods are in each phase, from the last pod list",
                                                control: "stats: pods by phase chart", label: StatsChart.podsByPhase.title)
        public static let podsByNode = HelpTag("How many pods each node holds, from the last pod list",
                                               control: "stats: pods by node chart", label: StatsChart.podsByNode.title)
        public static let restarts = HelpTag("Restarts found between pod list reads, in five-minute bars",
                                             control: "stats: restarts chart", label: StatsChart.restarts.title)
        public static let images = HelpTag("Size of the images each node reports holding, with their count",
                                           control: "stats: images chart", label: StatsChart.images.title)
        public static let storage = HelpTag("Capacity of the bound claims, against the data volume's free space",
                                            control: "stats: storage chart", label: StatsChart.storage.title)
        public static let updates = HelpTag("The update row's state in each status report this session",
                                            control: "stats: update chart", label: StatsChart.updates.title)

        /// One chart's tag.
        public static func tag(for chart: StatsChart) -> HelpTag {
            switch chart {
            case .cpu: return cpu
            case .memory: return memory
            case .podsByPhase: return podsByPhase
            case .podsByNode: return podsByNode
            case .restarts: return restarts
            case .images: return images
            case .storage: return storage
            case .updates: return updates
            }
        }

        public static var all: [HelpTag] { StatsChart.allCases.map(tag(for:)) }
    }

    // MARK: Alerts tab

    /// The Alerts tab's issue cards.
    public enum Alerts {
        /// The Copy button beside a command remedy or next step.
        public static let copyCommand = HelpTag("Copy the command to paste into Terminal",
                                                control: "alerts: Copy button", label: "Copy")
        /// The badge with a check's state word.
        public static let stateBadge = HelpTag("The state word k3sm status printed for this check",
                                               control: "alerts: state badge")

        /// The Copy button beside an alert's fix step command.
        public static let copyStep = HelpTag("Copy this step's command exactly as k3sm printed it",
                                             control: "alerts: fix step Copy button", label: "Copy")
        /// The disclosure that shows an alert's evidence.
        public static let evidence = HelpTag("Show the facts the check saw",
                                             control: "alerts: Evidence disclosure", label: "Evidence")
        /// The link to the guide page that covers an alert.
        public static let docs = HelpTag("Open the k3sm guide page about this problem in your browser",
                                         control: "alerts: Read the guide link", label: IssueAlert.docsTitle)
        /// The lock mark on a fix step that needs an administrator.
        public static let adminMark = HelpTag("Its command asks for an administrator password in Terminal",
                                              control: "alerts: needs an administrator mark", label: IssueAlert.adminMark)
        /// The mark on a fix step that destroys state or relaxes trust.
        public static let confirmMark = HelpTag("This step deletes state or relaxes trust; read it first",
                                                control: "alerts: Check before running mark", label: IssueAlert.confirmMark)

        public static let all = [copyCommand, stateBadge, copyStep, evidence, docs, adminMark, confirmMark]
    }

    // MARK: Inspector

    /// The inspector: the pod's detail tabs, the log summary's buttons and
    /// the health dots every list and card shares.
    public enum Inspector {
        /// The pod's Open Log, which opens its log in the log pane.
        public static let logs = HelpTag("Show the last \(K3smCLI.logTail) log lines of every container below",
                                         control: "inspector: Open Log", label: "Open Log")
        /// The pod's Events detail tab.
        public static let events = HelpTag("Show the events about this pod",
                                           control: "inspector: Events tab", label: "Events")
        /// The pod's Manifest detail tab.
        public static let manifest = HelpTag("Show the pod as kubectl prints it, in YAML",
                                             control: "inspector: Manifest tab", label: "Manifest")
        /// The log summary's Cancel button.
        public static let summaryCancel = HelpTag("Stop summarizing; nothing is kept",
                                                  control: "inspector: log summary Cancel", label: "Cancel")
        /// The log summary's Copy button.
        public static let summaryCopy = HelpTag("Copy the summary to the clipboard",
                                                control: "inspector: log summary Copy", label: "Copy")
        /// The log summary's Close button.
        public static let summaryClose = HelpTag("Put the summary away",
                                                 control: "inspector: log summary Close", label: "Close")
        /// A health dot with no word beside it (a pod, a model, an event).
        public static let healthDot = HelpTag("Green is fine, amber needs a look, red has failed",
                                              control: "lists: health dot")

        /// The inspector's Actions menu, the row's context menu as a button.
        public static let actions = HelpTag("Open the same list as the row's right-click menu",
                                            control: "inspector: Actions menu", label: "Actions")
        /// The Scale stepper on the pod's Deployment or StatefulSet.
        public static let scaleStepper = HelpTag("Choose the replica count to scale to, from 1 to 50",
                                                 control: "inspector: Scale stepper")
        /// The Scale button beside it.
        public static let scale = Actions.byVerb["controller-scale"] ?? Actions.other

        /// One of the pod's detail tabs, by its label.
        public static func detail(_ label: String) -> HelpTag {
            switch label {
            case events.label: return events
            case manifest.label: return manifest
            default: return logs
            }
        }

        public static var all: [HelpTag] {
            [logs, events, manifest, summaryCancel, summaryCopy, summaryClose, healthDot, actions, scaleStepper]
        }
    }

    /// The log pane along the bottom of the window: a pod's or a build's log.
    public enum LogPane {
        /// Follow, on a pod of one container.
        public static let follow = HelpTag("Stream the pod's new log lines into the pane",
                                           control: "log pane: Follow", label: "Follow")
        /// Follow, on a pod of several containers.
        public static let followMenu = HelpTag("Choose a container and stream its new log lines",
                                               control: "log pane: Follow menu", label: "Follow")
        /// One container's item in that menu.
        public static let followContainer = HelpTag("Stream this container's new log lines into the pane",
                                                    control: "log pane: Follow menu item")
        /// Stop, while a log is followed.
        public static let followStop = HelpTag("End the stream; the lines read so far stay",
                                               control: "log pane: Follow Stop", label: "Stop")
        /// The pane's close button.
        public static let close = HelpTag("Stop reading the log and close the pane",
                                          control: "log pane: close")

        public static var all: [HelpTag] { [follow, followMenu, followContainer, followStop, close] }
    }

    // MARK: Row actions

    /// The actions a row offers, by the request's `verb` and the local item's
    /// id. In the inspector's Actions menu and a row's context menu they are
    /// menu items, which show no help tag on macOS, so only the buttons that
    /// run one directly carry these: a tab's header row, a paused
    /// controller's row and the inspector's Scale button.
    public enum Actions {
        /// Each request verb's tag.
        static let byVerb: [String: HelpTag] = [
            "restart": tag("Delete the pod so its owner recreates it", "pod Restart", "Restart"),
            "delete": tag("Delete the pod; its containers stop now", "pod Delete", "Delete"),
            "workload-pause": tag("Scale the controller to zero, recording its replica count", "pod Pause", "Pause"),
            "workload-pause-retry": tag("Scale the controller to zero again; its recorded count stays", "pod Pause", "Pause"),
            "workload-pause-scale": tag("Scale the controller to zero once its count is recorded", "pod Pause", "Pause"),
            "workload-resume": tag("Scale the controller back to its recorded replicas", "controller Resume", "Resume"),
            "workload-resume-clear": tag("Remove the recorded count once the controller is back", "controller Resume",
                                         "Resume"),
            "rollout-restart": tag("Replace the controller's pods one by one, by its update strategy",
                                   "pod Rollout Restart", "Rollout Restart"),
            "controller-scale": tag("Set the controller's replicas to the stepper's count", "inspector Scale", "Scale"),
            "service-delete": tag("Delete the service and its cluster address", "service Delete", "Delete"),
            "model-unload": tag("Scale the model to zero; Load brings it back", "model Unload", "Unload"),
            "model-load": tag("Scale the model back to its recorded replicas", "model Load", "Load"),
            "model-delete": tag("Delete the model, its serving pods and its Services", "model Delete", "Delete"),
            "build-cancel": tag("Stop the build; its record stays in the history", "build Cancel Build", "Cancel Build"),
            "build-delete": tag("Remove the build and its log from the history", "build Delete Record", "Delete Record"),
            "builder-start": tag("Start the build engine and wait for it to serve", "engine Start Engine", "Start Engine"),
            "builder-reset-start": tag("Start the build engine after its reset", "engine Start Engine", "Start Engine"),
            "builder-stop": tag("Stop the build engine; its cache stays", "engine Stop Engine", "Stop Engine"),
            "builder-reset": tag("Remove the engine and its cache, then start it again", "engine Reset Engine", "Reset Engine"),
            "builder-prune-plan": tag("Measure what a prune would reclaim, then ask", "engine Prune Cache", "Prune Cache"),
            "builder-prune": tag("Free the cache no running build holds", "engine Prune Cache", "Prune Cache"),
            "cleanup": tag("Delete the pods that completed or failed", "workloads cleanup",
                           "Delete completed and failed pods"),
            "node-cordon": tag("Stop new pods being placed on the node", "node Cordon", "Cordon"),
            "node-uncordon": tag("Let new pods be placed on the node again", "node Uncordon", "Uncordon"),
            "node-drain": tag("Cordon the node and move its pods to other nodes", "node Drain", "Drain"),
            "delete-claim": tag("Delete the claim; its volume follows its reclaim policy", "claim Delete", "Delete"),
            "delete-volumes": tag("Delete volumes that no claim holds", "storage cleanup",
                                  "Delete released and unclaimed volumes"),
        ]

        /// Each local item's tag, by its id (Summarize Logs by its id's prefix).
        static let byLocalID: [String: HelpTag] = [
            "copy-name": tag("Copy the pod's name", "pod Copy Name", "Copy Name"),
            "copy-namespace-name": tag("Copy namespace/name, the form kubectl takes", "pod Copy Namespace/Name",
                                       "Copy Namespace/Name"),
            "open-shell": tag("Open a shell in the pod's container, in Terminal", "pod Open Shell",
                              "Open Shell in Terminal"),
            "summarize-logs": tag("Summarize the container's recent logs on this Mac", "pod Summarize Logs",
                                  "Summarize Logs"),
            "copy-endpoint": tag("Copy the model's address inside the cluster", "model Copy Endpoint", "Copy Endpoint"),
            "copy-curl": tag("Copy a curl command that asks the model a question", "model Copy curl Example",
                             "Copy curl Example"),
            "copy-ip": tag("Copy the service's virtual address", "service Copy Cluster IP", "Copy Cluster IP"),
            "copy-dns": tag("Copy the name pods use to reach the service", "service Copy DNS Name", "Copy DNS Name"),
            "open": tag("Open the service's address in your browser", "service Open in Browser", "Open in Browser"),
            "copy-url": tag("Copy the service's web address", "service Copy URL", "Copy URL"),
            "show-log": tag("Show the build's log, following it while it runs", "build Show Log", "Show Log"),
        ]

        /// The tag of an action the catalog does not know yet.
        public static let other = HelpTag("Run this action on the selected row", control: "row action")

        private static func tag(_ text: String, _ control: String, _ label: String) -> HelpTag {
            HelpTag(text, control: "row action: " + control, label: label)
        }

        /// A request's button.
        public static func tag(for item: ActionMenuItem) -> HelpTag {
            byVerb[item.request.verb] ?? other
        }

        /// A local item's button.
        public static func tag(for item: LocalMenuItem) -> HelpTag {
            let key = item.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? item.id
            return byLocalID[key] ?? other
        }

        /// The whole text of a bulk action's line, which its header row truncates to fit.
        public static func fullLine(_ text: String) -> String { text }

        public static var all: [HelpTag] {
            byVerb.keys.sorted().compactMap { byVerb[$0] } + byLocalID.keys.sorted().compactMap { byLocalID[$0] } + [other]
        }
    }

    // MARK: Mac panel

    /// The status headline in the navy panel and the info button's popover:
    /// the state's dot and the needs-admin lock.
    public enum Status {
        /// Where a headline is drawn, which decides where its lock points.
        public enum Place: Sendable {
            /// The navy panel, with the daemon rows under it.
            case panel
            /// The info button's popover, with All checks under it.
            case popover
        }

        /// The dot before the state.
        public static let dot = HelpTag("Green while k3sm runs here, amber when degraded, grey when stopped",
                                        control: "status headline: state dot")

        /// The lock beside the state while `count` checks need an
        /// administrator: the whole of the line the lock stands for, and
        /// where the checks are listed.
        public static func needsAdmin(_ count: Int, in place: Place) -> HelpTag {
            let checks = count == 1 ? "1 check" : "\(max(0, count)) checks"
            let see = place == .panel ? "see the rows below" : "open the checks list below"
            return HelpTag("Needs an administrator to read \(checks); \(see)", control: "status headline: needs-admin lock")
        }

        /// The panel's headline, which opens the Alerts tab.
        public static let headline = HelpTag("Show the checks behind this state and how to fix them",
                                             control: "status headline: panel")

        public static var all: [HelpTag] {
            [dot, headline, needsAdmin(1, in: .panel), needsAdmin(4, in: .panel), needsAdmin(1, in: .popover), needsAdmin(12, in: .popover)]
        }
    }

    /// The navy panel: the view switch, the tiles, the meters and the dots.
    public enum Panel {
        /// The Cluster segment of the panel's switch.
        public static let cluster = HelpTag("Show the cluster's figures and its nodes",
                                            control: "panel: Cluster switch", label: "Cluster")
        /// The This Mac segment of the panel's switch.
        public static let thisMac = HelpTag("Show this machine, its pods and its load",
                                            control: "panel: This Mac switch", label: "This Mac")
        /// The dot before a node's name.
        public static let nodeDot = HelpTag("Green when the node reports Ready, amber otherwise",
                                            control: "panel: node dot")
        /// A node row's CPU bar.
        public static let nodeCores = HelpTag("CPU pods request as the light band, CPU used as solid",
                                              control: "panel: node CPU bar")
        /// A node row's Memory bar.
        public static let nodeMemory = HelpTag("Memory pods request as the light band, memory used as solid",
                                               control: "panel: node Memory bar")
        /// This Mac's CPU bar.
        public static let liveCPU = HelpTag("This Mac's CPU requested as the light band, used now as solid",
                                            control: "panel: This Mac CPU bar")
        /// This Mac's memory bar.
        public static let liveMemory = HelpTag("This Mac's memory requested as the light band, used now as solid",
                                               control: "panel: This Mac Memory bar")
        /// The This Mac view's core grid.
        public static let coreGrid = HelpTag("Fill is CPU used, from metrics-server, one cell per core",
                                             control: "panel: core grid")
        /// The This Mac view's unified memory meter.
        public static let memoryMeter = HelpTag("Fill is memory used: the pods', from metrics-server, then macOS and apps",
                                                control: "panel: Unified memory meter")

        /// The panel's view switch segment.
        public static func mode(_ mode: PanelMode) -> HelpTag {
            mode == .cluster ? cluster : thisMac
        }

        /// One tile, by its label.
        public static func tile(_ tile: PanelTile) -> HelpTag {
            tileTag(label: tile.label)
        }

        static func tileTag(label: String) -> HelpTag {
            let text: String
            switch label {
            case "Macs": text = "Macs in this cluster, every node ready"
            case "nodes ready": text = "Nodes reporting Ready, of all the cluster's nodes"
            case "pods running": text = "Pods running on every node of the cluster"
            case "cores requested": text = "CPU the pods request, in cores, of the total"
            case "memory requested": text = "Memory the pods request, of the total"
            case "cores used": text = "CPU this Mac's node used, from metrics-server, of its cores"
            case "pod memory used": text = "Memory this Mac's pods use, from metrics-server, of its unified memory"
            case "data root": text = "Space used on the volume that holds k3sm's data"
            case "pod on this Mac", "pods on this Mac": text = "Pods bound to this Mac's node that have not finished"
            default: text = "A figure from the last status read"
            }
            return HelpTag(text, control: "panel: tile", label: label)
        }

        /// Every tile label the panel draws.
        static let tileLabels = ["Macs", "nodes ready", "pods running", "cores requested", "memory requested",
                                 "cores used", "pod memory used", "data root", "pod on this Mac", "pods on this Mac", ""]

        public static var all: [HelpTag] {
            [cluster, thisMac, nodeDot, nodeCores, nodeMemory, liveCPU, liveMemory,
             coreGrid, memoryMeter] + tileLabels.map { tileTag(label: $0) }
        }
    }

    // MARK: Status popover

    /// The info button's popover: the lifecycle buttons, the app-carried
    /// update, Refresh and the login approval line.
    public enum Popover {
        /// Stop k3sm…
        public static let stop = HelpTag("Stop this Mac's node until you start it again",
                                         control: "popover: Stop", label: "Stop k3sm…")
        /// Restart k3sm…
        public static let restart = HelpTag("Stop this Mac's k3sm daemons and start them again",
                                            control: "popover: Restart", label: "Restart k3sm…")
        /// Start k3sm…
        public static let start = HelpTag("Start this Mac's node and its pods again",
                                          control: "popover: Start", label: "Start k3sm…")
        /// Refresh, under All checks.
        public static let refresh = HelpTag("Read k3sm's status again (Command-R)",
                                            control: "popover: Refresh", label: "Refresh")
        /// Open Login Items, beside the approval line and in Settings.
        public static let openLoginItems = HelpTag("Open System Settings to allow k3sm at login",
                                                   control: "login approval: Open Login Items", label: "Open Login Items")

        public static var all: [HelpTag] { [stop, restart, start, refresh, openLoginItems] }
    }

    // MARK: Health banner and guided panel

    /// The health banner across the top of the console and the guided panel
    /// (a sheet) it opens.
    public enum Guided {
        /// The banner's button, whose label names the next step.
        public static let banner = HelpTag("Show the steps that bring k3sm back to health",
                                           control: "health banner: next step")
        /// Start k3sm, in the guided panel.
        public static let start = HelpTag("Start this Mac's node, as an administrator",
                                          control: "guided panel: Start", label: "Start k3sm")
        /// Restart k3sm, in the guided panel.
        public static let restart = HelpTag("Stop k3sm's daemons and start them again, as an administrator",
                                            control: "guided panel: Restart", label: "Restart k3sm")
        /// Update k3sm, in the guided panel.
        public static let update = HelpTag("Install the k3sm release this app carries, as an administrator",
                                           control: "guided panel: Update", label: "Update k3sm")
        /// Repair k3sm, in the guided panel.
        public static let repair = HelpTag("Install this app's k3sm release again over this one, as an administrator",
                                           control: "guided panel: Repair", label: "Repair k3sm")
        /// Refresh, in the guided panel.
        public static let refresh = HelpTag("Read k3sm's status on this Mac again",
                                            control: "guided panel: Refresh", label: "Refresh")
        /// Open Logs, in the guided panel.
        public static let openLogs = HelpTag("Open the k3sm logs this account can read",
                                             control: "guided panel: Open Logs", label: "Open Logs")
        /// Copy Command, beside the Terminal command.
        public static let copyCommand = HelpTag("Put the command on the clipboard to paste into Terminal",
                                                control: "guided panel: Copy Command", label: "Copy Command")
        /// Open Terminal, beside a Terminal command that is not an install.
        public static let openTerminal = HelpTag("Open the Terminal app to run the command",
                                                 control: "guided panel: Open Terminal", label: "Open Terminal")
        /// Run in Terminal, beside the install command of a developer build.
        public static let runInTerminal = HelpTag("Run the install command in a new Terminal window",
                                                  control: "guided panel: Run in Terminal", label: "Run in Terminal")
        /// Close, which puts the panel away.
        public static let close = HelpTag("Put this panel away (Escape)",
                                          control: "guided panel: Close", label: "Close")

        /// The primary button's tag: why it is disabled, or what it does;
        /// Update's is the update plan's.
        public static func primary(_ action: GuidedAction, disabledReason: String?, plan: UpdatePlan) -> String {
            if let disabledReason { return disabledReason }
            switch action {
            case .start: return start.text
            case .restart: return restart.text
            case .update: return Strip.update(plan)
            case .repair: return repair.text
            case .refresh: return refresh.text
            }
        }

        public static var all: [HelpTag] {
            [banner, start, restart, update, repair, refresh, openLogs, copyCommand, openTerminal, runInTerminal, close]
        }
    }

    // MARK: First run

    /// The guided first run (`FirstRunFlow`).
    public enum FirstRun {
        /// The start-or-join switch.
        public static let choice = HelpTag("Start a new cluster here, or join one that runs",
                                           control: "first run: choice switch")
        /// Continue, to the next step.
        public static let next = HelpTag("Go on to the next step",
                                         control: "first run: Continue", label: "Continue")
        /// Back, to the step before.
        public static let back = HelpTag("Go back to the previous step",
                                         control: "first run: Back", label: "Back")
        /// Start Cluster…, the review step's install for a start.
        public static let start = HelpTag("Install a k3sm server on this Mac, as an administrator",
                                          control: "first run: Start Cluster", label: "Start Cluster…")
        /// Join Cluster…, the review step's install for a join.
        public static let join = HelpTag("Install k3sm and join the cluster, as an administrator",
                                         control: "first run: Join Cluster", label: "Join Cluster…")
        /// Clear, beside the address and token read from a paste.
        public static let clearPaste = HelpTag("Forget the pasted address and token",
                                               control: "first run: Clear", label: "Clear")
        /// Copy Command, beside a developer build's Terminal command.
        public static let copyCommand = HelpTag("Put the commands on the clipboard for Terminal",
                                                control: "first run: Copy Command", label: "Copy Command")
        /// Install in Terminal, a developer build's install on the review step.
        public static let installInTerminal = HelpTag("Run the commands below in a new Terminal window",
                                                      control: "first run: Install in Terminal", label: "Install in Terminal")
        /// The install watch's path, where the butterfly flies between checks.
        public static let installPath = HelpTag("Checks for k3sm every 5 seconds; the button below checks now",
                                                control: "first run: install watch path")
        /// Check Again, which checks for an install now.
        public static let checkAgain = HelpTag("Look for a k3sm install on this Mac again",
                                               control: "first run: Check Again", label: "Check Again")
        /// Try Again, after a failed install.
        public static let tryAgain = HelpTag("Go back and run the install once more",
                                             control: "first run: Try Again", label: "Try Again")
        /// Open Console, after the install.
        public static let openConsole = HelpTag("Show the console for the new install",
                                                control: "first run: Open Console", label: "Open Console")

        /// The install button's tag: why it is disabled, or what it does.
        public static func install(join joining: Bool, disabledReason: String?) -> String {
            disabledReason ?? (joining ? join.text : start.text)
        }

        public static var all: [HelpTag] {
            [choice, next, back, start, join, clearPaste, copyCommand, installInTerminal, installPath, checkAgain, tryAgain, openConsole]
        }
    }

    // MARK: Update panel

    /// The managed update's progress panel under the strip.
    public enum Update {
        /// Cancel Update…
        public static let cancel = HelpTag("Stop the roll before its next node",
                                           control: "update panel: Cancel Update", label: "Cancel Update…")
        /// Abort Update…, while the roll runs and after it failed.
        public static let abort = HelpTag("End the roll now and release every node; nothing rolls back",
                                          control: "update panel: Abort Update", label: "Abort Update…")
        /// Dismiss, once the roll is over.
        public static let dismiss = HelpTag("Put this panel away; the update is over",
                                            control: "update panel: Dismiss", label: "Dismiss")

        /// Cancel Update's tag: why it is disabled, or what it does.
        public static func cancel(reason: String?) -> String { reason ?? cancel.text }

        /// Abort Update's tag: why it is disabled, or what it does.
        public static func abort(reason: String?) -> String { reason ?? abort.text }

        public static var all: [HelpTag] { [cancel, abort, dismiss] }
    }

    // MARK: Tour

    /// The tour card's buttons.
    public enum Tour {
        /// Back.
        public static let back = HelpTag("Go to the previous stop", control: "tour: Back", label: "Back")
        /// Next.
        public static let next = HelpTag("Go to the next stop", control: "tour: Next", label: "Next")
        /// Done, on the last stop.
        public static let done = HelpTag("End the tour and put your layout back", control: "tour: Done", label: "Done")

        /// The forward button, which reads Next or Done.
        public static func forward(last: Bool) -> HelpTag { last ? done : next }

        public static var all: [HelpTag] { [back, next, done] }
    }

    // MARK: Settings: General

    /// The General pane.
    public enum General {
        /// Open k3sm at login.
        public static let openAtLogin = HelpTag("Register k3sm as a login item for this account",
                                                control: "general: open at login", label: "Open k3sm at login")
        /// Open the window when k3sm opens at login.
        public static let windowAtLogin = HelpTag("Show the window too, not only the menu bar item",
                                                  control: "general: window at login",
                                                  label: "Open the window when k3sm opens at login")
        /// Notify me at login when k3sm is stopped.
        public static let notifyStopped = HelpTag("Post a notification with a Start button",
                                                  control: "general: stopped notification",
                                                  label: "Notify me at login when k3sm is stopped")
        /// Animate the Dock icon.
        public static let dockAnimation = HelpTag("Flap the butterfly on the Dock tile; off under Reduce Motion",
                                                  control: "general: Dock animation",
                                                  label: "Animate the Dock icon while the window is open")
        /// Take the Tour, while the console is the screen.
        public static let tour = HelpTag("Walk through the console, one stop at a time",
                                         control: "general: Take the Tour", label: "Take the Tour")
        /// Take the Tour, before k3sm is installed.
        public static let tourUnavailable = HelpTag("The tour needs the console, shown once k3sm is installed",
                                                    control: "general: Take the Tour (disabled)", label: "Take the Tour")
        /// Reset Window Layout…
        public static let resetLayout = HelpTag("Put the panel, details column and table columns back as first",
                                                control: "general: Reset Window Layout", label: "Reset Window Layout…")

        /// The status refresh popup.
        public static let pollProfile = HelpTag("How often the app reads k3sm; the slower choice saves battery",
                                                control: "general: poll profile popup", label: "Status refresh")
        /// The appearance picker.
        public static let appearance = HelpTag("Show the app's windows light or dark, or as macOS is set",
                                               control: "general: appearance picker", label: "Appearance")
        /// Stop k3sm when I quit the app.
        public static let stopOnQuit = HelpTag("Run k3sm stop, as an administrator, before the app quits",
                                               control: "general: stop on quit", label: QuitPolicy.toggleLabel)

        /// Take the Tour's tag.
        public static func tour(available: Bool) -> HelpTag { available ? tour : tourUnavailable }

        public static var all: [HelpTag] {
            [openAtLogin, windowAtLogin, notifyStopped, stopOnQuit, dockAnimation, tour, tourUnavailable, resetLayout, pollProfile,
             appearance]
        }
    }

    // MARK: Settings: Network

    /// The Network pane.
    public enum Network {
        /// Allow connections from other devices.
        public static let lan = HelpTag("Open or close pod listeners to your network, as an administrator",
                                        control: "network: LAN checkbox",
                                        label: "Allow connections from other devices")

        /// The interconnect checkbox, which shows the state only.
        public static let interconnect = HelpTag("Whether pods may use the Thunderbolt cable network; change it in Terminal",
                                                 control: "network: interconnect checkbox",
                                                 label: InterconnectSetting.title)

        public static var all: [HelpTag] { [lan, interconnect] }
    }

    // MARK: Settings: Updates

    /// The Updates pane: the two versions, the state, Update Now and the
    /// options passed to `k3sm update apply`.
    public enum Updates {
        /// The installed release.
        public static let installed = HelpTag("The release the installed k3sm reports, from k3sm version",
                                              control: "updates: installed value", label: "Installed")
        /// The available release.
        public static let available = HelpTag("The newest release, from the server's hourly update check",
                                              control: "updates: available value", label: "Available")
        /// The state line under the versions.
        public static let state = HelpTag("The update row of k3sm status, in plain words",
                                          control: "updates: state line")
        /// Update Now.
        public static let updateNow = HelpTag("Update every node to the newest release, the server last",
                                              control: "updates: Update Now", label: UpdateNowControl.title)
        /// Drain each node before updating it.
        public static let drain = HelpTag("Evict each node's pods before it updates, so they move first",
                                          control: "updates: drain checkbox", label: "Drain each node before updating it")
        /// Allow a release older than a node runs, in the update's confirmation.
        public static let allowDowngrade = HelpTag("Let this update move a node to an older release",
                                                   control: "update confirmation: downgrade checkbox",
                                                   label: UpdateOptions.downgradeTitle)
        /// The signature policy popup.
        public static let signature = HelpTag("Which code signature the new release must carry; checksums always apply",
                                              control: "updates: signature popup", label: "Code signature")

        /// Update Now's tag: why it is disabled, or what the update plan's path does.
        public static func updateNow(_ control: UpdateNowControl, plan: UpdatePlan) -> String {
            control.reason ?? Strip.update(plan)
        }

        /// Notify me when an update is available.
        public static let notify = HelpTag("Post a notification once for each new release the app can install",
                                           control: "updates: notify checkbox", label: "Notify me when an update is available")

        /// The app's own release line.
        public static let appState = HelpTag("This app against the latest signed release index",
                                             control: "updates: app release line")
        /// The age of the last successful check.
        public static let lastCheck = HelpTag("When the release index was last fetched and verified",
                                              control: "updates: last check line")
        /// Check Now, for the app's own release.
        public static let checkNow = HelpTag("Fetch and verify the signed release index now",
                                             control: "updates: Check Now", label: "Check Now")
        /// Check for app updates automatically.
        public static let checkApp = HelpTag("Fetch the release index a minute after launch, then daily",
                                             control: "updates: check app checkbox", label: "Check for app updates automatically")
        /// Download app updates.
        public static let downloadApp = HelpTag("Fetch and verify a new app release once one is found",
                                                control: "updates: download app checkbox", label: "Download app updates when available")

        public static var all: [HelpTag] {
            [installed, available, state, updateNow, drain, allowDowngrade, signature, notify,
             appState, lastCheck, checkNow, checkApp, downloadApp]
        }
    }

    // MARK: Settings: Advanced

    /// The Advanced pane.
    public enum Advanced {
        /// Write a Bug Report…
        public static let bugReport = HelpTag("Collect a report in Terminal for you to review; nothing is uploaded",
                                              control: "advanced: Write a Bug Report", label: "Write a Bug Report…")
        /// Live Status.
        public static let liveStatus = HelpTag("Watch k3sm status in Terminal, refreshed every \(LiveView.interval)",
                                               control: "advanced: Live Status", label: "Live Status")
        /// Open Logs.
        public static let openLogs = HelpTag("Open the k3sm logs this account can read",
                                             control: "advanced: Open Logs", label: "Open Logs")
        /// Reset to Defaults…
        public static let resetDefaults = HelpTag("Put the app's preferences back to how they first were",
                                                  control: "advanced: Reset to Defaults", label: "Reset to Defaults…")
        /// Also delete k3sm's data.
        public static let purge = HelpTag("Remove the cluster's data too; without it the data stays",
                                          control: "advanced: purge checkbox", label: "Also delete k3sm's data")
        /// Uninstall k3sm…
        public static let uninstall = HelpTag("Remove k3sm from this Mac, as an administrator",
                                              control: "advanced: Uninstall", label: "Uninstall k3sm…")

        public static var all: [HelpTag] { [bugReport, liveStatus, openLogs, resetDefaults, purge, uninstall] }
    }

    /// The Settings window's Cluster and Storage panes (`NodeSettingsPanes`).
    public enum InstallSettings {
        /// A setting line's Copy button.
        public static let copy = HelpTag("Put this value on the clipboard", control: "settings: setting Copy", label: "Copy")
        /// The lock beside a value only root can read.
        public static let restricted = HelpTag("Only an administrator can read this value, with sudo k3sm status",
                                               control: "settings: restricted value lock")

        /// The kubeconfig's Copy Path button.
        public static let copyKubeconfig = HelpTag("Put the kubeconfig's path on the clipboard, never its contents",
                                                   control: "cluster: kubeconfig Copy Path", label: "Copy Path")
        /// The kubeconfig's Show in Finder button.
        public static let revealKubeconfig = HelpTag("Open a Finder window with the kubeconfig file selected",
                                                     control: "cluster: kubeconfig Show in Finder", label: "Show in Finder")

        public static var all: [HelpTag] { [copy, restricted, copyKubeconfig, revealKubeconfig] }
    }

    // MARK: Settings window

    /// The Settings window's toolbar.
    public enum SettingsWindow {
        /// A pane's toolbar item.
        public static func pane(_ pane: SettingsPane) -> HelpTag {
            let text: String
            switch pane {
            case .general: text = "Show the login, quit, Dock and window settings"
            case .cluster: text = "Show the node's role and its cluster install settings"
            case .storage: text = "Show the data volume and where updates come from"
            case .network: text = "Show whether other devices may connect to pods"
            case .updates: text = "Show the releases, the update button and how an update runs"
            case .advanced: text = "Show diagnostics, uninstall and the preferences reset"
            }
            return HelpTag(text, control: "settings toolbar: \(pane.rawValue)", label: pane.title)
        }

        public static var all: [HelpTag] { SettingsPane.allCases.map(pane) }
    }

    // MARK: Menus

    /// The AppKit menus' items: the status item's menu and the menu bar.
    /// A menu shows its own shortcuts, so these name none.
    public enum Menus {
        /// Stop k3sm…, in the status item's menu.
        public static let stop = HelpTag(Popover.stop.text, control: "status menu: Stop", label: "Stop k3sm…")
        /// Restart k3sm…, in the status item's menu.
        public static let restart = HelpTag(Popover.restart.text, control: "status menu: Restart", label: "Restart k3sm…")
        /// Live Status in Terminal.
        public static let liveStatus = HelpTag("Watch k3sm status, refreshed every \(LiveView.interval)",
                                               control: "status menu: Live Status", label: LiveView.status.menuTitle)
        /// Live Top in Terminal.
        public static let liveTop = HelpTag("Watch node and pod load, refreshed every \(LiveView.interval)",
                                            control: "status menu: Live Top", label: LiveView.top.menuTitle)
        /// Open Logs.
        public static let openLogs = HelpTag(Advanced.openLogs.text, control: "status menu: Open Logs", label: "Open Logs")
        /// Write a Bug Report…
        public static let bugReport = HelpTag(Advanced.bugReport.text, control: "status menu: Write a Bug Report",
                                              label: "Write a Bug Report…")
        /// Settings…
        public static let settings = HelpTag("Open the Settings window", control: "menus: Settings", label: "Settings…")
        /// Check for Updates…, in the app menu.
        public static let checkForUpdates = HelpTag("Fetch and verify the signed release index now",
                                                    control: "app menu: Check for Updates", label: "Check for Updates…")
        /// Dashboard.
        public static let dashboard = HelpTag("Open the k3sm window", control: "status menu: Dashboard",
                                              label: MenuStatus.windowItemTitle)
        /// View > Refresh.
        public static let refresh = HelpTag("Read the status and the open tab again",
                                            control: "view menu: Refresh", label: "Refresh")
        /// View > Show Status.
        public static let showStatus = HelpTag("Open the status popover under the info button",
                                               control: "view menu: Show Status", label: "Show Status")
        /// View > Hide Panel or Show Panel.
        public static let panel = HelpTag("Hide or show the console's left panel",
                                          control: "view menu: Hide Panel", label: "Hide Panel")
        /// View > Reset Column Widths.
        public static let resetColumns = HelpTag("Put every table's columns back to their first widths",
                                                 control: "view menu: Reset Column Widths", label: "Reset Column Widths")
        /// Help > Take the Tour.
        public static let tour = HelpTag(Strip.tour.text, control: "help menu: Take the Tour", label: "Take the Tour")

        public static var all: [HelpTag] {
            [stop, restart, liveStatus, liveTop, openLogs, bugReport, settings, checkForUpdates, dashboard, refresh, showStatus,
             panel, resetColumns, tour]
        }
    }
}

/// HelpStandard checks a help tag against the app's standard (see `Help`).
public enum HelpStandard {
    /// The most words a tag carries, not counting a shortcut in parentheses.
    public static let maxWords = 12

    /// Words that keep a capital after the first: names of things, keys
    /// and the controls a tag points at.
    static let properNouns: Set<String> = [
        "Mac", "Mac's", "Macs", "Terminal", "Linux", "Dock", "Settings", "System", "Login", "Items",
        "Ready", "Start", "Load", "Reduce", "Motion", "Kubernetes", "Ingresses", "Services", "YAML", "VM",
        "Finder", "Thunderbolt",
    ]

    /// Lowercase words a tag may start with: product and command names.
    static let lowercaseStarts: Set<String> = ["k3sm", "k3sm's", "kubectl", "curl"]

    /// What is wrong with `tag`, one line each; empty when it follows the standard.
    public static func problems(_ tag: HelpTag) -> [String] {
        var out: [String] = []
        let text = tag.text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ["empty"] }
        if text != text.trimmingCharacters(in: .whitespacesAndNewlines) { out.append("leading or trailing space") }
        if text.contains("\n") { out.append("more than one line") }
        let prose = withoutParentheses(text)
        let words = prose.split(whereSeparator: { $0 == " " }).map(String.init)
        if words.count > maxWords { out.append("\(words.count) words, more than \(maxWords)") }
        if let first = words.first, let initial = first.first {
            if !initial.isUppercase && !lowercaseStarts.contains(first.trimmingCharacters(in: .punctuationCharacters)) {
                out.append("does not start with a capital")
            }
        }
        for (previous, word) in zip(words, words.dropFirst()) {
            // A word after a full stop starts the second sentence.
            if previous.hasSuffix(".") { continue }
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ",;:.!?\"'"))
            guard let initial = bare.first, initial.isUppercase else { continue }
            if isAcronym(bare) || properNouns.contains(bare) { continue }
            out.append("not sentence case: \"\(bare)\"")
        }
        if let last = text.last {
            if ",;:!?".contains(last) { out.append("ends with \"\(last)\"") }
            if last == "." && !text.dropLast().contains(". ") { out.append("one sentence ends with a period") }
            if last == "…" || text.hasSuffix("...") { out.append("ends with an ellipsis") }
        }
        if let label = tag.label, normalized(label) == normalized(text) {
            out.append("repeats its label \"\(label)\"")
        }
        return out
    }

    /// The text with every parenthesized part (a shortcut) removed.
    static func withoutParentheses(_ text: String) -> String {
        var out = ""
        var depth = 0
        for ch in text {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) } else if depth == 0 { out.append(ch) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func isAcronym(_ word: String) -> Bool {
        word.count >= 2 && word.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "-" || $0 == "/" }
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
    }
}
