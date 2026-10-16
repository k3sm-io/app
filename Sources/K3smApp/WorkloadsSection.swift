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

/// WorkloadsSection is the pods, grouped by namespace, under a column header;
/// one row per pod, the selected one highlighted.
struct WorkloadsSection: View {
    @ObservedObject var model: WorkloadsModel

    var body: some View {
        VStack(spacing: 0) {
            PodColumns.header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch model.reading {
                    case nil: note("Reading the pod list…")
                    case .binaryMissing: note("k3sm is not installed on this Mac.")
                    case .cliError(let message): note(StatusDisplay.errorText(message))
                    case .listed(let w) where w.pods.isEmpty: note("No pods on this Mac. Apply a manifest with kubectl and it appears here.")
                    case .listed(let w):
                        ForEach(w.namespaces, id: \.self) { ns in
                            NamespaceGroup(namespace: ns, pods: model.visible(w.pods(in: ns)), model: model)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 14)
            }
            if let at = model.readAt {
                Text(verbatim: "live from this Mac, \(at.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(Palette.dimText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 8)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Palette.ink2).padding(20)
    }
}

/// NamespaceGroup is one namespace's heading and its pods; a namespace the
/// search empties is left out.
struct NamespaceGroup: View {
    let namespace: String
    let pods: [Pod]
    @ObservedObject var model: WorkloadsModel

    var body: some View {
        if !pods.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.dimText)
                Text(verbatim: StatusDisplay.clip(namespace)).font(.system(size: 13, weight: .semibold))
                Text(verbatim: "\(pods.count) \(pods.count == 1 ? "pod" : "pods")").font(.system(size: 12)).foregroundStyle(Palette.ink2)
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
            ForEach(pods, id: \.uid) { pod in
                PodRow(pod: pod, node: model.nodeLabel(pod), selected: model.selected == pod.key)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(pod) }
            }
        }
    }
}

/// PodColumns is the one place the list's column widths live: the header
/// and every row lay out from it.
enum PodColumns {
    static let dot: CGFloat = 16
    static let node: CGFloat = 84
    static let runsAs: CGFloat = 74
    static let cores: CGFloat = 54
    static let memory: CGFloat = 66
    static let age: CGFloat = 50
    static let spacing: CGFloat = 12

    static var header: some View {
        HStack(spacing: spacing) {
            Color.clear.frame(width: dot, height: 1)
            Text("Pod").frame(maxWidth: .infinity, alignment: .leading)
            Text("Node").frame(width: node, alignment: .leading)
            Text("Runs as").frame(width: runsAs, alignment: .leading)
            Text("Cores").frame(width: cores, alignment: .trailing)
            Text("Memory").frame(width: memory, alignment: .trailing)
            Text("Age").frame(width: age, alignment: .trailing)
        }
        .font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
        .padding(.horizontal, 20).padding(.top, 10)
    }
}

/// PodRow is one line: health dot, name over image, the node it runs on,
/// how it runs, requests, age.
struct PodRow: View {
    let pod: Pod
    let node: PodNodeLabel
    let selected: Bool

    var body: some View {
        HStack(spacing: PodColumns.spacing) {
            Circle().fill(Palette.health(pod.health.severity)).frame(width: 9, height: 9).frame(width: PodColumns.dot)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: StatusDisplay.clip(pod.name)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(verbatim: StatusDisplay.clip(pod.image)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.dimText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NodeCell(label: node).frame(width: PodColumns.node, alignment: .leading)
            HStack(spacing: 6) {
                KindMark(kind: pod.kind)
                Text(verbatim: WorkloadsDisplay.runsAs(pod.kind)).font(.system(size: 11.5)).foregroundStyle(Palette.ink2)
            }
            .frame(width: PodColumns.runsAs, alignment: .leading)
            figure(WorkloadsDisplay.cores(pod.cpuRequest), width: PodColumns.cores)
            figure(WorkloadsDisplay.bytes(pod.memoryRequest), width: PodColumns.memory)
            figure(WorkloadsDisplay.age(pod.created), width: PodColumns.age)
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(selected ? Palette.tint : Color.clear)
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 2).fill(Palette.blue).frame(width: 3).padding(.vertical, 9) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func figure(_ text: String, width: CGFloat) -> some View {
        Text(verbatim: text).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.ink2).frame(width: width, alignment: .trailing)
    }
}

/// NodeCell is the row's node column: a dim dash before the pod is
/// scheduled, the "this Mac" tag (the navy panel's, on the light surface) for
/// this Mac's node, the node's clipped name in dim text otherwise.
struct NodeCell: View {
    let label: PodNodeLabel

    var body: some View {
        switch label {
        case .thisMac:
            Text(verbatim: label.text).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.navy)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(Palette.navy.opacity(0.4), lineWidth: 1))
                .fixedSize()
        case .unscheduled, .node:
            Text(verbatim: label.text).font(.system(size: 11.5)).foregroundStyle(Palette.dimText)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// KindMark is the small square that says how a pod runs: solid navy for a
/// native process, dashed amber for a Linux VM.
struct KindMark: View {
    let kind: WorkloadKind

    var body: some View {
        let vm = kind == .linuxVM
        RoundedRectangle(cornerRadius: 2.5)
            .strokeBorder(vm ? Palette.vm : Palette.navy, style: StrokeStyle(lineWidth: 1.5, dash: vm ? [2, 2] : []))
            .frame(width: 10, height: 10)
    }
}
