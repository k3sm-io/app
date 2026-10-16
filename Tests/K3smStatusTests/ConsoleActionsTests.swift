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

@Suite("the console's shared action mechanics")
struct ConsoleActionsTests {
    @Test("a failed run's report carries kubectl's quoted text and clears on the next good poll")
    func writeFailureRowCarriesStderr() throws {
        let request = try #require(PodActions.request(.restart, for: ownedPod()))
        // kubectl's error arrives on the output pipe (keepErrors) with a
        // bidi override and a second line, which errorText cleans.
        let stderr = Data("Error from server (Forbidden): pods \"web-1\" is forbidden:\n User \"dev\"\u{202E} cannot delete\n".utf8)
        var report = ActionReport.pending(request).confirmed()
        report = report.finished(request.report(.exited(status: 1, output: stderr)))
        #expect(report.phase == .failed)
        #expect(report.failed)
        #expect(report.text == "Restart failed. kubectl said: Error from server (Forbidden): pods \"web-1\" is forbidden: User \"dev\" cannot delete")
        #expect(report.section == .workloads)
        #expect(report.rowKey == "shop/web-1")

        // The read the runner asks for after the write returns with the
        // report still shown beside it.
        var kept = try #require(report.afterRead(of: .workloads, succeeded: true))
        kept = kept.refreshDone()
        // A failed read or another tab's read keeps it.
        #expect(kept.afterRead(of: .workloads, succeeded: false) == kept)
        #expect(kept.afterRead(of: .services, succeeded: true) == kept)
        // The next good read of its own tab clears it.
        #expect(kept.afterRead(of: .workloads, succeeded: true) == nil)
    }

    @Test("the lifecycle runs pending, running, then the outcome's phase")
    func lifecycleTransitions() throws {
        let request = try #require(PodActions.request(.restart, for: ownedPod()))
        let pending = ActionReport.pending(request)
        #expect(pending.phase == .pending)
        #expect(pending.actionID == request.id)
        #expect(!pending.finished)
        #expect(pending.cancelled() == nil)
        // A pending action is not finished by a run, and is not refreshed.
        #expect(pending.finished(.succeeded("x")) == pending)
        #expect(pending.refreshDone() == pending)

        let running = pending.confirmed()
        #expect(running.phase == .running)
        #expect(running.text.isEmpty)
        #expect(running.confirmed() == running)
        #expect(running.cancelled() == running)
        // No read clears an action still running.
        #expect(running.refreshDone().afterRead(of: .workloads, succeeded: true) == running)

        let ok = running.finished(.succeeded("Restart asked."))
        #expect(ok.phase == .succeeded && !ok.failed && ok.text == "Restart asked.")
        let failed = running.finished(.failed("Restart failed."))
        #expect(failed.phase == .failed && failed.failed)
        let refused = running.finished(.refused("Restart refused."))
        #expect(refused.phase == .refused && refused.failed)
        // A finished report is final: another outcome does not replace it.
        #expect(ok.finished(.failed("later")) == ok)
        #expect(ok.cancelled() == ok)
        // Before the runner's read returns, a good read keeps it.
        #expect(ok.afterRead(of: .workloads, succeeded: true) == ok)
        #expect(ok.refreshDone().afterRead(of: .workloads, succeeded: true) == nil)
    }

    @Test("a refusing pre-check reads as refused, and nothing runs")
    func precheckRefusal() throws {
        let request = try #require(PodActions.request(.restart, for: ownedPod()))
        #expect(request.precheckArguments == request.verifyArguments)
        let refusal = try #require(request.precheck(.exited(status: 0, output: Data("another-uid".utf8))))
        let report = ActionReport.pending(request).confirmed().finished(refusal)
        #expect(report.phase == .refused)
        #expect(report.text == "Restart refused: the pod changed since you clicked; nothing was deleted.")
        #expect(request.precheck(.exited(status: 0, output: Data("shop-web-1".utf8))) == nil)
    }

    @Test("the context menu, the inspector and the Delete key read one list")
    func rowMenuIsTheInspectorList() throws {
        let pod = ownedPod()
        let menu = PodActions.menu(for: pod)
        let restart = try #require(PodActions.request(.restart, for: pod))
        #expect(menu.items.map(\.id) == PodActions.available(for: pod).compactMap { PodActions.request($0, for: pod)?.id })
        #expect(menu.items.map(\.title) == ["Restart…"])
        #expect(menu.items.first?.request as? PodActionRequest == restart)
        // Restart is destructive but not a delete, so a row whose only
        // destructive action is Restart puts nothing on the Delete key.
        #expect(menu.items.first?.destructive == true)
        #expect(menu.items.first?.kind == .change)
        #expect(menu.deleteKeyItem == nil)
        // A pod with no action offers no menu and no Delete key.
        let bare = PodActions.menu(for: Pod(
            name: "bare", namespace: "shop", uid: "u", image: "", kind: .nativeProcess, phase: "Running", health: .running,
            ready: true, restarts: 0, ports: [], owner: nil, created: nil, cpuRequest: nil, memoryRequest: nil, nodeName: nil))
        #expect(bare.isEmpty)
        #expect(bare.deleteKeyItem == nil)
    }

    @Test("the Delete key is offered only when it cannot be someone else's key, and only for a delete")
    func deleteKeyDecision() {
        let delete = KindRequest(id: "delete", kind: .delete)
        let restartLike = KindRequest(id: "restart-like", kind: .change)
        #expect(ActionMenu([restartLike]).deleteKeyItem == nil)
        #expect(ActionMenu([restartLike, delete]).deleteKeyItem?.id == "delete")
        #expect(ActionMenu([delete, KindRequest(id: "delete-2", kind: .delete)]).deleteKeyItem?.id == "delete")

        #expect(DeleteKey.matches(code: 51, commandOptionOrControl: false, editingText: false, sheetShown: false, tourShown: false))
        #expect(DeleteKey.matches(code: 117, commandOptionOrControl: false, editingText: false, sheetShown: false, tourShown: false))
        #expect(!DeleteKey.matches(code: 0, commandOptionOrControl: false, editingText: false, sheetShown: false, tourShown: false))
        #expect(!DeleteKey.matches(code: 51, commandOptionOrControl: true, editingText: false, sheetShown: false, tourShown: false))
        #expect(!DeleteKey.matches(code: 51, commandOptionOrControl: false, editingText: true, sheetShown: false, tourShown: false))
        #expect(!DeleteKey.matches(code: 51, commandOptionOrControl: false, editingText: false, sheetShown: true, tourShown: false))
        #expect(!DeleteKey.matches(code: 51, commandOptionOrControl: false, editingText: false, sheetShown: false, tourShown: true))
    }
}

/// A destructive request of a given kind, for the Delete key's lookup.
private struct KindRequest: ConsoleActionRequest {
    let id: String
    let kind: ActionKind
    var section: ConsoleSection { .workloads }
    var rowKey: String { "shop/web-1" }
    var verb: String { id }
    var arguments: [String] { [] }
    var confirmation: ActionConfirmation {
        ActionConfirmation(title: id, message: "", verbTitle: id, cancelTitle: "Cancel", destructive: true)
    }
    func report(_ run: ActionRun) -> ActionOutcome { .succeeded("") }
}

private func ownedPod() -> Pod {
    Pod(name: "web-1", namespace: "shop", uid: "shop-web-1", image: "registry.local/app:1", kind: .nativeProcess,
        phase: "Running", health: .running, ready: true, restarts: 0, ports: [], owner: "ReplicaSet web-5f6d", created: nil,
        cpuRequest: nil, memoryRequest: nil, nodeName: nil)
}
