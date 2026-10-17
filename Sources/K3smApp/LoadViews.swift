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

/// LiveLoadRow is the This Mac view's load: its CPU and memory bars side
/// by side, each with its figures under it led by its title, and "no
/// metrics yet" under them when the sample does not carry the node.
struct LiveLoadRow: View {
    let bars: NodeBars

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if bars.hasFigures {
                HStack(alignment: .top, spacing: CGFloat(PanelLayout.tileSpacing)) {
                    SlimMeter(title: "CPU", stack: bars.cpu, help: Help.Panel.liveCPU, titled: true)
                    SlimMeter(title: "Memory", stack: bars.memory, help: Help.Panel.liveMemory, titled: true)
                }
            }
            if let note = bars.note {
                Text(verbatim: note).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

/// StackedBar is a `LoadStack` drawn: the requested share as a light band
/// on the panel's track, the used share solid over it from the same start.
struct StackedBar: View {
    let stack: LoadStack
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if let requested = stack.requested {
                    Rectangle().fill(Palette.loadPart(.requested)).frame(width: geo.size.width * requested)
                }
                if let used = stack.used {
                    Rectangle().fill(Palette.loadPart(.used)).frame(width: geo.size.width * used)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: height)
        .background(Palette.deep2)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
    }
}

/// LoadKey is the one key under a block of load bars: a swatch and the
/// word for each part the bars draw (`LoadStack.key`); nothing when none.
struct LoadKey: View {
    let parts: [LoadPart]

    var body: some View {
        if !parts.isEmpty {
            HStack(spacing: 12) {
                ForEach(parts, id: \.self) { part in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.loadPart(part))
                            .background(RoundedRectangle(cornerRadius: 2).fill(Palette.deep2))
                            .frame(width: 8, height: 8)
                        Text(verbatim: part.label)
                    }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.62))
        }
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

/// LiveLoadBlock is the This Mac view's load: its node's bars, joined
/// from its pods' requests (`row`) and the live sample, the key and the
/// note; only the note while neither figure is known.
struct LiveLoadBlock: View {
    let node: String?
    let row: ClusterNodeRow?
    let nodes: [ClusterNode]?
    let state: MetricsState

    var body: some View {
        let bars = NodeBars.of(row: row, load: node.flatMap { MetricsDisplay.nodeLoad(named: $0, nodes: nodes, state: state) })
        if bars.hasFigures || bars.note != nil || MetricsDisplay.note(state) != nil {
            PanelBlock("Load now", value: "") {
                LiveLoadRow(bars: bars)
                LoadKey(parts: LoadStack.key(bars.stacks))
                MetricsNote(state: state)
            }
        }
    }
}
