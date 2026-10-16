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

import CoreGraphics
import Foundation

/// TourTarget is what one stop of the guided tour points at.
public enum TourTarget: String, CaseIterable, Sendable {
    /// The panel's top: the machine, its state and the tiles.
    case summary
    /// The panel's core grid and memory meter.
    case cores
    /// The tab strip above the middle column.
    case tabs
    /// The pod list.
    case pods
    /// The inspector on the right.
    case inspector
    /// The info button that opens the status panel.
    case info

    /// Whether the target is in the console's left panel, which scrolls.
    public var inPanel: Bool { self == .summary || self == .cores }
}

/// TourStep is one stop: what it points at and what it says.
public struct TourStep: Sendable, Equatable {
    public let target: TourTarget
    public let title: String
    public let text: String
}

/// Tour is the guided tour's content and its pure decisions: the stops in
/// order, how the keyboard steps through them, the console layout it shows
/// them in, and where the caption card goes.
public enum Tour {
    /// steps is the tour for this Mac's place in its cluster: the first
    /// stop says what the panel's heading says (`ClusterDisplay.shape`),
    /// and the other five are the same everywhere.
    public static func steps(for shape: ClusterShape) -> [TourStep] {
        [first(for: shape)] + rest
    }

    /// The number of stops, whatever the shape.
    public static let count = 1 + rest.count

    /// tabsStop names every tab in the strip, read from `ConsoleSection`, so
    /// the stop stays true as tabs are added.
    static var tabsStop: TourStep {
        TourStep(target: .tabs, title: "The tabs",
                 text: "Each tab is one view of the cluster: \(list(ConsoleSection.allCases.map(\.title))). Workloads also shows the cluster's events.")
    }

    /// list joins words the way a sentence does: "A", "A and B", "A, B and C".
    static func list(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
    }

    /// first is the summary stop, true for each shape.
    public static func first(for shape: ClusterShape) -> TourStep {
        switch shape {
        case .single:
            return TourStep(target: .summary, title: "This Mac is the cluster",
                            text: "One Mac runs the whole thing: control plane, scheduler and the workloads, with no Linux virtual machine in the way. What you see on the left is the machine itself.")
        case .serverWithWorkers(let macs):
            return TourStep(target: .summary, title: "This Mac runs the cluster",
                            text: "This Mac is the server for a cluster of \(macs) Macs: it runs the control plane and the scheduler, and every Mac runs workloads, with no Linux virtual machine in the way. The panel shows this Mac; its switch shows the whole cluster.")
        case .worker:
            return TourStep(target: .summary, title: "This Mac has joined a cluster",
                            text: "This Mac is a worker: the control plane runs on the server Mac, and this Mac runs the workloads it is given, with no Linux virtual machine in the way. What you see on the left is this Mac.")
        case .unknown:
            return TourStep(target: .summary, title: "This Mac",
                            text: "What you see on the left is this Mac: its state, what its pods ask of it, and what it has. The rest of the cluster shows here once k3sm reports it.")
        }
    }

    static let rest: [TourStep] = [
        TourStep(target: .cores, title: "Cores and memory, by pod",
                 text: "What the pods use, filled, and ask for, outlined, against what this Mac has. Squares are performance cores, circles efficiency cores."),
        tabsStop,
        TourStep(target: .pods, title: "Workloads",
                 text: "Pods grouped by namespace. \"Process\" is a native macOS process under a default-deny sandbox; \"Linux VM\" is a Linux container in a small virtual machine, used only when a workload needs Linux."),
        TourStep(target: .inspector, title: "The inspector",
                 text: "Click a pod for how it runs, what isolates it, and its logs, events and manifest, straight from the API server."),
        TourStep(target: .info, title: "Start, stop and settings",
                 text: "k3sm on this Mac: its state, any check that needs attention, start, stop and update, behind this button. Connections from other devices and uninstall are in Settings, behind the gear."),
    ]

    /// Key is what a key does while the tour runs.
    public enum Key: Equatable, Sendable {
        case next, back, end
    }

    /// key maps a key code to a tour action: the right and down arrows,
    /// Return and Space go forward, the left and up arrows go back, Escape
    /// ends. Any other key, or one held with Command, Option or Control,
    /// passes through.
    public static func key(code: UInt16, commandOptionOrControl: Bool) -> Key? {
        guard !commandOptionOrControl else { return nil }
        switch code {
        case 124, 125, 36, 49: return .next
        case 123, 126: return .back
        case 53: return .end
        default: return nil
        }
    }

    /// step applies `key` to the current stop: the stop after or before it,
    /// or nil when the tour ends (Escape, or forward from the last stop).
    public static func step(after key: Key, from i: Int) -> Int? {
        switch key {
        case .next: return i + 1 < count ? i + 1 : nil
        case .back: return max(0, i - 1)
        case .end: return nil
        }
    }

    /// Layout is the part of the console's state the tour depends on.
    public struct Layout: Equatable, Sendable {
        public var section: ConsoleSection
        public var workloadsView: WorkloadsView
        public var panelCollapsed: Bool
        public var panelMode: PanelMode?
        public var inspectorShown: Bool

        public init(section: ConsoleSection, workloadsView: WorkloadsView, panelCollapsed: Bool, panelMode: PanelMode?, inspectorShown: Bool) {
            self.section = section
            self.workloadsView = workloadsView
            self.panelCollapsed = panelCollapsed
            self.panelMode = panelMode
            self.inspectorShown = inspectorShown
        }
    }

    /// shown is the layout every stop can be seen in: the Workloads tab on
    /// its pod list, the panel open on This Mac, and the inspector shown. The tour applies it
    /// while it runs and puts the user's layout back when it ends.
    public static let shown = Layout(section: .workloads, workloadsView: .pods, panelCollapsed: false, panelMode: .thisMac, inspectorShown: true)

    /// local converts a rectangle in window coordinates (origin at the
    /// bottom left) to the coordinates of a view whose own frame in the
    /// window is `view` (origin at its top left, y down).
    public static func local(_ rect: CGRect, in view: CGRect) -> CGRect {
        CGRect(x: rect.minX - view.minX, y: view.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// highlight is the lit box around a stop: the stop's frame padded by
    /// `pad`, kept `margin` inside the view so its glow stays in the window
    /// when the stop runs to an edge (the tab strip at the top, the pod list
    /// to the bottom, the inspector on the right).
    public static func highlight(_ r: CGRect, in size: CGSize, pad: CGFloat = 8, margin: CGFloat = 3) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
        let padded = r.insetBy(dx: -pad, dy: -pad).intersection(bounds)
        return padded.isNull ? r : padded
    }

    /// card is the caption card's origin: right of the target, else below,
    /// left, above; the first that fits inside `size` with a margin and does
    /// not cover the target. When none fits, a stop big enough to hold the
    /// card (the pod list) takes it in its lower-right corner, over its own
    /// empty space rather than a neighbour; otherwise it is clamped inside.
    public static func card(_ card: CGSize, by r: CGRect, in size: CGSize) -> CGPoint {
        let m: CGFloat = 12, gap: CGFloat = 22
        func clampX(_ x: CGFloat) -> CGFloat { max(m, min(size.width - card.width - m, x)) }
        func clampY(_ y: CGFloat) -> CGFloat { max(m, min(size.height - card.height - m, y)) }
        let tries = [
            CGPoint(x: r.maxX + gap, y: clampY(r.minY)),
            CGPoint(x: clampX(r.minX), y: r.maxY + gap),
            CGPoint(x: r.minX - card.width - gap, y: clampY(r.minY)),
            CGPoint(x: clampX(r.minX), y: r.minY - card.height - gap),
        ]
        for t in tries {
            let box = CGRect(origin: t, size: card)
            if box.minX < m || box.maxX > size.width - m || box.minY < m || box.maxY > size.height - m { continue }
            if !box.intersects(r) { return t }
        }
        let inset: CGFloat = 16
        if r.width >= card.width + 2 * inset, r.height >= card.height + 2 * inset {
            return CGPoint(x: clampX(r.maxX - card.width - inset), y: clampY(r.maxY - card.height - inset))
        }
        return CGPoint(x: clampX(r.maxX + gap), y: clampY(r.maxY + gap))
    }

    /// landing is where the guide settles by a stop: above its top-right
    /// corner; below it when the stop is near the top edge; and, when the
    /// stop runs from top to bottom (the inspector), perched on its top-left
    /// corner, on the box's edge, so it never covers the stop's content and
    /// never leaves the window.
    public static func landing(by r: CGRect, in size: CGSize) -> CGPoint {
        let edge: CGFloat = 20
        let x = max(edge, min(r.maxX - 6, size.width - edge))
        if r.minY > 40 { return CGPoint(x: x, y: r.minY - 12) }
        if r.maxY + 14 <= size.height - edge { return CGPoint(x: x, y: r.maxY + 14) }
        return CGPoint(x: max(edge, min(r.minX, size.width - edge)), y: max(edge, r.minY + 14))
    }

    /// flightPoint is where the guide is `t` (0 to 1) into a flight from `a`
    /// to `b`: a straight glide that eases out of the start and into the
    /// landing, kept inside `size`.
    public static func flightPoint(from a: CGPoint, to b: CGPoint, at t: Double, in size: CGSize) -> CGPoint {
        let u = min(max(t, 0), 1)
        let s = u * u * (3 - 2 * u)
        let x = Double(a.x) + (Double(b.x) - Double(a.x)) * s
        let y = Double(a.y) + (Double(b.y) - Double(a.y)) * s
        let margin = 16.0
        return CGPoint(x: min(max(x, margin), Double(size.width) - margin),
                       y: min(max(y, margin), Double(size.height) - margin))
    }

    /// flight is how long the guide takes to fly from one stop to the next.
    public static let flight: TimeInterval = 0.9

    /// reveal is how long after the guide sets off a stop is lit: when the
    /// guide lands, so it leads the tour rather than chasing the box. With
    /// Reduce Motion there is no flight, and the stop is lit at once.
    public static func reveal(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : flight
    }

    /// guideAngle is the guide's hinge angle while it flies, in degrees: a
    /// steady beat of `period` seconds that never goes past `peak`.
    public static func guideAngle(at t: TimeInterval, period: TimeInterval = 0.6, peak: Double = 55) -> Double {
        guard period > 0 else { return 0 }
        return peak * (1 - cos(2 * Double.pi * t / period)) / 2
    }
}
