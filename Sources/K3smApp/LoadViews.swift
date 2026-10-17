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

/// LiveLoadRow is one node's live load on the navy panel: its CPU and memory
/// bars with their numbers side by side; "no metrics yet" when the sample
/// does not carry it.
struct LiveLoadRow: View {
    let load: NodeLoad

    var body: some View {
        switch load {
        case .noSample:
            Text(verbatim: load.text).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        case .sampled(let cpu, let memory):
            HStack(alignment: .bottom, spacing: 10) {
                bar("CPU", cpu).help(Help.Panel.liveCPU)
                bar("Memory", memory).help(Help.Panel.liveMemory)
            }
        }
    }

    /// A 5 pt bar of the share used, with "CPU 1.43 of 19 cores · 8%" under it.
    private func bar(_ title: String, _ bar: LoadBar) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Meter(parts: [(bar.fraction ?? 0, Palette.fill)], total: 1)
            Text(verbatim: "\(title) \(bar.text)").font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.62)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Sparkline is a line through shares from 0 to 1, oldest on the left.
struct Sparkline: View {
    let points: [Double]

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let step = geo.size.width / CGFloat(max(1, points.count - 1))
                for (i, share) in points.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(max(0, min(1, share)))))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(Palette.fill, lineWidth: 1.2)
        }
    }
}

/// MetricsNote is the line under the live rows: the sample's age, kept
/// current, the last failure, or why the rows are hidden; nothing before
/// the first read.
struct MetricsNote: View {
    let state: MetricsState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let note = MetricsDisplay.note(state, now: context.date) {
                Footnote(note)
            }
        }
    }
}

/// LiveLoadBlock is the This Mac view's live load: its node's row and the
/// note, or only the note while the rows are hidden.
struct LiveLoadBlock: View {
    let node: String?
    let nodes: [ClusterNode]?
    let state: MetricsState

    var body: some View {
        let load = node.flatMap { MetricsDisplay.nodeLoad(named: $0, nodes: nodes, state: state) }
        if load != nil || MetricsDisplay.note(state) != nil {
            PanelBlock("Load now", value: "") {
                if let load {
                    LiveLoadRow(load: load)
                }
                MetricsNote(state: state)
            }
        }
    }
}
