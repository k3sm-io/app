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

import K3smStatus
import SwiftUI

/// Inspector is the right column: the selected pod's facts, the actions it
/// offers (its `ActionMenu`, each asked of the shared `ActionRunner`, whose
/// confirmation the console shows), Scale on its Deployment or StatefulSet,
/// the last action's line, the Summarize Logs panel when it ran on this
/// pod, then its events or manifest verbatim (`PodDetail.inspectorTabs`).
/// The log is not here: Open Log opens it in the log pane along the bottom
/// of the window (`LogPaneView`), where Follow streams it.
struct Inspector: View {
    @ObservedObject var model: WorkloadsModel
    @ObservedObject var runner: ActionRunner
    /// Opens the pod's log in the log pane.
    let openLog: (Pod) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pod = model.selectedPod {
                heading(pod)
                facts(pod)
                actions
                scale(pod)
                LogSummaryPanel(summaries: model.summaries, podKey: pod.key)
                detailTabs(pod)
                pane
            } else {
                Text("Select a pod.").foregroundStyle(Palette.ink2).padding(18)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface)
    }

    /// The detail pane: the selected tab's read, the events or the manifest.
    private var pane: some View {
        ScrollView {
            Text(verbatim: model.detailLoading ? "loading…" : model.detailText)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .background(Palette.wash)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
        .padding([.horizontal, .bottom], 14)
    }

    /// Scale on the pod's Deployment or StatefulSet (`WorkloadControls.scaleOffer`):
    /// a stepper from 1 to 50 and Scale, asked of the runner behind its
    /// confirmation; the line saying to Resume first while it is paused;
    /// nothing for a DaemonSet's pod or any other.
    @ViewBuilder
    private func scale(_ pod: Pod) -> some View {
        switch WorkloadControls.scaleOffer(for: pod, in: model.controllers) {
        case .scalable(let controller, let current)?:
            let count = model.scaleCount(for: controller, current: current)
            let request = WorkloadControls.scaleRequest(for: controller, to: count,
                                                        moved: model.scaleMoved(for: controller))
            HStack(spacing: 10) {
                Stepper(value: Binding(get: { count }, set: { model.setScaleCount($0, for: controller) }),
                        in: WorkloadControls.scaleRange) {
                    Text(verbatim: "Replicas: \(count)").font(.system(size: 12.5).monospacedDigit())
                }
                .help(Help.Inspector.scaleStepper)
                Button("Scale…") { if let request { runner.ask(request) } }
                    .disabled(request == nil || runner.busy || runner.pending != nil)
                    .help(Help.Inspector.scale)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        case .refused(let note)?:
            Text(verbatim: "Scale: " + note).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        case nil:
            EmptyView()
        }
    }

    /// The selected pod's actions and the last action's line (`RowActions`,
    /// the block every tab's inspector shares).
    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowActions(menu: model.selectedMenu, section: .workloads, rowKey: model.selected, runner: runner)
            // Pause, Resume, Scale and Rollout Restart report on the
            // controller's row key, so their line stays while the pod is
            // gone; it shows here too.
            if let pod = model.selectedPod, let key = WorkloadControls.controllerKey(for: pod, in: model.controllers),
               let report = runner.report(section: .workloads, rowKey: key) {
                Text(verbatim: report.text).font(.system(size: 11.5))
                    .foregroundStyle(report.failed ? Palette.bad : Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.horizontal, 18).padding(.vertical, 8)
            }
        }
    }

    private func heading(_ pod: Pod) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: StatusDisplay.clip(pod.name)).font(.system(size: 16, weight: .semibold))
            HStack(spacing: 7) {
                Circle().fill(Palette.health(pod.health.severity)).frame(width: 9, height: 9)
                Text(verbatim: StatusDisplay.clip(pod.health.text)).font(.system(size: 12.5)).foregroundStyle(Palette.ink2)
            }
        }
        .padding(18)
        .padding(.top, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func facts(_ pod: Pod) -> some View {
        let vm = pod.kind == .linuxVM
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            fact("Runs as", vm ? "A Linux micro-VM, one per pod" : "A native macOS process")
            fact("Isolation", vm ? "Virtualization.framework" : "Seatbelt sandbox, default deny")
            fact("Image", pod.image, mono: true)
            fact("Ports", pod.ports.isEmpty ? "none" : pod.ports.map(String.init).joined(separator: ", "), mono: true)
            fact("Namespace", pod.namespace)
            fact("Restarts", String(pod.restarts))
            if let owner = pod.owner { fact("Owned by", owner) }
            if let controller = WorkloadPause.controllerFact(for: pod, in: model.controllers) { fact("Controller", controller) }
            if let note = WorkloadPause.note(for: pod, in: model.controllers) { fact("Pause", note) }
            ForEach(model.loadFacts(pod), id: \.label) { fact($0.label, $0.value) }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func detailTabs(_ pod: Pod) -> some View {
        HStack(spacing: 4) {
            ForEach(PodDetail.inspectorTabs) { d in
                Button(d.rawValue) { model.detail = d; model.loadDetail() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: model.detail == d ? .medium : .regular))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(model.detail == d ? Palette.tint : Color.clear)
                    .foregroundStyle(model.detail == d ? Palette.navy : Palette.ink2)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help(Help.Inspector.detail(d.rawValue))
            }
            Spacer()
            Button("Open Log") { openLog(pod) }
                .controlSize(.small)
                .help(Help.Inspector.logs)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func fact(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Palette.dimText).frame(width: 86, alignment: .leading)
            Text(verbatim: StatusDisplay.clip(value)).font(.system(size: mono ? 11.5 : 12.5, design: mono ? .monospaced : .default)).textSelection(.enabled)
        }
    }
}
