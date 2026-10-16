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

@Suite("the Workloads cleanup of finished pods")
struct PodCleanupTests {
    static func pod(_ name: String, _ namespace: String = "shop", phase: String, reason: String = "", uid: String? = nil) -> Pod {
        Pod(name: name, namespace: namespace, uid: uid ?? "\(namespace)-\(name)", image: "", kind: .nativeProcess, phase: phase,
            health: .waiting(""), ready: false, restarts: 0, ports: [], owner: nil, created: nil,
            cpuRequest: nil, memoryRequest: nil, nodeName: nil, reason: reason)
    }

    static let list: [Pod] = Workloads(pods: [
        pod("web-1", phase: "Running"),
        pod("job-a", phase: "Succeeded"),
        pod("job-b", phase: "Failed"),
        pod("evicted", phase: "Failed", reason: "Evicted"),
        pod("evicted-odd", phase: "Running", reason: "Evicted"),
        pod("starting", phase: "Pending"),
        pod("lost", phase: "Unknown"),
        pod("nophase", phase: ""),
        pod("done", "batch", phase: "Succeeded"),
        pod("--all", "batch", phase: "Succeeded"),
        pod("x", "-A", phase: "Failed"),
        pod("nouid", "batch", phase: "Failed", uid: ""),
        pod("lower", phase: "succeeded"),
    ]).pods

    @Test("selects pods that succeeded, failed or were evicted, and nothing that runs or waits")
    func completedAndFailedPodsSelection() {
        #expect(PodCleanup.selection(Self.list).map(\.key)
            == ["batch/done", "shop/evicted", "shop/evicted-odd", "shop/job-a", "shop/job-b"])
        #expect(PodCleanup.selection([Self.pod("web-1", phase: "Running")]).isEmpty)
        #expect(PodCleanup.request(for: [Self.pod("web-1", phase: "Running")]) == nil)
        #expect(PodCleanup.bulkActions(for: [Self.pod("web-1", phase: "Running")]).isEmpty)
        #expect(PodCleanup.bulkActions(for: nil).isEmpty)
    }

    @Test("one delete per namespace, every name through ResourceName, without waiting")
    func cleanupArgumentsGolden() throws {
        let request = try #require(PodCleanup.request(for: Self.list))
        #expect(request.runs == [
            ["kubectl", "delete", "pod", "done", "-n", "batch", "--wait=false"],
            ["kubectl", "delete", "pod", "evicted", "evicted-odd", "job-a", "job-b", "-n", "shop", "--wait=false"],
        ])
        #expect(request.arguments == request.runs[0])
        #expect(request.precheckArguments == ["kubectl", "get", "pods", "-A", "-o",
            #"jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.uid}{"\n"}{end}"#])
        #expect(request.kind == .delete)
        #expect(request.rowKey == ActionMenu.bulkRowKey)
        #expect(request.count == 5)
    }

    @Test("the confirmation names the count and the namespaces")
    func cleanupConfirmation() throws {
        let c = try #require(PodCleanup.request(for: Self.list)).confirmation
        #expect(c.title == "Delete 5 pods that completed or failed?")
        #expect(c.message == "k3sm deletes the 5 pods in batch and shop that completed, failed or were evicted. Their logs and status go with them; running pods are not touched.")
        #expect(c.verbTitle == "Delete completed and failed pods")
        #expect(c.destructive)
        let one = try #require(PodCleanup.request(for: [Self.pod("job-a", phase: "Succeeded")])).confirmation
        #expect(one.title == "Delete 1 pod that completed or failed?")
        #expect(one.message.hasPrefix("k3sm deletes the pod in shop that completed"))
        let item = try #require(PodCleanup.bulkActions(for: Self.list).first)
        #expect(item.title == "Delete completed and failed pods…")
    }

    @Test("the namespace list reads as a sentence and stops at four")
    func namespaceList() {
        #expect(PodCleanup.namespaceList(["a"]) == "a")
        #expect(PodCleanup.namespaceList(["a", "b"]) == "a and b")
        #expect(PodCleanup.namespaceList(["a", "b", "c"]) == "a, b and c")
        #expect(PodCleanup.namespaceList(["a", "b", "c", "d", "e", "f"]) == "a, b, c, d and 2 more")
    }

    @Test("the UID read refuses a name that now carries another UID, and lets a gone pod pass")
    func cleanupPrecheck() throws {
        let request = try #require(PodCleanup.request(for: Self.list))
        let same = "shop/web-1 shop-web-1\nshop/job-a shop-job-a\nbatch/done batch-done\n"
        #expect(request.precheck(.exited(status: 0, output: Data(same.utf8))) == nil)
        let recreated = "shop/job-b shop-job-b-new\n"
        #expect(request.precheck(.exited(status: 0, output: Data(recreated.utf8)))
            == .refused("Cleanup refused: a pod changed since you clicked; nothing was deleted. Look again and retry."))
        #expect(request.precheck(.exited(status: 1, output: Data("Unable to connect\n".utf8)))
            == .failed("Cleanup failed; nothing was deleted. kubectl said: Unable to connect"))
        #expect(request.precheck(.noAnswer) == .failed("Cleanup failed: the k3sm CLI did not answer the pod check; nothing was deleted."))
        #expect(request.precheck(.missing) == .failed("Cleanup failed: k3sm is not installed on this Mac."))
    }

    struct ReportCase: Sendable, CustomTestStringConvertible {
        let name: String
        let runs: [ActionRun]
        let want: ActionOutcome
        var testDescription: String { name }
    }

    static func exited(_ status: Int32, _ text: String) -> ActionRun { .exited(status: status, output: Data(text.utf8)) }

    static let reportCases: [ReportCase] = [
        ReportCase(name: "every namespace deleted", runs: [exited(0, ""), exited(0, "")],
                   want: .succeeded("Deleted 5 pods that completed or failed.")),
        ReportCase(name: "one already gone", runs: [exited(0, ""), exited(1, """
            pod "evicted" deleted
            pod "evicted-odd" deleted from shop namespace
            pod "job-a" deleted
            Error from server (NotFound): pods "job-b" not found
            """)],
                   want: .succeeded("Deleted 4 pods that completed or failed. 1 pod was already gone.")),
        ReportCase(name: "a refusal in one namespace is quoted", runs: [exited(1, "Error from server (Forbidden): pods \"done\" is forbidden\u{202E}\n"), exited(0, "")],
                   want: .failed("Deleted 4 of 5 pods. Not all deleted in batch: kubectl said: Error from server (Forbidden): pods \"done\" is forbidden")),
        ReportCase(name: "no answer in one namespace", runs: [exited(0, ""), .noAnswer],
                   want: .failed("Deleted 1 of 5 pods. Not all deleted in shop: the k3sm CLI did not answer; refresh to see what was deleted")),
        ReportCase(name: "a missing CLI", runs: [.missing, .missing], want: .failed("Cleanup failed: k3sm is not installed on this Mac.")),
        ReportCase(name: "a refused CLI", runs: [.refused("owned by\nmallory"), .refused("x")],
                   want: .failed("Cleanup failed: the installed k3sm failed the app's check (owned by mallory), so it was not run.")),
    ]

    @Test("one report for every namespace's run", arguments: reportCases)
    func cleanupReport(_ c: ReportCase) throws {
        let request = try #require(PodCleanup.request(for: Self.list))
        #expect(request.report(runs: c.runs) == c.want)
    }

    @Test("a bulk action's report finishes on the bulk row and clears on the next good read")
    func bulkReport() throws {
        let request = try #require(PodCleanup.request(for: Self.list))
        let report = ActionReport.pending(request).confirmed().finished(request.report(runs: [Self.exited(0, ""), Self.exited(0, "")]))
        #expect(report.rowKey == ActionMenu.bulkRowKey && report.section == .workloads && report.phase == .succeeded)
        #expect(report.refreshDone().afterRead(of: .workloads, succeeded: true) == nil)
    }
}
