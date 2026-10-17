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

@Suite("scaling, restarting and following a workload")
struct WorkloadControlsTests {
    @Test("the gate: Rollout Restart's argument lists, on a Deployment, a StatefulSet and a DaemonSet")
    func rolloutRestartArgumentsGolden() throws {
        let controllers = try WorkloadControllers.decode(try fixture("kubectl_controllers.json"))

        // A Deployment's pod restarts the Deployment, never its ReplicaSet.
        let web = try #require(WorkloadControls.rolloutRestart(for: pod(apps("ReplicaSet", "web-6bcddf6f77", "rs-web")), in: controllers))
        #expect(web.arguments == ["kubectl", "rollout", "restart", "deployment/web", "-n", "default"])
        #expect(web.precheckArguments == ["kubectl", "get", "deployment/web", "-n", "default", "-o", "jsonpath={.metadata.uid}"])
        #expect(web.kind == .change && web.asksFirst && web.verb == "rollout-restart")
        #expect(web.rowKey == "default/Deployment/web")

        let db = try #require(WorkloadControls.rolloutRestart(for: pod(apps("StatefulSet", "db", "s-db")), in: controllers))
        #expect(db.arguments == ["kubectl", "rollout", "restart", "statefulset/db", "-n", "default"])

        // A DaemonSet's pod restarts the DaemonSet its reference names, even without the controller read.
        let agentPod = pod(apps("DaemonSet", "agent", "ds-agent"))
        let agent = try #require(WorkloadControls.rolloutRestart(for: agentPod, in: nil))
        #expect(agent.arguments == ["kubectl", "rollout", "restart", "daemonset/agent", "-n", "default"])
        #expect(agent.precheckArguments == ["kubectl", "get", "daemonset/agent", "-n", "default", "-o", "jsonpath={.metadata.uid}"])
        #expect(WorkloadControls.controllerKey(for: agentPod, in: controllers) == "default/DaemonSet/agent")

        // The menu offers it after Pause, before Delete.
        let verbs = PodActions.menu(for: pod(apps("ReplicaSet", "web-6bcddf6f77", "rs-web")), controllers: controllers)
            .items.map(\.request.verb)
        #expect(verbs == ["workload-pause", "rollout-restart", "delete"])
        #expect(PodActions.menu(for: agentPod, controllers: controllers).items.map(\.request.verb).contains("rollout-restart"))

        // Nothing for a bare ReplicaSet, a Job, a bare pod, a hostile name or a reference without a UID.
        for ref in [apps("ReplicaSet", "bare-5d8c", "rs-bare"), OwnerRef(apiVersion: "batch/v1", kind: "Job", name: "m", uid: "j"),
                    apps("DaemonSet", "--all", "ds-x"), apps("DaemonSet", "agent", "")] {
            #expect(WorkloadControls.rolloutRestart(for: pod(ref), in: controllers) == nil, "\(ref)")
        }
        #expect(WorkloadControls.rolloutRestart(for: testPod("bare"), in: controllers) == nil)

        // The pre-check runs it only on the controller confirmed.
        #expect(web.precheck(.exited(status: 0, output: Data("d-web".utf8))) == nil)
        #expect(web.precheck(.exited(status: 0, output: Data("d-new".utf8)))?.text
            == "Rollout Restart refused: Deployment web changed since you clicked; nothing was changed.")
        #expect(web.precheck(.exited(status: 1, output: Data("Error from server (NotFound): x".utf8)))?.failed == true)
        #expect(web.report(.exited(status: 0, output: Data())) == .succeeded("Rollout restart asked: Deployment web replaces its pods by its update strategy."))
        #expect(web.report(.exited(status: 1, output: Data("can't restart paused deployment".utf8))).text
            == "Rollout Restart failed. kubectl said: can't restart paused deployment")
        #expect(web.confirmation.title == "Rollout restart default/web?" && !web.confirmation.destructive)
        #expect(Help.Actions.byVerb["rollout-restart"] != nil)
    }

    @Test("Scale's argument list, its pre-check and its refusals")
    func scaleArgumentsGolden() throws {
        let web = WorkloadController(kind: .deployment, name: "web", namespace: "default", uid: "d-web", replicas: 3, pausedReplicas: nil)
        let up = try #require(WorkloadControls.scaleRequest(for: web, to: 5))
        #expect(up.arguments == ["kubectl", "scale", "deployment/web", "-n", "default", "--replicas=5"])
        #expect(up.precheckArguments
            == ["kubectl", "get", "deployment/web", "-n", "default", "-o",
                #"jsonpath={.metadata.uid} {.spec.replicas} {.metadata.annotations.k3sm\.io/paused-replicas}"#])
        #expect(up.kind == .change && up.rowKey == web.key && up.verb == "controller-scale")
        let db = WorkloadController(kind: .statefulSet, name: "db", namespace: "default", uid: "s-db", replicas: 1, pausedReplicas: nil)
        #expect(WorkloadControls.scaleRequest(for: db, to: 50)?.arguments
            == ["kubectl", "scale", "statefulset/db", "-n", "default", "--replicas=50"])

        // The pre-check: the UID, the count clicked on, and no Pause record since.
        #expect(up.precheck(.exited(status: 0, output: Data("d-web 3 ".utf8))) == nil)
        #expect(up.precheck(.exited(status: 0, output: Data("d-web 3".utf8))) == nil)
        for live in ["d-web 4 ", "d-new 3 ", "d-web 3 3", "d-web  ", ""] {
            let outcome = up.precheck(.exited(status: 0, output: Data(live.utf8)))
            #expect(outcome?.failed == true && outcome?.text.contains("changed since you clicked") == true, "\(live)")
        }

        // Only 1 to 50, never the count it has, never on a paused controller.
        for count in [0, -1, 51, 3] { #expect(WorkloadControls.scaleRequest(for: web, to: count) == nil, "\(count)") }
        #expect(WorkloadControls.stepperValue(current: 0) == 1 && WorkloadControls.stepperValue(current: 70) == 50)
        let paused = WorkloadController(kind: .deployment, name: "api", namespace: "default", uid: "d-api", replicas: 0, pausedReplicas: "2")
        #expect(WorkloadControls.scaleRequest(for: paused, to: 2) == nil)
        let controllers = try WorkloadControllers.decode(try fixture("kubectl_controllers.json"))
        #expect(WorkloadControls.scaleOffer(for: pod(apps("ReplicaSet", "api-7f9c4d", "rs-api")), in: controllers)
            == .refused(WorkloadControls.pausedNote))
        #expect(WorkloadControls.pausedNote.contains("Resume it first"))
        let stale = WorkloadController(kind: .statefulSet, name: "db", namespace: "default", uid: "s-db", replicas: 1, pausedReplicas: "1")
        #expect(WorkloadControls.scaleOffer(for: pod(apps("StatefulSet", "db", "s-db")), in: WorkloadControllers([stale]))
            == .refused(WorkloadControls.staleNote))
        guard case .scalable(let c, let current)? = WorkloadControls.scaleOffer(
            for: pod(apps("ReplicaSet", "web-6bcddf6f77", "rs-web")), in: controllers) else {
            Issue.record("no Scale on the Deployment's pod")
            return
        }
        #expect(c.name == "web" && current == 3)
        // No Scale on a DaemonSet's pod, a bare ReplicaSet's or a hostile name.
        #expect(WorkloadControls.scaleOffer(for: pod(apps("DaemonSet", "agent", "ds-agent")), in: controllers) == nil)
        #expect(WorkloadControls.scaleOffer(for: pod(apps("ReplicaSet", "bare-5d8c", "rs-bare")), in: controllers) == nil)
        let hostile = WorkloadController(kind: .deployment, name: "--all", namespace: "default", uid: "u", replicas: 3, pausedReplicas: nil)
        #expect(WorkloadControls.scaleRequest(for: hostile, to: 4) == nil)

        // The wording: a scale down is destructive and says how many pods stop.
        let down = try #require(WorkloadControls.scaleRequest(for: web, to: 1))
        #expect(down.confirmation.title == "Scale default/web?" && down.confirmation.destructive)
        #expect(down.confirmation.message == "k3sm scales Deployment web from 3 replicas to 1 replica. 2 pods stop now.")
        #expect(!up.confirmation.destructive && up.confirmation.message.hasSuffix("The new pods start, maybe on other nodes."))
        #expect(up.report(.exited(status: 0, output: Data())) == .succeeded("Scale asked: Deployment web goes from 3 replicas to 5 replicas."))
        #expect(up.report(.noAnswer).text.contains("Refresh"))
    }

    @Test("Follow's argument list, its targets, and the line when the limit stops it")
    @MainActor
    func followLogsArgumentsGolden() async throws {
        let ns = try #require(ResourceName("default")), name = try #require(ResourceName("web-1"))
        #expect(K3smCLI.followLogsArguments(namespace: ns, pod: name, container: nil)
            == ["kubectl", "logs", "-f", "--tail=200", "web-1", "-n", "default"])
        #expect(K3smCLI.followLogsArguments(namespace: ns, pod: name, container: ResourceName("sidecar"))
            == ["kubectl", "logs", "-f", "--tail=200", "web-1", "-n", "default", "-c", "sidecar"])

        // One target for a pod of one container, one per container otherwise; none for a pending pod.
        var one = testPod("web-1")
        one.containers = ["app"]
        #expect(LogFollow.targets(for: one).map(\.arguments) == [["kubectl", "logs", "-f", "--tail=200", "web-1", "-n", "default"]])
        var two = testPod("web-1")
        two.containers = ["app", "Bad Name", "sidecar"]
        #expect(LogFollow.targets(for: two).map { $0.container?.value } == ["app", "sidecar"])
        let pending = Pod(name: "p", namespace: "default", uid: "u", image: "", kind: .nativeProcess, phase: "Pending",
                          health: .waiting(""), ready: false, restarts: 0, ports: [], owner: nil, created: nil,
                          cpuRequest: nil, memoryRequest: nil, nodeName: nil)
        #expect(LogFollow.targets(for: pending).isEmpty)

        // A read that hits the limit says so; one the user stops says that instead.
        let target = try #require(LogFollow.targets(for: one).first)
        let limited = LogFollowRead(target: target)
        let ended = AsyncStream<Void>.makeStream()
        limited.changed = { if !limited.reading { ended.continuation.yield() } }
        limited.start { arguments, onOutput in
            #expect(arguments == target.arguments)
            onOutput(Data("line 1\n".utf8))
            return .limit
        }
        var iterator = ended.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(limited.text == "line 1\n")
        #expect(limited.status == "Stopped at 64 KiB, the most the pane holds. Follow again for the newest lines.")

        let stopped = LogFollowRead(target: target)
        stopped.start { _, _ in
            try? await Task.sleep(for: .seconds(60))
            return .exited(0)
        }
        stopped.stop(.user)
        #expect(stopped.status == "Stopped following." && !stopped.reading)
        // A stopped read never starts again.
        stopped.start { _, _ in .exited(0) }
        #expect(stopped.end == .stopped(.user))
        #expect(LogFollow.status(.exited(0), target: target) == "The log ended: the container stopped writing.")
        #expect(LogFollow.status(.timedOut, target: target).contains("30 minutes"))
    }
}

private func apps(_ kind: String, _ name: String, _ uid: String) -> OwnerRef {
    OwnerRef(apiVersion: "apps/v1", kind: kind, name: name, uid: uid)
}

private func pod(_ ref: OwnerRef) -> Pod {
    var pod = testPod("p-1")
    pod.controllerRef = ref
    return pod
}
