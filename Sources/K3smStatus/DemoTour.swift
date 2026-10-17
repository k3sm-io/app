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

/// DemoTour is the scripted demo mode's pure half: the tour file's closed
/// step set, its parser and validator, the conditions a step waits for, the
/// rows a step selects, and where a tour file may live. The app's
/// `--demo-tour <file>` launch argument reads a tour, refuses it whole before
/// anything runs when one step is unknown, malformed, out of order or names
/// an action that is not a read, then walks the console through it with its
/// own controls and quits. Nothing in the set reaches a change to the
/// cluster or the root step: the only CLI runs a tour makes are the reads the
/// console already makes (the pod list, the node list, the model list, and a
/// pod's logs, events or manifest).
public enum DemoTour {
    /// The launch argument that names a tour file.
    public static let argument = "--demo-tour"
    /// The directory a checkout keeps its tours in, relative to its root,
    /// and the one inside the bundle's Resources.
    public static let checkoutDirectory = "hack/demo"
    public static let resourcesDirectory = "demo"
    /// The largest tour file read, and the most steps one may hold.
    public static let maxBytes = 64 * 1024
    public static let maxSteps = 200
    /// The longest one step's text may be.
    public static let maxLineLength = 200
    /// The bounds of a pause and of a wait, in seconds, and a wait's default.
    public static let maxPause: Double = 60
    public static let maxWait: Double = 900
    public static let defaultWait: Double = 120
    /// How long a `selectRow` waits for its row to be listed.
    public static let rowWait: Double = 30
    /// How long the tour waits for the console to come on screen first.
    public static let consoleWait: Double = 60
    /// How often a wait reads again.
    public static let pollInterval: Double = 2
    /// The bounds of `windowFrame`'s size, in points.
    public static let minWidth: Double = 400, minHeight: Double = 300, maxSide: Double = 8192

    /// ReadAction is the closed set `runRead` takes: the reads the console
    /// already offers. Logs, Events and Manifest are the inspector's detail
    /// tabs for the selected pod; refresh reads the node list and the
    /// selected tab again. None of them changes anything.
    public enum ReadAction: String, CaseIterable, Sendable {
        case logs, events, manifest, refresh

        /// The CLI arguments the read runs for a pod, or nil for refresh,
        /// which runs the tab's own list reads.
        public func arguments(namespace: ResourceName, pod: ResourceName) -> [String]? {
            switch self {
            case .logs: return K3smCLI.logsArguments(namespace: namespace, pod: pod)
            case .events: return K3smCLI.eventsArguments(namespace: namespace, pod: pod)
            case .manifest: return K3smCLI.manifestArguments(namespace: namespace, pod: pod)
            case .refresh: return nil
            }
        }

        /// Whether the read needs a selected pod.
        public var needsPod: Bool { self != .refresh }
    }

    /// NameMatch is a row name as a step writes it: exact, or a prefix
    /// written with a trailing `*` (a StatefulSet's pod, whose ordinal the
    /// tour does not know).
    public enum NameMatch: Equatable, Sendable {
        case exact(String)
        case prefix(String)

        public func matches(_ name: String) -> Bool {
            switch self {
            case .exact(let n): return name == n
            case .prefix(let p): return name.hasPrefix(p)
            }
        }

        var text: String {
            switch self {
            case .exact(let n): return n
            case .prefix(let p): return p + "*"
            }
        }

        /// Parses `name` or `prefix*`; nil unless the name, or the prefix
        /// with a character after it, is one `ResourceName` accepts.
        static func parse(_ text: String) -> NameMatch? {
            if text.hasSuffix("*") {
                let p = String(text.dropLast())
                guard !p.isEmpty, !p.contains("*"), ResourceName(p + "0") != nil else { return nil }
                return .prefix(p)
            }
            return ResourceName(text) == nil ? nil : .exact(text)
        }
    }

    /// PodMatch is a pod as a step names it: its namespace and its name.
    public struct PodMatch: Equatable, Sendable {
        public let namespace: String
        public let name: NameMatch

        public func matches(_ pod: Pod) -> Bool {
            pod.namespace == namespace && name.matches(pod.name)
        }

        var text: String { "\(namespace)/\(name.text)" }

        static func parse(_ text: String) -> PodMatch? {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, ResourceName(parts[0]) != nil, let name = NameMatch.parse(parts[1]) else { return nil }
            return PodMatch(namespace: parts[0], name: name)
        }
    }

    /// NodeMatch is a node as a step names it: by name, or `@server`, the
    /// control-plane node, so a checked-in tour names no machine.
    public enum NodeMatch: Equatable, Sendable {
        case name(String)
        case server
    }

    /// RowTarget is the row `selectRow` selects, on its own tab.
    public enum RowTarget: Equatable, Sendable {
        case pod(PodMatch)
        case node(NodeMatch)

        public var section: ConsoleSection {
            switch self {
            case .pod: return .workloads
            case .node: return .nodes
            }
        }
    }

    /// Condition is the closed set `waitFor` takes.
    public enum Condition: Equatable, Sendable {
        /// The MLXModel `namespace/name` reports the Ready phase.
        case modelReady(namespace: String, name: String)
        /// A pod the match names is Running with every container ready.
        case podRunning(PodMatch)
        /// At least this many nodes report Ready.
        case nodesReady(Int)
    }

    /// Frame is a window frame as `windowFrame` writes it: the top-left
    /// corner from the main screen's top-left, and the size, in points.
    public struct Frame: Equatable, Sendable {
        public let x: Double, y: Double, width: Double, height: Double
    }

    /// Step is one step of a tour.
    public enum Step: Equatable, Sendable {
        case selectTab(ConsoleSection)
        case selectWorkloadsView(WorkloadsView)
        case selectRow(RowTarget)
        case openInspector
        case closeInspector
        case runRead(ReadAction)
        case waitFor(Condition, timeout: Double)
        case pause(Double)
        case windowFrame(Frame)
        case end
    }

    /// Entry is one parsed step and the text it came from, for the failure line.
    public struct Entry: Equatable, Sendable {
        public let line: String
        public let step: Step
    }

    /// TourError is why a tour was refused before it ran.
    public enum TourError: Error, Equatable, Sendable {
        case tooLarge
        case notATour
        case noSteps
        case tooManySteps
        case badLine(index: Int)
        case unknownStep(index: Int, verb: String)
        case notARead(index: Int, name: String)
        case unknownCondition(index: Int, name: String)
        case badArgument(index: Int, step: String, why: String)
        case outOfOrder(index: Int, step: String, why: String)
        case missingEnd

        /// The line printed on standard error; every name in it is clipped.
        public var message: String {
            switch self {
            case .tooLarge: return "the tour file is larger than \(DemoTour.maxBytes / 1024) KiB"
            case .notATour: return "the tour file is not a JSON object with a \"steps\" list of strings"
            case .noSteps: return "the tour has no steps"
            case .tooManySteps: return "the tour has more than \(DemoTour.maxSteps) steps"
            case .badLine(let i): return "step \(i): not one line of at most \(DemoTour.maxLineLength) printable characters"
            case .unknownStep(let i, let verb): return "step \(i): unknown step \"\(StatusDisplay.clip(verb))\""
            case .notARead(let i, let name):
                return "step \(i): \"\(StatusDisplay.clip(name))\" is not a read-only action; runRead takes \(ReadAction.allCases.map(\.rawValue).joined(separator: ", "))"
            case .unknownCondition(let i, let name): return "step \(i): unknown condition \"\(StatusDisplay.clip(name))\""
            case .badArgument(let i, let step, let why): return "step \(i) (\(StatusDisplay.clip(step))): \(why)"
            case .outOfOrder(let i, let step, let why): return "step \(i) (\(StatusDisplay.clip(step))): \(why)"
            case .missingEnd: return "the tour does not finish with end"
            }
        }
    }

    // MARK: parsing

    /// Parses and validates a tour file: a JSON object whose `steps` is a
    /// list of step lines (an optional `about` string is a comment). It
    /// throws on the first problem, so nothing of a refused tour runs.
    public static func parse(_ data: Data) throws -> [Entry] {
        guard data.count <= maxBytes else { throw TourError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["steps", "about"]),
              object["about"] == nil || object["about"] is String,
              let lines = object["steps"] as? [Any] else { throw TourError.notATour }
        guard !lines.isEmpty else { throw TourError.noSteps }
        guard lines.count <= maxSteps else { throw TourError.tooManySteps }
        var entries: [Entry] = []
        for (n, any) in lines.enumerated() {
            guard let line = any as? String else { throw TourError.notATour }
            entries.append(Entry(line: line, step: try step(line, index: n + 1)))
        }
        try validate(entries.map(\.step))
        return entries
    }

    /// Parses one step line. Words are separated by spaces.
    public static func step(_ line: String, index i: Int) throws -> Step {
        guard !line.isEmpty, line.count <= maxLineLength,
              line.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { throw TourError.badLine(index: i) }
        let words = line.split(separator: " ").map(String.init)
        guard let verb = words.first else { throw TourError.badLine(index: i) }
        let args = Array(words.dropFirst())
        func bad(_ why: String) -> TourError { .badArgument(index: i, step: line, why: why) }
        func count(_ n: Int) throws {
            guard args.count == n else { throw bad(n == 0 ? "takes no argument" : "takes \(n) argument\(n == 1 ? "" : "s")") }
        }
        switch verb {
        case "selectTab":
            try count(1)
            guard let s = ConsoleSection(rawValue: args[0]) else {
                throw bad("the tab is one of \(ConsoleSection.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .selectTab(s)
        case "selectWorkloadsView":
            try count(1)
            guard let v = WorkloadsView(rawValue: args[0]) else {
                throw bad("the view is one of \(WorkloadsView.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .selectWorkloadsView(v)
        case "selectRow":
            try count(2)
            switch args[0] {
            case "pod":
                guard let m = PodMatch.parse(args[1]) else { throw bad("a pod is namespace/name or namespace/prefix*") }
                return .selectRow(.pod(m))
            case "node":
                if args[1] == "@server" { return .selectRow(.node(.server)) }
                guard ResourceName(args[1]) != nil else { throw bad("a node is its name or @server") }
                return .selectRow(.node(.name(args[1])))
            default:
                throw bad("the row kind is pod or node")
            }
        case "openInspector":
            try count(0)
            return .openInspector
        case "closeInspector":
            try count(0)
            return .closeInspector
        case "runRead":
            try count(1)
            guard let r = ReadAction(rawValue: args[0]) else { throw TourError.notARead(index: i, name: args[0]) }
            return .runRead(r)
        case "waitFor":
            guard args.count == 2 || args.count == 3 else { throw bad("takes a condition, its argument and an optional timeout") }
            var timeout = defaultWait
            if args.count == 3 {
                guard let t = seconds(args[2]), t >= 1, t <= maxWait else { throw bad("the timeout is 1 to \(Int(maxWait)) seconds") }
                timeout = t
            }
            switch args[0] {
            case "modelReady":
                guard let m = PodMatch.parse(args[1]), case .exact(let name) = m.name else { throw bad("a model is namespace/name") }
                return .waitFor(.modelReady(namespace: m.namespace, name: name), timeout: timeout)
            case "podRunning":
                guard let m = PodMatch.parse(args[1]) else { throw bad("a pod is namespace/name or namespace/prefix*") }
                return .waitFor(.podRunning(m), timeout: timeout)
            case "nodesReady":
                guard let n = Int(args[1]), n >= 1, n <= 64 else { throw bad("the node count is 1 to 64") }
                return .waitFor(.nodesReady(n), timeout: timeout)
            default:
                throw TourError.unknownCondition(index: i, name: args[0])
            }
        case "pause":
            try count(1)
            guard let s = seconds(args[0]), s > 0, s <= maxPause else { throw bad("a pause is more than 0 and at most \(Int(maxPause)) seconds") }
            return .pause(s)
        case "windowFrame":
            try count(4)
            let v = args.compactMap { Int($0) }.map(Double.init)
            guard v.count == 4, v[0] >= 0, v[1] >= 0, v[0] <= maxSide, v[1] <= maxSide,
                  v[2] >= minWidth, v[3] >= minHeight, v[2] <= maxSide, v[3] <= maxSide else {
                throw bad("the frame is x y width height in whole points, at least \(Int(minWidth)) by \(Int(minHeight))")
            }
            return .windowFrame(Frame(x: v[0], y: v[1], width: v[2], height: v[3]))
        case "end":
            try count(0)
            return .end
        default:
            throw TourError.unknownStep(index: i, verb: verb)
        }
    }

    /// A decimal number of seconds, nil for anything else.
    static func seconds(_ text: String) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), let v = Double(text), v.isFinite else { return nil }
        return v
    }

    /// Checks the order: a row is selected only on its own tab, chosen
    /// earlier in the tour (a pod on the Workloads tab's Pods view, also
    /// chosen earlier, since a fresh launch restores whatever was last
    /// shown); a pod read follows a pod the tour selected, with Workloads
    /// still shown; and `end` is the last step and only there.
    public static func validate(_ steps: [Step]) throws {
        var tab: ConsoleSection?
        var view: WorkloadsView?
        var podSelected = false
        for (n, step) in steps.enumerated() {
            let i = n + 1
            func order(_ why: String) -> TourError { .outOfOrder(index: i, step: describe(step), why: why) }
            switch step {
            case .selectTab(let s):
                tab = s
            case .selectWorkloadsView(let v):
                guard tab == .workloads else { throw order("the Workloads tab is not selected") }
                view = v
            case .selectRow(let target):
                guard tab == target.section else { throw order("its row's tab, \(target.section.rawValue), is not selected") }
                if case .pod = target {
                    guard view == .pods else { throw order("the Workloads tab's pods view is not selected") }
                    podSelected = true
                }
            case .runRead(let r):
                if r.needsPod {
                    guard podSelected, tab == .workloads, view == .pods else { throw order("no pod is selected on the Workloads tab") }
                }
            case .end:
                guard n == steps.count - 1 else { throw order("end is the last step") }
            case .openInspector, .closeInspector, .waitFor, .pause, .windowFrame:
                break
            }
        }
        guard steps.last == .end else { throw TourError.missingEnd }
    }

    /// A step as a tour line, for the failure line.
    public static func describe(_ step: Step) -> String {
        switch step {
        case .selectTab(let s): return "selectTab \(s.rawValue)"
        case .selectWorkloadsView(let v): return "selectWorkloadsView \(v.rawValue)"
        case .selectRow(.pod(let m)): return "selectRow pod \(m.text)"
        case .selectRow(.node(.server)): return "selectRow node @server"
        case .selectRow(.node(.name(let n))): return "selectRow node \(n)"
        case .openInspector: return "openInspector"
        case .closeInspector: return "closeInspector"
        case .runRead(let r): return "runRead \(r.rawValue)"
        case .waitFor(let c, let t):
            let what: String
            switch c {
            case .modelReady(let ns, let name): what = "modelReady \(ns)/\(name)"
            case .podRunning(let m): what = "podRunning \(m.text)"
            case .nodesReady(let n): what = "nodesReady \(n)"
            }
            return "waitFor \(what) \(Int(t))"
        case .pause(let s): return "pause \(s)"
        case .windowFrame(let f): return "windowFrame \(Int(f.x)) \(Int(f.y)) \(Int(f.width)) \(Int(f.height))"
        case .end: return "end"
        }
    }

    // MARK: running

    /// The pod a match selects: the first listed, by name.
    public static func pod(_ match: PodMatch, in pods: [Pod]) -> Pod? {
        pods.filter(match.matches).min { $0.name < $1.name }
    }

    /// The node a match selects: the named one, or the control-plane node
    /// (the first by name when there are several servers).
    public static func node(_ match: NodeMatch, in nodes: [ClusterNode]) -> ClusterNode? {
        switch match {
        case .name(let n): return nodes.first { $0.name == n }
        case .server: return nodes.filter(\.controlPlane).min { $0.name < $1.name }
        }
    }

    /// Whether a condition holds over the last reads; a read not made yet
    /// (nil) holds nothing.
    public static func met(_ condition: Condition, pods: [Pod]?, models: [ModelRow]?, nodes: [ClusterNode]?) -> Bool {
        switch condition {
        case .modelReady(let ns, let name):
            return models?.contains { $0.namespace == ns && $0.name == name && $0.phase == "Ready" } ?? false
        case .podRunning(let m):
            return pods?.contains { m.matches($0) && $0.phase == "Running" && $0.ready } ?? false
        case .nodesReady(let n):
            return (nodes?.filter { $0.ready == true }.count ?? 0) >= n
        }
    }

    /// How long a step's change of layout animates: nil under Reduce
    /// Motion, so the console changes at once.
    public static func animation(reduceMotion: Bool) -> Double? {
        reduceMotion ? nil : 0.3
    }

    /// The window's frame in AppKit's coordinates (origin at the main
    /// screen's bottom left) for a step's top-left frame on a main screen
    /// `screenHeight` points tall.
    public static func appKitFrame(_ f: Frame, screenHeight: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        (f.x, screenHeight - f.y - f.height, f.width, f.height)
    }

    /// The line printed on standard error when a step fails while the tour
    /// runs; the reason is the app's own sentence, clipped.
    public static func failureLine(index: Int, step: Step, reason: String) -> String {
        "k3sm demo tour: step \(index) (\(describe(step))) failed: \(StatusDisplay.clip(reason))"
    }

    // MARK: the launch argument

    /// LaunchError is why the launch argument was refused.
    public enum LaunchError: Error, Equatable, Sendable {
        case missingPath
        case repeated
        case outside(String)

        public var message: String {
            switch self {
            case .missingPath: return "\(DemoTour.argument) needs a tour file"
            case .repeated: return "\(DemoTour.argument) is given more than once"
            case .outside(let path):
                return "\(StatusDisplay.clip(path)) is not in the checkout's \(DemoTour.checkoutDirectory) or the app's Resources/\(DemoTour.resourcesDirectory)"
            }
        }
    }

    /// The tour file the launch arguments name, nil when there is none.
    public static func path(in arguments: [String]) throws -> String? {
        let at = arguments.indices.filter { arguments[$0] == argument }
        guard let i = at.first else { return nil }
        guard at.count == 1 else { throw LaunchError.repeated }
        guard i + 1 < arguments.count, !arguments[i + 1].isEmpty, !arguments[i + 1].hasPrefix("-") else { throw LaunchError.missingPath }
        return arguments[i + 1]
    }

    /// The directories a tour may be read from: the bundle's Resources/demo,
    /// and the hack/demo of the nearest checkout above the executable (the
    /// first ancestor `isCheckout` accepts). Paths are standardized and
    /// their links resolved by the caller.
    public static func allowedDirectories(executable: URL, resources: URL?, isCheckout: (URL) -> Bool) -> [URL] {
        var dirs: [URL] = []
        if let resources { dirs.append(resources.appendingPathComponent(resourcesDirectory, isDirectory: true).standardizedFileURL) }
        var dir = executable.deletingLastPathComponent().standardizedFileURL
        while dir.path != "/" {
            if isCheckout(dir) {
                dirs.append(dir.appendingPathComponent(checkoutDirectory, isDirectory: true).standardizedFileURL)
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        return dirs
    }

    /// Whether `file` (standardized, its links resolved) sits directly in
    /// one of `directories`, so a stray argument cannot point the app at
    /// any other file.
    public static func permits(_ file: URL, in directories: [URL]) -> Bool {
        let parent = file.standardizedFileURL.deletingLastPathComponent().path
        let normal = { (u: URL) -> String in
            let p = u.standardizedFileURL.path
            return p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p
        }
        return file.pathExtension == "json" && directories.contains { normal($0) == normal(URL(fileURLWithPath: parent)) }
    }
}
