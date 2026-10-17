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
import Testing
@testable import K3smStatus

/// The B686 gate: the demo tour's closed step set, its refusals, its closed
/// condition set and its ordering. Every test name starts with
/// `demoTourSteps`, so the gate's filter runs them all.
@Suite("the scripted demo tour")
struct DemoTourTests {
    static func tour(_ steps: [String]) throws -> [DemoTour.Entry] {
        let data = try JSONSerialization.data(withJSONObject: ["steps": steps])
        return try DemoTour.parse(data)
    }

    static func refusal(_ steps: [String]) -> DemoTour.TourError? {
        do {
            _ = try tour(steps)
            return nil
        } catch let e as DemoTour.TourError {
            return e
        } catch {
            return nil
        }
    }

    static let qwen = DemoTour.PodMatch(namespace: "default", name: .prefix("qwen3-06b-"))

    @Test("the checked-in release tour parses into the recording's walk, about 40 seconds of pauses")
    func demoTourSteps() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hack/demo/release-tour.json")
        let entries = try DemoTour.parse(Data(contentsOf: url))
        #expect(entries.map(\.step) == [
            .windowFrame(.init(x: 80, y: 60, width: 1280, height: 800)),
            .closeInspector,
            .selectTab(.workloads),
            .selectWorkloadsView(.pods),
            .waitFor(.podRunning(Self.qwen), timeout: 120),
            .pause(2),
            .selectRow(.pod(Self.qwen)),
            .openInspector,
            .runRead(.logs),
            .pause(10),
            .selectTab(.stats),
            .pause(10),
            .selectTab(.nodes),
            .selectRow(.node(.server)),
            .openInspector,
            .pause(10),
            .end,
        ])
        let paused = entries.reduce(0.0) { sum, e in
            if case .pause(let s) = e.step { return sum + s }
            return sum
        }
        #expect(paused >= 30 && paused <= 45)
        // Every line reads back as the step it parsed to.
        for e in entries { #expect(DemoTour.describe(e.step) == e.line || e.line.hasPrefix("pause")) }
    }

    @Test("an unknown step, a malformed line or a malformed file is refused before anything runs")
    func demoTourStepsRefuseUnknown() {
        #expect(Self.refusal(["click 10 10", "end"]) == .unknownStep(index: 1, verb: "click"))
        #expect(Self.refusal(["selectTab workloads", "deletePod default/x", "end"]) == .unknownStep(index: 2, verb: "deletePod"))
        #expect(Self.refusal(["uninstall", "end"]) == .unknownStep(index: 1, verb: "uninstall"))
        #expect(Self.refusal(["selectTab settings", "end"]) != nil)
        #expect(Self.refusal(["selectTab", "end"]) != nil)
        #expect(Self.refusal(["openInspector now", "end"]) != nil)
        #expect(Self.refusal(["pause 0", "end"]) != nil)
        #expect(Self.refusal(["pause 61", "end"]) != nil)
        #expect(Self.refusal(["pause -1", "end"]) != nil)
        #expect(Self.refusal(["pause 1e3", "end"]) != nil)
        #expect(Self.refusal(["windowFrame 0 0 100 100", "end"]) != nil)
        #expect(Self.refusal(["windowFrame 0 0 1280", "end"]) != nil)
        #expect(Self.refusal(["selectTab workloads\nend", "end"]) == .badLine(index: 1))
        #expect(Self.refusal(["", "end"]) == .badLine(index: 1))
        #expect(Self.refusal(["selectTab nodes", "selectRow node --all", "end"]) != nil)
        #expect(Self.refusal(["selectTab workloads", "selectWorkloadsView pods", "selectRow pod default/a*b*", "end"]) != nil)
        #expect(Self.refusal(["selectTab workloads", "selectWorkloadsView owners", "end"]) != nil)
        #expect(Self.refusal([]) == .noSteps)
        #expect(Self.refusal(Array(repeating: "pause 1", count: DemoTour.maxSteps) + ["end"]) == .tooManySteps)
        #expect(throws: DemoTour.TourError.notATour) { try DemoTour.parse(Data("[\"end\"]".utf8)) }
        #expect(throws: DemoTour.TourError.notATour) { try DemoTour.parse(Data("{\"steps\":[\"end\"],\"run\":\"x\"}".utf8)) }
        #expect(throws: DemoTour.TourError.notATour) { try DemoTour.parse(Data("{\"steps\":[1]}".utf8)) }
        #expect(throws: DemoTour.TourError.notATour) { try DemoTour.parse(Data("not json".utf8)) }
        #expect(throws: DemoTour.TourError.tooLarge) { try DemoTour.parse(Data(count: DemoTour.maxBytes + 1)) }
    }

    @Test("runRead takes only reads: no console action of any tab is reachable")
    func demoTourStepsRefuseMutating() throws {
        // Every action every tab offers, by its enum and by the verb its
        // request logs. ActionKind has only delete and change: no console
        // action is a read, so none may be in the tour's set.
        var names = Set<String>()
        names.formUnion(PodAction.allCases.map(\.rawValue))
        names.formUnion(NodeAction.allCases.flatMap { [$0.rawValue, "node-\($0.rawValue)"] })
        names.formUnion(ModelAction.allCases.flatMap { [$0.rawValue, "model-\($0.rawValue)"] })
        names.formUnion(ServiceAction.allCases.flatMap { [$0.rawValue, "service-\($0.rawValue)"] })
        names.formUnion(BuildAction.allCases.flatMap { [$0.rawValue, "build-\($0.rawValue)"] })
        names.formUnion(BuildEngineAction.allCases.flatMap { [$0.rawValue, "builder-\($0.rawValue)"] })
        names.formUnion(["delete-claim", "delete-volumes", "cleanup", "start", "stop", "restart", "install", "uninstall", "update"])
        #expect(names.count > 10)
        let reads = Set(DemoTour.ReadAction.allCases.map(\.rawValue))
        #expect(reads.isDisjoint(with: names))
        for name in names.sorted() {
            #expect(Self.refusal(["selectTab workloads", "selectWorkloadsView pods", "selectRow pod a/b", "runRead \(name)", "end"])
                    == .notARead(index: 4, name: name), "runRead \(name)")
        }
        // Each read's command line only gets or reads logs.
        let ns = try #require(ResourceName("default")), pod = try #require(ResourceName("qwen3-06b-0"))
        for read in DemoTour.ReadAction.allCases {
            guard let argv = read.arguments(namespace: ns, pod: pod) else {
                #expect(read == .refresh)
                continue
            }
            #expect(argv.first == "kubectl")
            #expect(argv.count > 1 && ["get", "logs"].contains(argv[1]), "\(read): \(argv)")
            #expect(!argv.contains { ["delete", "apply", "patch", "edit", "scale", "exec", "drain", "cordon", "--overwrite"].contains($0) })
        }
        #expect(DemoTour.ReadAction.allCases.map(\.rawValue) == ["logs", "events", "manifest", "refresh"])
    }

    @Test("waitFor takes only its three conditions, with a bounded timeout, and each is decided from the reads")
    func demoTourStepsConditions() throws {
        let parsed = try Self.tour([
            "waitFor modelReady default/qwen3-06b",
            "waitFor podRunning default/qwen3-06b-0 30",
            "waitFor nodesReady 2 900",
            "end",
        ]).map(\.step)
        #expect(parsed == [
            .waitFor(.modelReady(namespace: "default", name: "qwen3-06b"), timeout: DemoTour.defaultWait),
            .waitFor(.podRunning(.init(namespace: "default", name: .exact("qwen3-06b-0"))), timeout: 30),
            .waitFor(.nodesReady(2), timeout: 900),
            .end,
        ])
        #expect(Self.refusal(["waitFor modelServing default/x", "end"]) == .unknownCondition(index: 1, name: "modelServing"))
        #expect(Self.refusal(["waitFor nodesReady 1 901", "end"]) != nil)
        #expect(Self.refusal(["waitFor nodesReady 1 0", "end"]) != nil)
        #expect(Self.refusal(["waitFor nodesReady 0", "end"]) != nil)
        #expect(Self.refusal(["waitFor modelReady default/qwen*", "end"]) != nil)
        #expect(Self.refusal(["waitFor modelReady qwen3-06b", "end"]) != nil)
        #expect(Self.refusal(["waitFor podRunning", "end"]) != nil)

        func pod(_ name: String, phase: String, ready: Bool) -> Pod {
            Pod(name: name, namespace: "default", uid: "u-\(name)", image: "", kind: .nativeProcess, phase: phase, health: .running,
                ready: ready, restarts: 0, ports: [], owner: "StatefulSet qwen3-06b", created: nil, cpuRequest: nil, memoryRequest: nil, nodeName: nil)
        }
        let running = DemoTour.Condition.podRunning(Self.qwen)
        #expect(!DemoTour.met(running, pods: nil, models: nil, nodes: nil))
        #expect(!DemoTour.met(running, pods: [pod("qwen3-06b-0", phase: "Pending", ready: false)], models: nil, nodes: nil))
        #expect(!DemoTour.met(running, pods: [pod("qwen3-06b-0", phase: "Running", ready: false)], models: nil, nodes: nil))
        #expect(!DemoTour.met(running, pods: [pod("other-0", phase: "Running", ready: true)], models: nil, nodes: nil))
        #expect(DemoTour.met(running, pods: [pod("qwen3-06b-0", phase: "Running", ready: true)], models: nil, nodes: nil))

        let models = try ModelsList.decode(Data("""
        {"kind":"List","items":[
          {"kind":"MLXModel","metadata":{"name":"qwen3-06b","namespace":"default","uid":"m1"},"status":{"phase":"Loading"}},
          {"kind":"MLXModel","metadata":{"name":"other","namespace":"default","uid":"m2"},"status":{"phase":"Ready"}}]}
        """.utf8))
        let ready = DemoTour.Condition.modelReady(namespace: "default", name: "qwen3-06b")
        #expect(!DemoTour.met(ready, pods: nil, models: nil, nodes: nil))
        #expect(!DemoTour.met(ready, pods: nil, models: models, nodes: nil))
        let nowReady = try ModelsList.decode(Data("""
        {"kind":"List","items":[{"kind":"MLXModel","metadata":{"name":"qwen3-06b","namespace":"default","uid":"m1"},"status":{"phase":"Ready"}}]}
        """.utf8))
        #expect(DemoTour.met(ready, pods: nil, models: nowReady, nodes: nil))

        let nodes = [ClusterNode(name: "a", ready: true), ClusterNode(name: "b", ready: false), ClusterNode(name: "c", ready: nil)]
        #expect(DemoTour.met(.nodesReady(1), pods: nil, models: nil, nodes: nodes))
        #expect(!DemoTour.met(.nodesReady(2), pods: nil, models: nil, nodes: nodes))
        #expect(!DemoTour.met(.nodesReady(1), pods: nil, models: nil, nodes: nil))
    }

    @Test("the order holds: a row on its own tab chosen first, a pod read after a pod, end last and once")
    func demoTourStepsOrdering() throws {
        // A row before its tab: a fresh launch restores whatever tab was last shown.
        #expect(Self.refusal(["selectRow node @server", "end"])
                == .outOfOrder(index: 1, step: "selectRow node @server", why: "its row's tab, nodes, is not selected"))
        #expect(Self.refusal(["selectTab workloads", "selectRow node @server", "end"]) != nil)
        // A pod needs the Pods view chosen, not left to the stored one.
        #expect(Self.refusal(["selectTab workloads", "selectRow pod default/x", "end"]) != nil)
        #expect(Self.refusal(["selectTab workloads", "selectWorkloadsView events", "selectRow pod default/x", "end"]) != nil)
        #expect(Self.refusal(["selectTab nodes", "selectWorkloadsView pods", "end"]) != nil)
        // A pod read follows a selected pod, with Workloads still shown.
        #expect(Self.refusal(["selectTab workloads", "selectWorkloadsView pods", "runRead logs", "end"]) != nil)
        #expect(Self.refusal(["selectTab workloads", "selectWorkloadsView pods", "selectRow pod default/x", "selectTab nodes", "runRead events", "end"]) != nil)
        #expect(try Self.tour(["runRead refresh", "end"]).count == 2)
        #expect(try Self.tour(["selectTab workloads", "selectWorkloadsView pods", "selectRow pod default/x", "selectTab nodes",
                               "selectTab workloads", "runRead manifest", "end"]).count == 7)
        // end is last, and only once.
        #expect(Self.refusal(["selectTab stats"]) == .missingEnd)
        #expect(Self.refusal(["end", "selectTab stats"]) == .outOfOrder(index: 1, step: "end", why: "end is the last step"))
        #expect(Self.refusal(["end", "end"]) != nil)
        #expect(try Self.tour(["end"]).map(\.step) == [.end])
        // A refused message names the step, clipped.
        #expect(DemoTour.TourError.unknownStep(index: 3, verb: "x\u{202E}y").message == "step 3: unknown step \"xy\"")
    }

    @Test("the launch argument names one tour file, read only from the checkout's hack/demo or the bundle's Resources/demo")
    func demoTourStepsLaunchPath() throws {
        #expect(try DemoTour.path(in: ["k3sm-app"]) == nil)
        #expect(try DemoTour.path(in: ["k3sm-app", "--demo-tour", "/x/hack/demo/a.json"]) == "/x/hack/demo/a.json")
        #expect(throws: DemoTour.LaunchError.missingPath) { try DemoTour.path(in: ["k3sm-app", "--demo-tour"]) }
        #expect(throws: DemoTour.LaunchError.missingPath) { try DemoTour.path(in: ["k3sm-app", "--demo-tour", "--other"]) }
        #expect(throws: DemoTour.LaunchError.repeated) { try DemoTour.path(in: ["k3sm-app", "--demo-tour", "a", "--demo-tour", "b"]) }

        let checkout = URL(fileURLWithPath: "/src/app")
        let exe = URL(fileURLWithPath: "/src/app/.build/arm64-apple-macosx/debug/K3smApp")
        let dirs = DemoTour.allowedDirectories(executable: exe, resources: nil) { $0.path == checkout.path }
        #expect(dirs.map(\.path) == ["/src/app/hack/demo"])
        #expect(DemoTour.permits(URL(fileURLWithPath: "/src/app/hack/demo/release-tour.json"), in: dirs))
        #expect(DemoTour.permits(URL(fileURLWithPath: "/src/app/hack/demo/../demo/release-tour.json"), in: dirs))
        #expect(!DemoTour.permits(URL(fileURLWithPath: "/src/app/hack/demo/../release-tour.json"), in: dirs))
        #expect(!DemoTour.permits(URL(fileURLWithPath: "/src/app/hack/demo/sub/release-tour.json"), in: dirs))
        #expect(!DemoTour.permits(URL(fileURLWithPath: "/src/app/hack/demo/release-tour.sh"), in: dirs))
        #expect(!DemoTour.permits(URL(fileURLWithPath: "/tmp/release-tour.json"), in: dirs))
        // A bundle carries Resources/demo; one outside any checkout reads only there.
        let bundle = URL(fileURLWithPath: "/Applications/k3sm.app/Contents")
        let bundled = DemoTour.allowedDirectories(executable: bundle.appendingPathComponent("MacOS/k3sm-app"),
                                                  resources: bundle.appendingPathComponent("Resources")) { _ in false }
        #expect(bundled.map(\.path) == ["/Applications/k3sm.app/Contents/Resources/demo"])
        #expect(DemoTour.permits(URL(fileURLWithPath: "/Applications/k3sm.app/Contents/Resources/demo/release-tour.json"), in: bundled))
        #expect(!DemoTour.permits(URL(fileURLWithPath: "/Applications/k3sm.app/Contents/Resources/payload.json"), in: bundled))
    }

    @Test("a bare tour name resolves inside the bundle; separators, .. and missing names are refused")
    func demoTourFromBundle() throws {
        let res = URL(fileURLWithPath: "/Applications/k3sm.app/Contents/Resources")
        let got = try DemoTour.bundledTour(named: "release-tour", resources: res) { _ in true }
        #expect(got.path == "/Applications/k3sm.app/Contents/Resources/demo/release-tour.json")
        #expect(DemoTour.isBareName("release-tour") && DemoTour.isBareName(".."))
        #expect(!DemoTour.isBareName("a/b") && !DemoTour.isBareName("a.json"))
        for bad in ["../release-tour", "a/b", "..", "", ".hidden", "x\\y"] {
            #expect(throws: DemoTour.LaunchError.badName(bad)) { try DemoTour.bundledTour(named: bad, resources: res) { _ in true } }
        }
        #expect(throws: DemoTour.LaunchError.unknownTour("nope")) { try DemoTour.bundledTour(named: "nope", resources: res) { _ in false } }
        #expect(throws: DemoTour.LaunchError.unknownTour("release-tour")) { try DemoTour.bundledTour(named: "release-tour", resources: nil) { _ in true } }
        #expect(DemoTour.LaunchError.unknownTour("nope").message.contains("no tour named nope"))
    }

    @Test("rows, frames and motion: the pod by prefix, the server by role, the frame from the top left")
    func demoTourStepsRunning() {
        func pod(_ name: String, _ ns: String = "default") -> Pod {
            Pod(name: name, namespace: ns, uid: name, image: "", kind: .nativeProcess, phase: "Running", health: .running,
                ready: true, restarts: 0, ports: [], owner: nil, created: nil, cpuRequest: nil, memoryRequest: nil, nodeName: nil)
        }
        let pods = [pod("qwen3-06b-1"), pod("qwen3-06b-0"), pod("qwen3-06b-0", "other"), pod("web")]
        #expect(DemoTour.pod(Self.qwen, in: pods)?.key == "default/qwen3-06b-0")
        #expect(DemoTour.pod(.init(namespace: "default", name: .exact("web")), in: pods)?.key == "default/web")
        #expect(DemoTour.pod(.init(namespace: "default", name: .exact("qwen3-06b")), in: pods) == nil)
        let nodes = [ClusterNode(name: "worker", ready: true), ClusterNode(name: "srv-b", ready: true, controlPlane: true),
                     ClusterNode(name: "srv-a", ready: true, controlPlane: true)]
        #expect(DemoTour.node(.server, in: nodes)?.name == "srv-a")
        #expect(DemoTour.node(.name("worker"), in: nodes)?.name == "worker")
        #expect(DemoTour.node(.server, in: [ClusterNode(name: "worker", ready: true)]) == nil)
        let f = DemoTour.appKitFrame(.init(x: 80, y: 60, width: 1280, height: 800), screenHeight: 1000)
        #expect(f.x == 80 && f.y == 140 && f.width == 1280 && f.height == 800)
        #expect(DemoTour.animation(reduceMotion: true) == nil)
        #expect(DemoTour.animation(reduceMotion: false) != nil)
        #expect(DemoTour.failureLine(index: 7, step: .selectRow(.node(.server)), reason: "no row\nlisted")
                == "k3sm demo tour: step 7 (selectRow node @server) failed: no row listed")
    }
}
