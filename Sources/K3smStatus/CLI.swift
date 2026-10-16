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

/// K3smCLI is how the app invokes the k3sm CLI: one absolute path, fixed
/// argument lists, and an environment the app builds itself. Nothing in the
/// user's own environment (PATH, KUBECONFIG, K3SM_WORK_DIR) reaches the CLI.
public enum K3smCLI {
    /// The installed CLI. The app never searches PATH for it.
    public static let path = "/Library/k3sm/k3sm"
    /// The install root. Its absence is the app's first-run state.
    public static let installRoot = "/Library/k3sm"
    /// The cheap visibility probe: launchd state only, no apiserver call.
    public static let probeArguments = ["status", "daemons", "-o", "json"]
    /// The full report, run only when the user looks at it.
    public static let reportArguments = ["status", "-o", "json"]
    /// The installed version, read on launch for the update check.
    public static let versionArguments = ["version"]
    /// The start's own time bound, read before the app runs `k3sm start`:
    /// the CLI prints whole seconds and does nothing else (`StartTimeBound`).
    public static let startTimeBoundArguments = ["start", "--print-time-bound"]
    /// The managed update's progress, read while one rolls
    /// (`UpdateStatus`). Unprivileged: it only reads the roll.
    public static let updateStatusArguments = ["update", "status", "-o", "json"]
    /// Starts the managed update to the latest release. Run only as root,
    /// through the checked lifecycle script; `--yes` answers the CLI's own
    /// question, which the app has already asked.
    public static let updateApplyArguments = ["update", "apply", "--yes"]
    /// Cancels the managed update. Run only as root, like the apply.
    public static let updateCancelArguments = ["update", "cancel"]
    /// The workloads list: every pod on the cluster, through the CLI's bundled
    /// kubectl with the kubeconfig the CLI presets.
    public static let workloadsArguments = ["kubectl", "get", "pods", "-A", "-o", "json"]
    /// The cluster's nodes, through the same bundled kubectl: names, Ready,
    /// versions, addresses, capacity and allocatable.
    public static let nodesArguments = ["kubectl", "get", "nodes", "-o", "json"]
    /// The build engine: the pods and claims in its namespace, through the
    /// same bundled kubectl. A cluster without an engine lists none.
    public static let buildEngineArguments = ["kubectl", "get", "pods,pvc", "-n", "k3sm-builder", "-o", "json"]
    /// The Services tab: every Service and Ingress, across namespaces.
    public static let servicesArguments = ["kubectl", "get", "svc,ingress", "-A", "-o", "json"]
    /// The Services tab's endpoint read: every EndpointSlice, across
    /// namespaces, read after the service list on the tab's cadence and
    /// counted per Service (`ServicesList.endpointCounts`).
    public static let endpointSlicesArguments = ["kubectl", "get", "endpointslices", "-A", "-o", "json"]
    /// The Storage tab's list: every volume claim and volume.
    public static let storageArguments = ["kubectl", "get", "pvc,pv", "-A", "-o", "json"]
    /// The Storage tab's card: this Mac's data volume, from the CLI itself;
    /// it needs no privilege.
    public static let dataVolumeArguments = ["datavol", "status", "-o", "json"]
    /// The Models tab: every MLXModel, by the resource's full name.
    public static let modelsArguments = ["kubectl", "get", ModelsList.resource, "-A", "-o", "json"]
    /// Whether the cluster serves the MLX API, read only after the models
    /// list failed (`ModelsList.needsDiscovery`).
    public static let modelsDiscoveryArguments = ["kubectl", "api-resources", "--api-group=mlx.k3sm.io", "-o", "name"]
    /// The Events view: every Event, across namespaces.
    public static let eventsArguments = ["kubectl", "get", "events", "-A", "-o", "json"]
    /// The live load: metrics-server's node and pod samples, read raw from
    /// the metrics API through the same bundled kubectl.
    public static let nodeMetricsArguments = ["kubectl", "get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes"]
    public static let podMetricsArguments = ["kubectl", "get", "--raw", "/apis/metrics.k8s.io/v1beta1/pods"]
    /// Whether the metrics API is served, read only after the node read failed.
    public static let metricsAPIServiceArguments = ["kubectl", "get", "apiservice", "v1beta1.metrics.k8s.io", "-o", "json"]
    /// The most log lines a detail call asks for.
    public static let logTail = 200

    /// The last `logTail` lines of every container of one pod.
    public static func logsArguments(namespace: ResourceName, pod: ResourceName) -> [String] {
        ["kubectl", "logs", "-n", namespace.value, pod.value, "--tail=\(logTail)", "--all-containers"]
    }

    /// The events recorded against one pod, oldest first.
    public static func eventsArguments(namespace: ResourceName, pod: ResourceName) -> [String] {
        ["kubectl", "get", "events", "-n", namespace.value, "--field-selector", "involvedObject.name=\(pod.value)",
         "--sort-by=.lastTimestamp", "-o", "custom-columns=AGE:.lastTimestamp,TYPE:.type,REASON:.reason,MESSAGE:.message"]
    }

    /// One pod as the API server holds it.
    public static func manifestArguments(namespace: ResourceName, pod: ResourceName) -> [String] {
        ["kubectl", "get", "pod", "-n", namespace.value, pod.value, "-o", "yaml"]
    }

    /// Deletes one pod without waiting for it to go: the console's first
    /// write, run through the same bundled kubectl and the kubeconfig the CLI
    /// presets as every read. Only `ResourceName` values reach it, so neither
    /// name can carry an option, a selector or a path.
    public static func deletePodArguments(namespace: ResourceName, pod: ResourceName) -> [String] {
        ["kubectl", "delete", "pod", pod.value, "-n", namespace.value, "--wait=false"]
    }

    /// One pod's UID, read just before a console action so the action runs
    /// only on the pod the user confirmed.
    public static func podUIDArguments(namespace: ResourceName, pod: ResourceName) -> [String] {
        ["kubectl", "get", "pod", pod.value, "-n", namespace.value, "-o", "jsonpath={.metadata.uid}"]
    }

    /// Deletes one Service without waiting for it to go, the Services tab's
    /// Delete. Only `ResourceName` values reach it.
    public static func deleteServiceArguments(namespace: ResourceName, service: ResourceName) -> [String] {
        ["kubectl", "delete", "service", service.value, "-n", namespace.value, "--wait=false"]
    }

    /// One Service's UID, read just before its Delete so it runs only on the
    /// Service the user confirmed.
    public static func serviceUIDArguments(namespace: ResourceName, service: ResourceName) -> [String] {
        ["kubectl", "get", "service", service.value, "-n", namespace.value, "-o", "jsonpath={.metadata.uid}"]
    }

    /// Deletes several pods of one namespace in one run, without waiting:
    /// the Workloads cleanup, one run per namespace. Only `ResourceName`
    /// values reach it.
    public static func deletePodsArguments(namespace: ResourceName, pods: [ResourceName]) -> [String] {
        ["kubectl", "delete", "pod"] + pods.map(\.value) + ["-n", namespace.value, "--wait=false"]
    }

    /// Every pod's "namespace/name uid", one per line, read just before the
    /// cleanup so it deletes only the pods the user confirmed.
    public static let podUIDsArguments = [
        "kubectl", "get", "pods", "-A", "-o",
        #"jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.uid}{"\n"}{end}"#,
    ]

    /// One MLXModel's UID, read just before a Models tab action so the
    /// action runs only on the model the user confirmed.
    public static func modelUIDArguments(namespace: ResourceName, model: ResourceName) -> [String] {
        ["kubectl", "get", ModelsList.resource, model.value, "-n", namespace.value, "-o", "jsonpath={.metadata.uid}"]
    }

    /// Unloads or loads one MLXModel: one JSON merge patch that sets
    /// `spec.replicas` and the recorded count's annotation together
    /// (`ModelActions.patch`). The CRD has no scale subresource, so
    /// `kubectl scale` is not an option. Nil only when the patch cannot be
    /// serialised.
    public static func modelScaleArguments(namespace: ResourceName, model: ResourceName, scale: ModelScale) -> [String]? {
        guard let patch = ModelActions.patch(scale) else { return nil }
        return ["kubectl", "patch", ModelsList.resource, model.value, "-n", namespace.value, "--type=merge", "-p", patch]
    }

    /// Deletes one MLXModel without waiting for it to go; its operator
    /// removes what it rendered for it.
    public static func deleteModelArguments(namespace: ResourceName, model: ResourceName) -> [String] {
        ["kubectl", "delete", ModelsList.resource, model.value, "-n", namespace.value, "--wait=false"]
    }

    /// The PATH every CLI run gets: system directories only.
    public static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Builds the CLI's whole environment from the user's passwd entry. A home
    /// that is not an absolute path is replaced by /var/empty, so the CLI never
    /// resolves `~` against the working directory.
    public static func environment(home: String, user: String) -> [String: String] {
        let safeHome = home.hasPrefix("/") ? home : "/var/empty"
        return [
            "HOME": safeHome,
            "USER": user,
            "LOGNAME": user,
            "PATH": systemPath,
        ]
    }
}

/// PollSchedule is the visibility poll's cadence: 5 s while the status item is
/// shown, 15 s while it is hidden, and a 4 s deadline after which a run is
/// killed. The poller starts the next run only after the previous one exits.
public enum PollSchedule {
    public static let visibleInterval: Duration = .seconds(5)
    public static let hiddenInterval: Duration = .seconds(15)
    public static let killDeadline: Duration = .seconds(4)
    /// The deadline for the console's pod and node list reads. It is longer
    /// than `killDeadline` because those reads go through kubectl to the API
    /// server, on a worker across the network, and return every pod in the
    /// cluster; the 4 s budget is sized for the local status probe, and a
    /// slow but healthy list killed at 4 s would read as a CLI that did not
    /// answer. It stays under `consoleReportInterval`, and `PollGate` keeps
    /// the console's runs serial, so a slow list delays the next poll
    /// without stacking runs.
    public static let listDeadline: Duration = .seconds(10)
    /// The wait between full status reads while the console window is open.
    public static let consoleReportInterval: Duration = .seconds(30)

    /// The wait before the next poll, chosen by whether the item is shown.
    public static func interval(visible: Bool) -> Duration {
        visible ? visibleInterval : hiddenInterval
    }

    /// The Images tab's cadence: images change only when one is pulled,
    /// loaded or removed.
    public static let imagesInterval: Duration = .seconds(15)
    /// The cadence of the Services, Storage and Models tabs: objects that
    /// change when someone applies a manifest.
    public static let objectsInterval: Duration = .seconds(15)
    /// The Events view's cadence, the pod list's own.
    public static let eventsInterval: Duration = .seconds(5)
    /// The Builds tab's cadence once the engine is ready; until then it is
    /// read at `visibleInterval`, so a starting engine is seen when it serves.
    public static let buildsReadyInterval: Duration = .seconds(15)

    /// The managed update's progress cadence while it is read.
    public static let updateStatusInterval: Duration = .seconds(5)

    /// The pod list's cadence while the console is open but another tab is
    /// selected: the navy panel's pod counts and meters come from it, so it
    /// keeps reading, slowly, rather than freezing.
    public static let backgroundInterval: Duration = .seconds(30)

    /// The pod list's cadence: the Workloads tab's when it is selected,
    /// `backgroundInterval` otherwise.
    public static func podsInterval(selected: Bool) -> Duration {
        selected ? interval(for: .workloads, engineReady: false) : backgroundInterval
    }

    /// The age the panel shows beside its state line: the pod list's read
    /// age once it is older than one `backgroundInterval` (a read that is
    /// late or failing), nil while it is current or before the first read.
    public static func panelAge(podsReadAt: Date?, now: Date = Date()) -> String? {
        guard let podsReadAt else { return nil }
        let late = Double(backgroundInterval.components.seconds)
        guard now.timeIntervalSince(podsReadAt) > late else { return nil }
        return TabLoad.age(since: podsReadAt, now: now)
    }

    /// The wait between a console tab's reads while it is selected:
    /// Workloads at `visibleInterval`, as before tabs; Images at
    /// `imagesInterval`; Builds at `visibleInterval` until the engine is
    /// ready, then `buildsReadyInterval`; Services, Storage and Models at
    /// `objectsInterval`. The shared node list follows the selected tab's
    /// cadence too.
    public static func interval(for section: ConsoleSection, engineReady: Bool) -> Duration {
        switch section {
        case .workloads: return visibleInterval
        case .images: return imagesInterval
        case .builds: return engineReady ? buildsReadyInterval : visibleInterval
        case .services, .storage, .models: return objectsInterval
        }
    }
}

/// PollGate keeps one model's list reads serial: at most one run is in
/// flight, and a run asked for meanwhile (a Refresh during a poll) is
/// coalesced into one more run after the current one, however many times it
/// is asked for. The caller calls `begin()` before a run and `finish()` after
/// each, running again while `finish()` says so.
public struct PollGate: Equatable, Sendable {
    public private(set) var running = false
    public private(set) var pending = false

    public init() {}

    /// True when the caller runs now; false when a run is in flight, which
    /// then runs once more when it finishes.
    public mutating func begin() -> Bool {
        if running {
            pending = true
            return false
        }
        running = true
        return true
    }

    /// True when a run was asked for during this one, and the caller runs
    /// again; false when the gate is free.
    public mutating func finish() -> Bool {
        if pending {
            pending = false
            return true
        }
        running = false
        return false
    }
}

/// StatusDisplay limits how much status text the app renders. Every string
/// from the CLI is data: it is shown verbatim, with control characters
/// replaced and format characters removed, clipped to a fixed length, and
/// capped to a fixed row count.
public enum StatusDisplay {
    public static let maxRows = 24
    public static let maxLength = 160

    /// Returns the text safe to show on one line: a character holding a
    /// control or line-separator character becomes a space, format
    /// characters (bidirectional overrides and isolates, zero-width
    /// characters) are removed, and anything past `maxLength` characters
    /// becomes an ellipsis. A workload author controls image names, owners
    /// and kubelet reasons, so none of them may reorder or hide what is
    /// shown around them.
    public static func clip(_ text: String) -> String {
        var flat = ""
        for character in text {
            let scalars = character.unicodeScalars
            if scalars.contains(where: { breaksLine($0) }) {
                flat.append(" ")
                continue
            }
            var kept = String.UnicodeScalarView()
            kept.append(contentsOf: scalars.filter { $0.properties.generalCategory != .format })
            flat.append(contentsOf: String(kept))
        }
        guard flat.count > maxLength else { return flat }
        return String(flat.prefix(maxLength - 1)) + "…"
    }

    /// Returns cluster output safe to show as a block of text (the
    /// inspector's logs, events and manifest): line breaks and tabs are kept,
    /// a carriage return or a line or paragraph separator becomes a line
    /// break, other control characters are removed, and format characters are
    /// removed as in `clip`. The caller has already capped the length.
    public static func body(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var afterReturn = false
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            defer { afterReturn = scalar == "\r" }
            switch scalar {
            case "\n":
                if !afterReturn { scalars.append(scalar) }
            case "\t":
                scalars.append(scalar)
            case "\r", "\u{2028}", "\u{2029}":
                scalars.append("\n")
            default:
                if category == .control || category == .format { continue }
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// breaksLine is whether `scalar` would break or rewrite a single line:
    /// a control character or a line or paragraph separator.
    private static func breaksLine(_ scalar: Unicode.Scalar) -> Bool {
        let category = scalar.properties.generalCategory
        return category == .control || category == .lineSeparator || category == .paragraphSeparator
    }

    /// The most characters of a CLI error message the app shows.
    public static let maxErrorLength = 300

    /// Returns a CLI error message safe to show: control and format
    /// characters (bidirectional overrides included) are removed, runs of
    /// whitespace become one space, and anything past `maxErrorLength`
    /// characters becomes an ellipsis.
    public static func errorText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            if scalar.properties.isWhitespace || category == .control || category == .lineSeparator || category == .paragraphSeparator {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if category == .format { continue }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        let flat = String(scalars)
        guard flat.count > maxErrorLength else { return flat }
        return String(flat.prefix(maxErrorLength - 1)) + "…"
    }

    /// Returns at most `maxRows` rows with every field clipped. A
    /// `needs-admin` row's detail is `rowDetail`'s sentence.
    public static func rows(of report: StatusReport) -> [StatusRow] {
        report.rows.prefix(maxRows).map {
            StatusRow(name: clip($0.name), state: clip($0.state), detail: rowDetail($0), remedy: clip($0.remedy))
        }
    }
}
