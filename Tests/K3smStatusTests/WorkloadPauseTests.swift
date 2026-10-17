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

@Suite("pausing and resuming a workload")
struct WorkloadPauseTests {
    struct AvailabilityCase: Sendable, CustomTestStringConvertible {
        let name: String
        let ref: OwnerRef?
        /// The verbs the pod's menu offers between Restart and Delete.
        let offered: [String]
        let note: String?
        var testDescription: String { name }
    }

    static let availability: [AvailabilityCase] = [
        AvailabilityCase(name: "a Deployment's pod, through its ReplicaSet, offers Pause",
                         ref: apps("ReplicaSet", "web-6bcddf6f77", "rs-web"), offered: ["workload-pause"], note: nil),
        AvailabilityCase(name: "a StatefulSet's pod offers Pause",
                         ref: apps("StatefulSet", "db", "s-db"), offered: ["workload-pause"], note: nil),
        AvailabilityCase(name: "a paused Deployment's pod offers Resume",
                         ref: apps("ReplicaSet", "api-7f9c4d", "rs-api"), offered: ["workload-resume"], note: nil),
        AvailabilityCase(name: "a DaemonSet's pod offers no Pause and says why",
                         ref: apps("DaemonSet", "agent", "ds-agent"), offered: [], note: WorkloadPause.daemonSetNote),
        AvailabilityCase(name: "a bare ReplicaSet's pod offers no Pause",
                         ref: apps("ReplicaSet", "bare-5d8c", "rs-bare"), offered: [], note: nil),
        AvailabilityCase(name: "a Job's pod offers no Pause",
                         ref: OwnerRef(apiVersion: "batch/v1", kind: "Job", name: "migrate", uid: "j"), offered: [], note: nil),
        AvailabilityCase(name: "a pod with no controller offers no Pause", ref: nil, offered: [], note: nil),
        AvailabilityCase(name: "a ReplicaSet of another UID offers no Pause",
                         ref: apps("ReplicaSet", "web-6bcddf6f77", "rs-other"), offered: [], note: nil),
        AvailabilityCase(name: "a StatefulSet of another API group offers no Pause",
                         ref: OwnerRef(apiVersion: "example.com/v1", kind: "StatefulSet", name: "db", uid: "s-db"),
                         offered: [], note: nil),
    ]

    @Test("the gate: availability, the two argument lists, the annotation round trip and the DaemonSet refusal")
    func pauseResumeWorkload() throws {
        let controllers = try WorkloadControllers.decode(try fixture("kubectl_controllers.json"))

        // The availability table: the pod's menu, between Restart and Delete.
        for c in Self.availability {
            var pod = testPod("p-1")
            pod.controllerRef = c.ref
            let verbs = PodActions.menu(for: pod, controllers: controllers).items.map(\.request.verb)
                .filter { $0.hasPrefix("workload-") }
            #expect(verbs == c.offered, "\(c.name)")
            #expect(WorkloadPause.note(for: pod, in: controllers) == c.note, "\(c.name)")
        }
        // Without the controller read nothing is offered, and a DaemonSet is still named.
        var webPod = testPod("web-6bcddf6f77-x2x")
        webPod.controllerRef = apps("ReplicaSet", "web-6bcddf6f77", "rs-web")
        #expect(WorkloadPause.requests(for: webPod, in: nil).isEmpty)
        var agentPod = testPod("agent-abc")
        agentPod.controllerRef = apps("DaemonSet", "agent", "ds-agent")
        #expect(WorkloadPause.resolve(agentPod, in: nil) == .daemonSet)
        #expect(WorkloadPause.requests(for: agentPod, in: controllers).isEmpty)

        // Pause: record the count, then scale to zero, on the Deployment, never its ReplicaSet.
        let pause = try #require(WorkloadPause.requests(for: webPod, in: controllers).first)
        #expect(pause.action == .pause && pause.controller == .deployment && pause.count == 3 && pause.uid == "d-web")
        #expect(pause.kind == .change && pause.asksFirst)
        #expect(pause.precheckArguments
            == ["kubectl", "get", "deployment/web", "-n", "default", "-o",
                    #"jsonpath={.metadata.uid} {.spec.replicas} {.metadata.annotations.k3sm\.io/paused-replicas}"#])
        #expect(pause.arguments
            == ["kubectl", "annotate", "deployment/web", "-n", "default", "k3sm.io/paused-replicas=3", "--overwrite"])
        let pauseScale = try #require(pause.next(after: .exited(status: 0, output: Data())) as? WorkloadActionRequest)
        #expect(pauseScale.arguments == ["kubectl", "scale", "deployment/web", "-n", "default", "--replicas=0"])
        #expect(!pauseScale.asksFirst && pauseScale.next(after: .exited(status: 0, output: Data())) == nil)
        // A failed record never leads to the scale.
        #expect(pause.next(after: .exited(status: 1, output: Data())) == nil)
        #expect(pause.next(after: .noAnswer) == nil)

        // The annotation round trip: the paused Deployment offers Resume to the recorded count.
        let api = try #require(controllers.items.first { $0.name == "api" })
        #expect(api.paused && WorkloadPause.available(for: api) == [.resume])
        let resume = try #require(WorkloadPause.request(.resume, for: api))
        #expect(resume.count == 2)
        #expect(resume.arguments == ["kubectl", "scale", "deployment/api", "-n", "default", "--replicas=2"])
        let resumeClear = try #require(resume.next(after: .exited(status: 0, output: Data())) as? WorkloadActionRequest)
        #expect(resumeClear.arguments == ["kubectl", "annotate", "deployment/api", "-n", "default", "k3sm.io/paused-replicas-"])
        // What Pause writes, Resume reads back: a controller carrying the
        // recorded "3" resumes to 3, and once the annotation is gone it offers Pause again.
        let recorded = WorkloadController(kind: .deployment, name: "web", namespace: "default", uid: "d-web", replicas: 0,
                                          pausedReplicas: "3")
        #expect(WorkloadPause.request(.resume, for: recorded)?.count == pause.count)
        let cleared = WorkloadController(kind: .deployment, name: "web", namespace: "default", uid: "d-web", replicas: 3,
                                         pausedReplicas: nil)
        #expect(WorkloadPause.available(for: cleared) == [.pause])
        #expect(WorkloadPause.paused(webPod, in: controllers) == false)

        // The paused row holds Resume in its namespace.
        let workloads = Workloads(pods: [webPod], controllers: controllers)
        #expect(WorkloadPause.pausedControllers(in: workloads, namespace: "default").map(\.name) == ["api"])

        // The StatefulSet golden.
        var dbPod = testPod("db-0")
        dbPod.controllerRef = apps("StatefulSet", "db", "s-db")
        let dbPause = try #require(WorkloadPause.requests(for: dbPod, in: controllers).first)
        #expect(dbPause.arguments
            == ["kubectl", "annotate", "statefulset/db", "-n", "default", "k3sm.io/paused-replicas=1", "--overwrite"])
    }

    @Test("a ReplicaSet owner resolves to the Deployment that controls it; a bare one to none")
    func ownerDecodeResolvesReplicaSetToDeployment() throws {
        let controllers = try WorkloadControllers.decode(try fixture("kubectl_controllers.json"))
        let workloads = try Workloads.decode(try fixture("kubectl_pods_running.json"))
        // The decoded controller reference keeps kind, name, UID and API version.
        for pod in workloads.pods {
            if let ref = pod.controllerRef { #expect(!ref.kind.isEmpty && !ref.name.isEmpty) }
        }
        var pod = testPod("web-6bcddf6f77-x2x")
        pod.controllerRef = apps("ReplicaSet", "web-6bcddf6f77", "rs-web")
        guard case .controller(let c) = WorkloadPause.resolve(pod, in: controllers) else {
            Issue.record("no controller")
            return
        }
        #expect(c.kind == .deployment && c.name == "web" && c.uid == "d-web")
        pod.controllerRef = apps("ReplicaSet", "bare-5d8c", "rs-bare")
        #expect(WorkloadPause.resolve(pod, in: controllers) == .none)
    }

    @Test("the pod decode takes the owner reference marked controller, not the first, for the owner and the reference alike")
    func podDecodeTakesTheControllerReference() throws {
        let json = #"""
        {"kind":"PodList","items":[{"metadata":{"name":"web-1","namespace":"default","uid":"u",
          "ownerReferences":[{"apiVersion":"v1","kind":"Widget","name":"w","uid":"w1"},
                             {"apiVersion":"apps/v1","kind":"ReplicaSet","name":"web-6bcddf6f77","uid":"rs-web","controller":true}]},
          "spec":{"containers":[{"name":"c","image":"i"}]}}]}
        """#
        let pod = try #require(try Workloads.decode(Data(json.utf8)).pods.first)
        #expect(pod.controllerRef == apps("ReplicaSet", "web-6bcddf6f77", "rs-web"))
        #expect(pod.owner == "ReplicaSet web-6bcddf6f77")
    }

    @Test("the pre-check runs a step only on the controller and count confirmed")
    func precheckRefusesAChangedController() throws {
        let web = WorkloadController(kind: .deployment, name: "web", namespace: "default", uid: "d-web", replicas: 3, pausedReplicas: nil)
        let pause = try #require(WorkloadPause.request(.pause, for: web))
        #expect(pause.precheck(.exited(status: 0, output: Data("d-web 3".utf8))) == nil)
        #expect(pause.precheck(.exited(status: 0, output: Data("d-web 5".utf8)))?.failed == true)
        #expect(pause.precheck(.exited(status: 0, output: Data("d-new 3".utf8)))?.failed == true)
        #expect(pause.precheck(.exited(status: 1, output: Data("Error from server (NotFound): x".utf8)))?.failed == true)
        // The second step checks the UID only: the replicas are still 3 after the record.
        let scale = try #require(pause.next(after: .exited(status: 0, output: Data())))
        #expect(scale.precheck(.exited(status: 0, output: Data("d-web 3".utf8))) == nil)
    }

    @Test("the gate: Resume re-reads the record, a half-done Pause is retryable, the decode fails closed")
    func resumeRefusesAChangedWorkload() throws {
        let api = WorkloadController(kind: .deployment, name: "api", namespace: "default", uid: "d-api", replicas: 0, pausedReplicas: "2")
        let resume = try #require(WorkloadPause.request(.resume, for: api))
        // (1) the live record and replicas must be the ones confirmed.
        #expect(resume.precheck(.exited(status: 0, output: Data("d-api 0 2".utf8))) == nil)
        for live in ["d-api 0 5", "d-api 0 ", "d-api 3 2", "d-api  2", "d-new 0 2", "d-api 0 2 x"] {
            let outcome = resume.precheck(.exited(status: 0, output: Data(live.utf8)))
            #expect(outcome?.failed == true && outcome?.text.contains("changed since you clicked") == true, "\(live)")
        }
        let clear = try #require(resume.next(after: .exited(status: 0, output: Data())))
        #expect(clear.precheck(.exited(status: 0, output: Data("d-api 2 2".utf8))) == nil)

        // (2) a record on a controller still asking for replicas offers Pause again, the scale step only.
        let stale = WorkloadController(kind: .deployment, name: "web", namespace: "default", uid: "d-web", replicas: 3, pausedReplicas: "3")
        #expect(stale.stale && WorkloadPause.available(for: stale) == [.pause])
        let retry = try #require(WorkloadPause.request(.pause, for: stale))
        #expect(retry.asksFirst && retry.count == 3 && retry.verb == "workload-pause-retry")
        #expect(retry.arguments == ["kubectl", "scale", "deployment/web", "-n", "default", "--replicas=0"])
        #expect(retry.next(after: .exited(status: 0, output: Data())) == nil)
        #expect(retry.precheck(.exited(status: 0, output: Data("d-web 3 3".utf8))) == nil)
        #expect(retry.precheck(.exited(status: 0, output: Data("d-web 3 4".utf8)))?.failed == true)
        #expect(retry.precheck(.exited(status: 0, output: Data("d-web 0 3".utf8)))?.failed == true)
        #expect(retry.confirmation.message.contains("stale"))
        #expect(Help.Actions.byVerb["workload-pause-retry"] != nil)
        let sts = WorkloadController(kind: .statefulSet, name: "db", namespace: "default", uid: "s-db", replicas: 1, pausedReplicas: "1")
        let fact = WorkloadPause.controllerFact(for: podOf(sts), in: WorkloadControllers([sts]))
        #expect(fact?.contains("stale") == true && fact?.contains("paused") == false)

        // (3) the decode accepts only apps/v1, and find refuses an empty UID.
        let list = #"""
        {"kind":"List","items":[
          {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"a","namespace":"n","uid":"u1"},"spec":{"replicas":1}},
          {"kind":"Deployment","metadata":{"name":"b","namespace":"n","uid":"u2"},"spec":{"replicas":1}},
          {"apiVersion":"extensions/v1beta1","kind":"Deployment","metadata":{"name":"c","namespace":"n","uid":"u3"},"spec":{"replicas":1}}]}
        """#
        let decoded = try WorkloadControllers.decode(Data(list.utf8))
        #expect(decoded.items.map(\.name) == ["a"])
        #expect(decoded.find(.deployment, OwnerRef(apiVersion: "apps/v1", kind: "Deployment", name: "a", uid: ""), in: "n") == nil)
        #expect(decoded.find(.deployment, OwnerRef(apiVersion: "apps/v1", kind: "Deployment", name: "a", uid: "u1"), in: "n") != nil)

        // (4) an unreadable record qualifies the Resume question.
        let junk = WorkloadController(kind: .deployment, name: "api", namespace: "default", uid: "d-api", replicas: 0, pausedReplicas: "lots")
        let junkResume = try #require(WorkloadPause.request(.resume, for: junk))
        #expect(junkResume.count == 1 && junkResume.confirmation.message.contains("unreadable"))
        #expect(junkResume.precheck(.exited(status: 0, output: Data("d-api 0 lots".utf8))) == nil)
        #expect(!resume.confirmation.message.contains("unreadable"))
    }

    @Test("the confirmations say what happens, and the reports say the result")
    func confirmationAndReportWording() throws {
        let web = WorkloadController(kind: .deployment, name: "web", namespace: "default", uid: "d-web", replicas: 3, pausedReplicas: nil)
        let pause = try #require(WorkloadPause.request(.pause, for: web))
        #expect(pause.confirmation.title == "Pause default/web?")
        #expect(pause.confirmation.message.contains("its 3 pods stop"))
        #expect(pause.confirmation.message.contains("The Deployment stays"))
        #expect(pause.confirmation.message.contains("Resume restores 3 replicas"))
        #expect(pause.confirmation.destructive)
        let scale = try #require(pause.next(after: .exited(status: 0, output: Data())))
        #expect(scale.report(.exited(status: 0, output: Data())) == .succeeded("Paused Deployment web: its pods stop, and Resume restores 3 replicas."))
        #expect(scale.report(.exited(status: 1, output: Data("forbidden".utf8))).text.hasPrefix("Pause stopped: the count was recorded"))
        #expect(pause.report(runs: [.exited(status: 1, output: Data())]).text.hasPrefix("Pause failed; nothing was changed."))

        let paused = WorkloadController(kind: .statefulSet, name: "db", namespace: "default", uid: "s-db", replicas: 0, pausedReplicas: "1")
        let resume = try #require(WorkloadPause.request(.resume, for: paused))
        #expect(!resume.confirmation.destructive)
        #expect(resume.confirmation.message.hasPrefix("k3sm scales StatefulSet db back to 1 replica"))
        let clear = try #require(resume.next(after: .exited(status: 0, output: Data())))
        #expect(clear.report(.exited(status: 0, output: Data())) == .succeeded("Resumed StatefulSet db: it scales back to 1 replica."))
    }

    @Test("a hostile name or a missing UID offers nothing, and a foreign record restores one replica")
    func refusedNamesAndForeignRecords() {
        let hostile = WorkloadController(kind: .deployment, name: "--all", namespace: "default", uid: "u", replicas: 3, pausedReplicas: nil)
        #expect(WorkloadPause.available(for: hostile).isEmpty)
        let noUID = WorkloadController(kind: .deployment, name: "web", namespace: "default", uid: "", replicas: 3, pausedReplicas: nil)
        #expect(WorkloadPause.available(for: noUID).isEmpty)
        let replicaSet = WorkloadController(kind: .replicaSet, name: "web-1", namespace: "default", uid: "u", replicas: 3, pausedReplicas: nil)
        #expect(WorkloadPause.available(for: replicaSet).isEmpty)
        let zero = WorkloadController(kind: .deployment, name: "web", namespace: "default", uid: "u", replicas: 0, pausedReplicas: nil)
        #expect(WorkloadPause.available(for: zero).isEmpty)
        for foreign in ["", "0", "-1", "3; rm", "99999999999", "1e3"] {
            let c = WorkloadController(kind: .deployment, name: "web", namespace: "default", uid: "u", replicas: 0, pausedReplicas: foreign)
            #expect(WorkloadPause.request(.resume, for: c)?.count == 1, "\(foreign)")
        }
    }

    @Test("the controller read is fixed, and a failed one leaves Pause off")
    func controllerReadAndTabResult() throws {
        #expect(K3smCLI.controllersArguments == ["kubectl", "get", "deployments,statefulsets,replicasets", "-A", "-o", "json"])
        let pods = try fixture("kubectl_pods_running.json")
        guard case .value(let with) = Workloads.tabResult(podsExit: 0, podsStdout: pods,
                                                          controllers: (0, try fixture("kubectl_controllers.json"))) else {
            Issue.record("not listed")
            return
        }
        #expect(with.controllers?.items.count == 6)
        guard case .value(let without) = Workloads.tabResult(podsExit: 0, podsStdout: pods, controllers: (1, Data())) else {
            Issue.record("not listed")
            return
        }
        #expect(without.controllers == nil && without.pods == with.pods)
    }
}

private func apps(_ kind: String, _ name: String, _ uid: String) -> OwnerRef {
    OwnerRef(apiVersion: "apps/v1", kind: kind, name: name, uid: uid)
}

private func podOf(_ c: WorkloadController) -> Pod {
    var pod = testPod("p-1")
    pod.controllerRef = OwnerRef(apiVersion: "apps/v1", kind: "StatefulSet", name: c.name, uid: c.uid)
    return pod
}
