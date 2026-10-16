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

@Suite("the build engine card")
struct BuildEngineTests {
    static func list(_ items: [String]) -> Data {
        Data(#"{"apiVersion":"v1","kind":"List","items":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    static func pod(name: String = "k3sm-builder", phase: String, ready: Bool?, waiting: String? = nil, extra: String = "") -> String {
        var container = ""
        if let ready {
            let state = waiting.map { #""state":{"waiting":{"reason":"\#($0)"}},"# } ?? ""
            container = #","containerStatuses":[{"name":"buildkitd",\#(state)"ready":\#(ready),"restartCount":0}]"#
        }
        return #"{"kind":"Pod","metadata":{"name":"\#(name)"\#(extra)},"spec":{"nodeName":"mac-a"},"status":{"phase":"\#(phase)"\#(container)}}"#
    }

    struct StateCase: Sendable, CustomTestStringConvertible {
        let name: String
        let items: [String]
        let want: BuildEngineState
        var testDescription: String { name }
    }

    static let stateCases: [StateCase] = [
        StateCase(name: "no pod is absent", items: [], want: .absent),
        StateCase(name: "running with the engine ready is ready", items: [pod(phase: "Running", ready: true)], want: .ready),
        StateCase(name: "running but not ready is pending", items: [pod(phase: "Running", ready: false)], want: .pending("")),
        StateCase(name: "running with no container status is pending", items: [pod(phase: "Running", ready: nil)], want: .pending("")),
        StateCase(name: "a ready container in a pending pod is pending", items: [pod(phase: "Pending", ready: true)], want: .pending("Pending")),
        StateCase(name: "pulling is pending with the reason",
                  items: [pod(phase: "Pending", ready: false, waiting: "ContainerCreating")], want: .pending("ContainerCreating")),
        StateCase(name: "a crash loop is failed",
                  items: [pod(phase: "Running", ready: false, waiting: "CrashLoopBackOff")], want: .failed("CrashLoopBackOff")),
        StateCase(name: "a failed pod is failed", items: [pod(phase: "Failed", ready: false)], want: .failed("")),
        StateCase(name: "a pod being deleted is stopping",
                  items: [pod(phase: "Running", ready: true, extra: #","deletionTimestamp":"2026-10-15T00:00:00Z""#)], want: .pending("Stopping")),
        StateCase(name: "the default-named pod decides over another",
                  items: [pod(name: "a-other", phase: "Failed", ready: false), pod(phase: "Running", ready: true)], want: .ready),
    ]

    @Test("ready only when the engine pod runs and its container is ready", arguments: stateCases)
    func readyOnlyWhenPodRunningAndContainerReady(_ c: StateCase) throws {
        #expect(try BuildEngine.decode(Self.list(c.items)).state == c.want)
    }

    @Test("a stranger pod or claim in the namespace is not the engine")
    func strangerPodIsNotTheEngine() throws {
        let stranger = Self.pod(name: "lookalike", phase: "Running", ready: true)
        let claim = #"{"kind":"PersistentVolumeClaim","metadata":{"name":"someone-else"},"status":{"phase":"Bound"}}"#
        let engine = try BuildEngine.decode(Self.list([stranger, claim]))
        #expect(engine.state == .absent)
        #expect(engine.podName == nil && engine.cache == nil)
        let halfLabelled = Self.pod(name: "x", phase: "Running", ready: true,
                                    extra: #","labels":{"app.kubernetes.io/name":"k3sm-builder"}"#)
        #expect(try BuildEngine.decode(Self.list([halfLabelled])).state == .absent)
    }

    @Test("a renamed engine counts by its labels")
    func labelledEngineCounts() throws {
        let renamed = Self.pod(name: "builder-2", phase: "Running", ready: true,
                               extra: #","labels":{"app.kubernetes.io/name":"k3sm-builder","k3sm.io/managed":"true"}"#)
        let engine = try BuildEngine.decode(Self.list([renamed]))
        #expect(engine.state == .ready)
        #expect(engine.podName == "builder-2")
    }

    @Test("only the buildkitd container's readiness counts")
    func onlyBuildkitdReadiness() throws {
        let pod = #"{"kind":"Pod","metadata":{"name":"k3sm-builder"},"status":{"phase":"Running","containerStatuses":[{"name":"sidecar","ready":true,"restartCount":0}]}}"#
        #expect(try BuildEngine.decode(Self.list([pod])).state == .pending(""))
    }

    @Test("the card carries the pod, its node and the cache claim, every string clipped")
    func card() throws {
        let claim = #"{"kind":"PersistentVolumeClaim","metadata":{"name":"k3sm-builder"},"status":{"phase":"Bound","capacity":{"storage":"40Gi"}}}"#
        let crash = Self.pod(phase: "Pending", ready: false, waiting: #"Err‮or\nX"#)
        let engine = try BuildEngine.decode(Self.list([crash, claim]))
        #expect(engine.state == .pending("Error X"))
        #expect(engine.podName == "k3sm-builder")
        #expect(engine.nodeName == "mac-a")
        #expect(engine.cache == BuildCache(name: "k3sm-builder", phase: "Bound", capacityBytes: 40 * 1024 * 1024 * 1024))
    }

    @Test("a list of another kind, or of other kinds, is refused by name")
    func refused() {
        #expect(throws: BuildEngineDecodeError.malformed) { try BuildEngine.decode(Data("No resources found".utf8)) }
        #expect(throws: BuildEngineDecodeError.notAList("PodList")) { try BuildEngine.decode(Data(#"{"kind":"PodList","items":[]}"#.utf8)) }
        #expect(throws: BuildEngineDecodeError.notAList("List")) {
            try BuildEngine.decode(Self.list([#"{"kind":"Service","metadata":{"name":"k3sm-builder"}}"#]))
        }
        #expect(BuildEngine.tabResult(exitCode: 1, stdout: Data()) == .failed("k3sm kubectl exited 1"))
    }

    @Test("each state has its word, severity and line")
    func words() {
        #expect(BuildEngineState.ready.word == "Ready" && BuildEngineState.ready.severity == "ok")
        #expect(BuildEngineState.absent.severity == "off" && BuildEngineState.absent.detail.contains("k3sm builder up"))
        #expect(BuildEngineState.pending("").detail == "The engine pod is starting.")
        #expect(BuildEngineState.failed("ErrImagePull").detail == "ErrImagePull")
        #expect(BuildEngineState.failed("x").severity == "bad")
    }
}
