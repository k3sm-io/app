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

@Suite("the console's pod actions")
struct PodActionsTests {
    @Test("the pod delete is one fixed argument list through the CLI's kubectl")
    func deletePodArgumentsGolden() throws {
        let ns = try #require(ResourceName("shop"))
        let pod = try #require(ResourceName("web-7d9f8-abcde"))
        #expect(K3smCLI.deletePodArguments(namespace: ns, pod: pod)
            == ["kubectl", "delete", "pod", "web-7d9f8-abcde", "-n", "shop", "--wait=false"])
    }

    @Test("the UID read before an action is one fixed argument list")
    func podUIDArgumentsGolden() throws {
        let ns = try #require(ResourceName("shop"))
        let pod = try #require(ResourceName("web-0"))
        #expect(K3smCLI.podUIDArguments(namespace: ns, pod: pod)
            == ["kubectl", "get", "pod", "web-0", "-n", "shop", "-o", "jsonpath={.metadata.uid}"])
    }

    @Test("a hostile name never becomes a ResourceName, so it cannot reach the delete", arguments: [
        "--all", "-A", "--force", "a b", "../etc", "web;rm", "Web", "web\n-n", "web\u{202E}x", "", "-", "web-", ".web",
        "web/other", "--grace-period=0", String(repeating: "a", count: 254),
        "\u{FF57}\u{FF45}\u{FF42}", "web\u{0131}", "web\u{0}x", "a=b", "a,b",
    ])
    func hostileNameCannotReachTheDelete(_ name: String) {
        #expect(ResourceName(name) == nil)
    }

    @Test("a pod whose names the guard refuses offers no action and builds no request")
    func refusedNamesOfferNothing() {
        let pod = ownedPod(name: "--all", namespace: "default")
        #expect(PodActions.available(for: pod).isEmpty)
        #expect(PodActions.request(.restart, for: pod) == nil)
        let ns = ownedPod(name: "web", namespace: "-A")
        #expect(PodActions.available(for: ns).isEmpty)
    }

    @Test("restart is offered for an owned pod and absent for an unowned one; delete for both")
    func restartOnlyForOwnedPod() {
        #expect(PodActions.available(for: ownedPod()) == [.restart, .delete])
        #expect(PodActions.available(for: testPod("bare")) == [.delete])
        #expect(PodActions.request(.restart, for: testPod("bare")) == nil)
    }

    struct OwnerCase: Sendable, CustomTestStringConvertible {
        let owner: String?
        let offered: Bool
        var testDescription: String { owner ?? "no owner" }
    }

    static let ownerCases: [OwnerCase] = [
        OwnerCase(owner: "ReplicaSet web-5f6d", offered: true),
        OwnerCase(owner: "StatefulSet db", offered: true),
        OwnerCase(owner: "DaemonSet agent", offered: true),
        OwnerCase(owner: "Node mac-1", offered: false),
        OwnerCase(owner: "Job migrate", offered: false),
        OwnerCase(owner: "CronJob nightly", offered: false),
        OwnerCase(owner: "Widget w", offered: false),
        OwnerCase(owner: "replicaset web", offered: false),
        OwnerCase(owner: "ReplicaSet", offered: false),
        OwnerCase(owner: " ReplicaSet web", offered: false),
        OwnerCase(owner: nil, offered: false),
    ]

    @Test("restart is offered only when the owner recreates the pod", arguments: ownerCases)
    func restartOnlyForRecreatingOwners(_ c: OwnerCase) {
        let pod = c.owner.map { ownedPod(owner: $0) } ?? testPod("bare")
        #expect(PodActions.available(for: pod) == (c.offered ? [.restart, .delete] : [.delete]))
        #expect((PodActions.request(.restart, for: pod) != nil) == c.offered)
    }

    @Test("the restart request deletes the confirmed pod without waiting")
    func restartRequestArguments() throws {
        let request = try #require(PodActions.request(.restart, for: ownedPod()))
        #expect(request.arguments == ["kubectl", "delete", "pod", "web-1", "-n", "shop", "--wait=false"])
        #expect(request.podKey == "shop/web-1")
        #expect(request.uid == "shop-web-1")
        #expect(request.verifyArguments == ["kubectl", "get", "pod", "web-1", "-n", "shop", "-o", "jsonpath={.metadata.uid}"])
    }

    @Test("a pod listed without a UID offers no action, since none can be pinned")
    func noUIDNoAction() {
        let pod = Pod(name: "web-1", namespace: "shop", uid: "", image: "", kind: .nativeProcess,
                      phase: "Running", health: .running, ready: true, restarts: 0, ports: [], owner: "ReplicaSet web-5f6d",
                      created: nil, cpuRequest: nil, memoryRequest: nil, nodeName: nil)
        #expect(PodActions.available(for: pod).isEmpty)
    }

    struct VerifyCase: Sendable, CustomTestStringConvertible {
        let name: String
        let run: ActionRun
        let want: ActionOutcome?
        var testDescription: String { name }
    }

    static let changed = ActionOutcome.refused("Restart refused: the pod changed since you clicked; nothing was deleted.")
    static let verifyCases: [VerifyCase] = [
        VerifyCase(name: "the same UID runs the delete", run: .exited(status: 0, output: Data("shop-web-1".utf8)), want: nil),
        VerifyCase(name: "a trailing newline is not a change", run: .exited(status: 0, output: Data("shop-web-1\n".utf8)), want: nil),
        VerifyCase(name: "another UID is refused", run: .exited(status: 0, output: Data("shop-web-1-new".utf8)), want: changed),
        VerifyCase(name: "an empty UID is refused", run: .exited(status: 0, output: Data()), want: changed),
        VerifyCase(name: "a gone pod is refused",
                   run: .exited(status: 1, output: Data("Error from server (NotFound): pods \"web-1\" not found\n".utf8)), want: changed),
        VerifyCase(name: "another failure quotes kubectl and deletes nothing",
                   run: .exited(status: 1, output: Data("Unable to connect to the server\n".utf8)),
                   want: .failed("Restart failed; nothing was deleted. kubectl said: Unable to connect to the server")),
        VerifyCase(name: "no answer deletes nothing", run: .noAnswer,
                   want: .failed("Restart failed: the k3sm CLI did not answer the pod check; nothing was deleted.")),
        VerifyCase(name: "a missing CLI", run: .missing, want: .failed("Restart failed: k3sm is not installed on this Mac.")),
    ]

    @Test("the UID read before the delete", arguments: verifyCases)
    func verifyBeforeDelete(_ c: VerifyCase) throws {
        let request = try #require(PodActions.request(.restart, for: ownedPod()))
        #expect(PodActions.verify(request, run: c.run) == c.want)
    }

    @Test("the restart confirmation says the owner recreates the pod")
    func restartConfirmationWording() throws {
        let request = try #require(PodActions.request(.restart, for: ownedPod()))
        let c = request.confirmation
        #expect(c.title == "Restart shop/web-1?")
        #expect(c.message == "k3sm deletes this pod, and its owner, ReplicaSet web-5f6d, recreates it. Its containers stop now; the new pod may have a new name and run on another node.")
        #expect(c.verbTitle == "Restart")
        #expect(c.cancelTitle == "Cancel")
        #expect(c.destructive)
    }

    @Test("the confirmation clips the cluster's strings")
    func confirmationClipsOwner() throws {
        let pod = ownedPod(owner: "ReplicaSet \u{202E}evil\nline")
        let c = try #require(PodActions.request(.restart, for: pod)).confirmation
        #expect(!c.message.contains("\u{202E}"))
        #expect(!c.message.contains("\n"))
    }

    struct ReportCase: Sendable, CustomTestStringConvertible {
        let name: String
        let run: ActionRun
        let want: ActionOutcome
        var testDescription: String { name }
    }

    static let reportCases: [ReportCase] = [
        ReportCase(name: "a zero exit asks the owner to recreate", run: .exited(status: 0, output: Data("pod \"web-1\" deleted\n".utf8)),
                   want: .succeeded("Restart asked: ReplicaSet web-5f6d recreates the pod.")),
        ReportCase(name: "a failed delete shows the CLI's text through errorText",
                   run: .exited(status: 1, output: Data("Error from server (NotFound):\n pods \"web-1\"\u{202E} not found\n".utf8)),
                   want: .failed("Restart failed. kubectl said: Error from server (NotFound): pods \"web-1\" not found")),
        ReportCase(name: "a failed delete with no output names the exit", run: .exited(status: 1, output: Data()),
                   want: .failed("Restart failed: k3sm kubectl exited 1")),
        ReportCase(name: "no answer says the pod may still be deleted", run: .noAnswer,
                   want: .failed("Restart failed: the k3sm CLI did not answer. Refresh to see whether the pod was deleted.")),
        ReportCase(name: "a missing CLI", run: .missing, want: .failed("Restart failed: k3sm is not installed on this Mac.")),
        ReportCase(name: "a refused CLI is not run", run: .refused("owned by\nmallory"),
                   want: .failed("Restart failed: the installed k3sm failed the app's check (owned by mallory), so it was not run.")),
    ]

    @Test("a run's report", arguments: reportCases)
    func report(_ c: ReportCase) throws {
        let request = try #require(PodActions.request(.restart, for: ownedPod()))
        #expect(PodActions.report(request, run: c.run) == c.want)
    }
}

@Suite("deleting a pod")
struct PodDeleteTests {
    @Test("the delete confirmation says whether the owner recreates the pod")
    func deleteConfirmationWordingOwnedVersusUnowned() throws {
        let owned = try #require(PodActions.request(.delete, for: ownedPod())).confirmation
        #expect(owned.title == "Delete shop/web-1?")
        #expect(owned.message == "k3sm deletes this pod, and its containers stop now. Its owner, ReplicaSet web-5f6d, recreates it, maybe under a new name and on another node.")
        #expect(owned.verbTitle == "Delete")
        #expect(owned.destructive)
        let bare = try #require(PodActions.request(.delete, for: testPod("bare", namespace: "shop"))).confirmation
        #expect(bare.title == "Delete shop/bare?")
        #expect(bare.message == "k3sm deletes this pod, and its containers stop now. Nothing recreates it; this pod is gone for good.")
        let job = try #require(PodActions.request(.delete, for: ownedPod(owner: "Job migrate"))).confirmation
        #expect(job.message == "k3sm deletes this pod, and its containers stop now. Its owner, Job migrate, may not recreate it.")
        // The owner is cluster text: clipped before it reaches the sheet.
        let hostile = try #require(PodActions.request(.delete, for: ownedPod(owner: "ReplicaSet \u{202E}x\ny"))).confirmation
        #expect(!hostile.message.contains("\u{202E}") && !hostile.message.contains("\n"))
    }

    @Test("the delete runs the restart's argument list behind the same UID read, and is the Delete key's")
    func deleteRequest() throws {
        let request = try #require(PodActions.request(.delete, for: testPod("bare", namespace: "shop")))
        #expect(request.arguments == ["kubectl", "delete", "pod", "bare", "-n", "shop", "--wait=false"])
        #expect(request.precheckArguments == ["kubectl", "get", "pod", "bare", "-n", "shop", "-o", "jsonpath={.metadata.uid}"])
        #expect(request.kind == .delete)
        #expect(request.id == "delete:shop/bare")
        #expect(request.precheck(.exited(status: 0, output: Data("other".utf8)))
            == .refused("Delete refused: the pod changed since you clicked; nothing was deleted."))
        #expect(request.precheck(.exited(status: 0, output: Data("shop-bare".utf8))) == nil)
    }

    @Test("the delete's report says what comes back")
    func deleteReport() throws {
        let owned = try #require(PodActions.request(.delete, for: ownedPod()))
        #expect(owned.report(.exited(status: 0, output: Data())) == .succeeded("Delete asked: ReplicaSet web-5f6d recreates the pod."))
        let bare = try #require(PodActions.request(.delete, for: testPod("bare")))
        #expect(bare.report(.exited(status: 0, output: Data())) == .succeeded("Delete asked: nothing recreates this pod."))
        #expect(bare.report(.exited(status: 1, output: Data("Error from server (Forbidden): no\n".utf8)))
            == .failed("Delete failed. kubectl said: Error from server (Forbidden): no"))
    }
}

@Suite("the pod's local actions")
struct PodLocalActionsTests {
    @Test("copy name and copy namespace/name put the checked names on the pasteboard")
    func copyActions() {
        let items = PodActions.localActions(for: ownedPod())
        #expect(items.map(\.title) == ["Copy Name", "Copy Namespace/Name"])
        #expect(items.map(\.action) == [.copy("web-1"), .copy("shop/web-1")])
        #expect(PodActions.menu(for: ownedPod()).local == items)
        #expect(PodActions.localActions(for: ownedPod(name: "--all")).isEmpty)
        #expect(PodActions.menu(for: ownedPod(name: "--all")).isEmpty)
    }

    @Test("open shell is offered only for a running pod whose first container's name passes the guard")
    func openShellOffer() throws {
        var running = ownedPod()
        running.containers = ["app", "sidecar"]
        let shell = try #require(PodActions.localActions(for: running).last)
        #expect(shell.title == "Open Shell in Terminal")
        let want = PodShell(namespace: try #require(ResourceName("shop")), pod: try #require(ResourceName("web-1")),
                            container: try #require(ResourceName("app")))
        #expect(shell.action == .openShell(want))
        for phase in ["Pending", "Succeeded", "Failed", "Unknown", ""] {
            let pod = Pod(name: "web-1", namespace: "shop", uid: "u", image: "", kind: .nativeProcess, phase: phase,
                          health: .waiting(""), ready: false, restarts: 0, ports: [], owner: nil, created: nil,
                          cpuRequest: nil, memoryRequest: nil, nodeName: nil, containers: ["app"])
            #expect(PodActions.localActions(for: pod).count == 2, "phase \(phase)")
        }
        var hostile = ownedPod()
        hostile.containers = ["--privileged"]
        #expect(PodActions.localActions(for: hostile).count == 2)
        #expect(PodActions.localActions(for: ownedPod()).count == 2)
    }

    @Test("a refused CLI's alert cleans the check's text")
    func refusedAlert() {
        let alert = PodShell.refusedAlert(why: "owned by\nmallory\u{202E}")
        #expect(alert.title == "k3sm will not run the installed k3sm")
        #expect(alert.text == "It failed the app's check: owned by mallory.")
    }

    @Test("the decoder keeps the container names and the pod's status reason")
    func decodesContainersAndReason() throws {
        let json = """
            {"kind":"PodList","items":[{"metadata":{"name":"web-1","namespace":"shop","uid":"u1"},
             "spec":{"containers":[{"name":"app","image":"a"},{"name":"log","image":"b"}]},
             "status":{"phase":"Failed","reason":"Evicted"}}]}
            """
        let pod = try #require(try Workloads.decode(Data(json.utf8)).pods.first)
        #expect(pod.containers == ["app", "log"])
        #expect(pod.reason == "Evicted")
    }
}

/// An owned pod in the shop namespace, by default the ReplicaSet's.
private func ownedPod(name: String = "web-1", namespace: String = "shop", owner: String = "ReplicaSet web-5f6d") -> Pod {
    Pod(name: name, namespace: namespace, uid: "\(namespace)-\(name)", image: "registry.local/app:1", kind: .nativeProcess,
        phase: "Running", health: .running, ready: true, restarts: 0, ports: [], owner: owner, created: nil,
        cpuRequest: nil, memoryRequest: nil, nodeName: nil)
}
