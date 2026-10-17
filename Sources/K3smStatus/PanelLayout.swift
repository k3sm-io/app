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

/// PanelContent is what one region of the console's navy panel (the Cluster
/// view or the This Mac view) shows that decides how wide it could use: its
/// tiles, the Cluster view's node rows, the nodes block's lines, the
/// labelled lines with a value on the right (the memory block's heading and
/// its legend), and the This Mac view's load row. A node row's bars are
/// `nodeBars` at its index, or its requests alone past the end. Every
/// string in it is already clipped.
public struct PanelContent: Equatable, Sendable {
    public let tiles: [PanelTile]
    public let nodes: [ClusterNodeRow]
    public let nodeBars: [NodeBars]
    public let lines: [NodeLine]
    public let pairs: [PanelPair]
    public let loads: [NodeBars]

    public init(tiles: [PanelTile] = [], nodes: [ClusterNodeRow] = [], nodeBars: [NodeBars] = [], lines: [NodeLine] = [],
                pairs: [PanelPair] = [], loads: [NodeBars] = []) {
        self.tiles = tiles
        self.nodes = nodes
        self.nodeBars = nodeBars
        self.lines = lines
        self.pairs = pairs
        self.loads = loads
    }

    /// The bars of the node row at `index`.
    public func bars(at index: Int) -> NodeBars {
        index < nodeBars.count ? nodeBars[index] : NodeBars.of(row: nodes[index], load: nil)
    }
}

/// PanelPair is a panel line with a label on the left and its value on the
/// right, at 12 pt: a block's heading ("Unified memory", "12 GB of 64 GB")
/// or a legend row, which leads with a swatch.
public struct PanelPair: Equatable, Sendable {
    public let label: String
    public let value: String
    public let swatch: Bool

    public init(_ label: String, _ value: String, swatch: Bool = false) {
        self.label = label
        self.value = value
        self.swatch = swatch
    }
}

/// PanelLayout sizes the console's navy panel, the left pane of a split view
/// with a draggable divider. Its minimum is the panel's fixed width before
/// the split; its natural width, which is also its maximum, is the smallest
/// width at which nothing in either region compresses or clips: the tiles
/// in two columns at their natural width, the longest node row with its name,
/// role, pod count and both meters on one line, the nodes block's lines,
/// the memory block's heading and legend, and the live load rows, whichever
/// is widest across both regions, never past `ceiling`, with the panel's
/// `edge` on both sides. The panel measures that content as it draws it (the
/// ideal width of each block, `measured`), so the natural width is exactly
/// the content and its two edges; until the first layout it is estimated
/// from character counts at a conservative advance per point of font size,
/// which errs wide rather than truncating. The constants below are the ones
/// the panel's views draw with (the edge, a tile's inner padding, the gap
/// between tiles), so the estimate and the drawing cannot drift apart.
///
/// The natural width is fixed when the window lays out (`PanelWidth`), not
/// followed as the content changes: a live figure, a pod count or the
/// headline word never moves the divider, and content that would need more
/// room wraps or shortens inside the panel. The stored width (none while the
/// panel sits at its natural width) and collapsed state are read back
/// through `restoreWidth` and `restoreCollapsed`, both tolerant of any
/// stored value.
public enum PanelLayout {
    /// The panel's minimum width, its width before it could be resized.
    public static let minimum: Double = 250
    /// The widest the panel goes, whatever its content: a clipped node name
    /// can be 160 characters.
    public static let ceiling: Double = 720
    /// The user-defaults keys.
    public static let widthKey = "consolePanelWidth"
    public static let collapsedKey = "consolePanelCollapsed"

    /// The panel's padding on each side, from its edge to its content.
    public static let edge: Double = 20
    /// The panel's horizontal padding, both sides together.
    public static let padding: Double = 2 * edge
    /// The gap between tiles, and between a node row's parts.
    public static let tileSpacing: Double = 10
    /// A tile's inner padding on each side, from its edge to its figures.
    public static let tilePadding: Double = 10
    /// A slim meter's width when a node row is on one line.
    public static let meterWidth: Double = 96

    /// How wide one character is estimated, per point of font size.
    static let advance = 0.62

    /// A legend row's swatch and the gap after it.
    public static let swatchWidth: Double = 16
    /// The least gap a label keeps from its value on the right.
    public static let pairGap: Double = 8

    /// The width `regions` need with nothing compressed or clipped, at
    /// least `minimum`, never past `ceiling`: the widest block the panel
    /// measured (`measured`, its content without the edges) and both edges,
    /// or, before the panel has measured anything (nil, or not a positive
    /// finite width), the widest of every region's estimated content.
    public static func naturalWidth(regions: [PanelContent], measured: Double? = nil) -> Double {
        let wanted: Double
        if let measured, measured.isFinite, measured > 0 {
            wanted = measured.rounded(.up) + padding
        } else {
            wanted = regions.map(wantedWidth).max() ?? 0
        }
        return min(ceiling, max(minimum, wanted))
    }

    /// The panel's width range for `regions`: from `minimum` to the natural width.
    public static func widthRange(regions: [PanelContent], measured: Double? = nil) -> ClosedRange<Double> {
        minimum...naturalWidth(regions: regions, measured: measured)
    }

    /// The panel's width range for one region's `content`.
    public static func widthRange(content: PanelContent) -> ClosedRange<Double> {
        widthRange(regions: [content])
    }

    /// One region's widest part.
    static func wantedWidth(_ content: PanelContent) -> Double {
        [gridWidth(content.tiles), content.nodes.indices.map { nodeRowWidth(content.nodes[$0], bars: content.bars(at: $0)) }.max() ?? 0,
         content.lines.map(lineWidth).max() ?? 0, content.pairs.map(pairWidth).max() ?? 0,
         content.loads.map(loadWidth).max() ?? 0].max() ?? 0
    }

    /// `width` within `range`; a width that is not finite is the minimum.
    public static func clamp(_ width: Double, to range: ClosedRange<Double>) -> Double {
        guard width.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, width))
    }

    /// A stored width the user dragged, clamped to `minimum...ceiling`; nil
    /// (auto-sized) when none is stored, the value is not a finite number, or
    /// it is the minimum, which earlier releases stored as their default and
    /// on a layout reset. The content's own range narrows it again when the
    /// panel is drawn.
    public static func restoreWidth(from stored: Any?) -> Double? {
        let value: Double
        if let d = stored as? Double {
            value = d
        } else if let i = stored as? Int {
            value = Double(i)
        } else {
            return nil
        }
        guard value.isFinite, value != minimum else { return nil }
        return clamp(value, to: minimum...ceiling)
    }

    /// A stored collapsed flag; false when none is stored or it is not a Bool.
    public static func restoreCollapsed(from stored: Any?) -> Bool {
        (stored as? Bool) ?? false
    }

    /// How many columns `count` tiles take: always two (so the Cluster and
    /// This Mac figures are a 2 by 2 grid), one for a lone tile.
    public static func tileColumns(count: Int) -> Int {
        min(2, max(0, count))
    }

    /// The width of the tile grid: two columns, each as wide as the widest of
    /// `tileWidths` (every tile's whole width, its inner padding on both
    /// sides included), `tileSpacing` apart. The panel's tile grid lays its
    /// tiles out by it, so a measured grid and an estimated one agree.
    public static func tileGridWidth(_ tileWidths: [Double]) -> Double {
        guard let widest = tileWidths.max() else { return 0 }
        let columns = Double(tileColumns(count: tileWidths.count))
        return columns * widest + (columns - 1) * tileSpacing
    }

    /// The gaps from the panel's two edges to a tile row `rowWidth` wide in a
    /// panel `width` wide: the leading edge always, and on the trailing side
    /// what the row leaves of the width. A grid that fits stretches across the
    /// content, so both are `edge`; a grid wider than the content runs into the
    /// trailing edge, which is what the natural width must never allow.
    public static func tileMargins(width: Double, rowWidth: Double) -> (leading: Double, trailing: Double) {
        (edge, width - edge - max(rowWidth, width - padding))
    }

    /// One tile's estimated natural width: its inner padding on both sides
    /// and the wider of the value with its "of" beside it, and the label.
    static func tileWidth(_ tile: PanelTile) -> Double {
        let figure = text(tile.value, size: 20) + (tile.detail.map { 4 + text($0, size: 11) } ?? 0)
        return 2 * tilePadding + max(figure, text(tile.label, size: 11))
    }

    /// The tile grid (`tileGridWidth`), with the panel's padding.
    static func gridWidth(_ tiles: [PanelTile]) -> Double {
        guard !tiles.isEmpty else { return 0 }
        return padding + tileGridWidth(tiles.map(tileWidth))
    }

    /// A Cluster view node row on one line: the dot, the name, the "this Mac"
    /// tag, the role, the pod count, then both bars (its requests alone
    /// without `bars`).
    static func nodeRowWidth(_ node: ClusterNodeRow, bars: NodeBars? = nil) -> Double {
        var width = 7 + 6 + text(node.name, size: 12) + 6 + text(node.role, size: 11)
        if node.thisMac { width += 6 + text("this Mac", size: 9) + 10 }
        if let running = node.running { width += 4 + text("\(running) pods", size: 11) }
        let meters = (bars ?? NodeBars.of(row: node, load: nil)).stacks.map(stackMeterWidth)
        return padding + width + tileSpacing + meters.reduce(0, +) + tileSpacing
    }

    /// A node row's bar on the row's one line: `meterWidth`, or its widest
    /// figure line when that is wider, so no figure is cut off.
    public static func stackMeterWidth(_ stack: LoadStack) -> Double {
        max(meterWidth, stack.lines.map { text($0, size: 10) }.max() ?? 0)
    }

    /// A nodes-block line: the name, the role and the version, untruncated.
    static func lineWidth(_ line: NodeLine) -> Double {
        let version = line.version.map { 8 + text($0, size: 12) } ?? 0
        return padding + text(line.name, size: 12) + 8 + text(line.role, size: 12) + 8 + version
    }

    /// A label and its value on one line, with a swatch before a legend row's.
    static func pairWidth(_ pair: PanelPair) -> Double {
        padding + (pair.swatch ? swatchWidth : 0) + text(pair.label, size: 12) + pairGap + text(pair.value, size: 12)
    }

    /// The This Mac load row: the CPU and memory bars, each as wide as the
    /// widest figure line under either, the first led by its title,
    /// `tileSpacing` apart; nothing when neither bar has a figure.
    static func loadWidth(_ bars: NodeBars) -> Double {
        guard bars.hasFigures else { return 0 }
        let bar = [("CPU", bars.cpu), ("Memory", bars.memory)].flatMap { title, stack in
            stack.lines(titled: title).map { text($0, size: 10) }
        }.max() ?? 0
        return padding + 2 * bar + tileSpacing
    }

    private static func text(_ s: String, size: Double) -> Double {
        Double(s.count) * size * advance
    }
}

/// PanelWidth is the console panel's width over the window's life. The
/// natural width is fixed when the window lays out: when it opens (`open`)
/// and, the first time, when the panel first measures its content
/// (`measured`); a width the user dragged that is narrower than it is
/// replaced then, and only then. After that the width moves only on a drag
/// (`drag`), which is kept and saved, or on Reset Window Layout (`reset`);
/// content changes leave it where it is.
public struct PanelWidth: Equatable, Sendable {
    /// The natural width fixed at the last layout; nil before the first.
    public private(set) var natural: Double?
    /// The width the user dragged to, kept and saved; nil while the panel
    /// sits at its natural width.
    public private(set) var dragged: Double?
    /// Whether the layout still waits for the panel's first measurement.
    private var awaitingMeasure = false

    /// A panel restored with the width saved at the last drag, if any
    /// (`PanelLayout.restoreWidth`).
    public init(saved: Double?) {
        dragged = saved.map { PanelLayout.clamp($0, to: PanelLayout.minimum...PanelLayout.ceiling) }
    }

    /// The window opened (the first time, or again after it was closed) and
    /// laid out at `natural`. A `measured` natural width (the panel has
    /// drawn its content) decides now; an estimate fixes the width until the
    /// panel's first measurement, which decides once (`measured(_:)`).
    public mutating func open(natural: Double, measured: Bool) {
        if measured {
            awaitingMeasure = false
            layOut(natural)
        } else {
            awaitingMeasure = true
            self.natural = natural
        }
    }

    /// The panel measured its content at `natural`: it lays the panel out
    /// only while the window's layout waits for that first measurement.
    public mutating func measured(_ natural: Double) {
        guard awaitingMeasure else { return }
        awaitingMeasure = false
        layOut(natural)
    }

    /// A drag of the divider to `width`: kept, within `minimum...ceiling`,
    /// or the natural width again (nil) when it reaches it.
    public mutating func drag(to width: Double) {
        guard width.isFinite else { return }
        if let natural, width >= natural - 1 {
            dragged = nil
        } else {
            dragged = PanelLayout.clamp(width, to: PanelLayout.minimum...PanelLayout.ceiling)
        }
    }

    /// Reset Window Layout: back to the natural width.
    public mutating func reset() {
        dragged = nil
    }

    /// The width to draw: the dragged width, else the fixed natural width,
    /// else (before any layout) `estimate`.
    public func shown(estimate: Double) -> Double {
        PanelLayout.clamp(dragged ?? natural ?? estimate, to: range(estimate: estimate))
    }

    /// The divider's range: the minimum to the fixed natural width (or a
    /// wider dragged width), `estimate` before any layout.
    public func range(estimate: Double) -> ClosedRange<Double> {
        let upper = max(natural ?? estimate, dragged ?? 0)
        return PanelLayout.minimum...min(PanelLayout.ceiling, max(PanelLayout.minimum, upper))
    }

    /// What to save: the dragged width, or nothing while at the natural width.
    public var saved: Double? { dragged }

    private mutating func layOut(_ natural: Double) {
        let fixed = min(PanelLayout.ceiling, max(PanelLayout.minimum, natural.isFinite ? natural : PanelLayout.minimum))
        self.natural = fixed
        if let width = dragged, width < fixed - 1 { dragged = nil }
    }
}

/// InspectorWidth sizes the console's inspector, the right-hand pane of the
/// split view with a draggable divider. It opens at `defaultWidth` until the
/// user drags its divider; a dragged width is kept in the user defaults
/// under `key` and read back through `restore`, tolerant of any stored
/// value. The width runs from `minimum` to the widest that keeps the tab
/// column at its own minimum (`range`), never past `ceiling`. After the
/// window opens only a drag (or Reset Window Layout) moves it: a window
/// resize leaves it alone, and the split places it once per change of the
/// stored value (`PaneKeeper`).
public enum InspectorWidth {
    /// The narrowest the inspector goes.
    public static let minimum: Double = 240
    /// The inspector's width until the user drags its divider.
    public static let defaultWidth: Double = 320
    /// The widest the inspector goes, whatever room the window has.
    public static let ceiling: Double = 720
    /// The user-defaults key of the dragged width.
    public static let key = "consoleInspectorWidth"

    /// The inspector's width range when the tab column and the inspector
    /// share `shared` points (the split's width less the panel and its
    /// divider; nil before the first layout) and the column needs
    /// `columnMinimum`: from `minimum` to what the column and the divider
    /// between them leave, never past `ceiling`, and never below `minimum`.
    public static func range(shared: Double?, columnMinimum: Double) -> ClosedRange<Double> {
        guard let shared, shared.isFinite, columnMinimum.isFinite else { return minimum...ceiling }
        let room = shared - columnMinimum - TabStripLayout.dividerWidth
        return minimum...min(ceiling, max(minimum, room))
    }

    /// `width` within `range`; a width that is not finite is the default,
    /// clamped.
    public static func clamp(_ width: Double, to range: ClosedRange<Double> = minimum...ceiling) -> Double {
        guard width.isFinite else { return PanelLayout.clamp(defaultWidth, to: range) }
        return PanelLayout.clamp(width, to: range)
    }

    /// What a drag of the divider to `width` stores: the width within
    /// `minimum...ceiling`.
    public static func dragged(_ width: Double) -> Double {
        clamp(width)
    }

    /// A stored width, clamped to `minimum...ceiling`; the default when
    /// none is stored or the value is not a finite number.
    public static func restore(from stored: Any?) -> Double {
        let value: Double
        if let d = stored as? Double {
            value = d
        } else if let i = stored as? Int {
            value = Double(i)
        } else {
            return defaultWidth
        }
        return clamp(value)
    }
}

/// PaneKeeper is the discipline a resizable pane's size follows once the
/// window is open: the split places the stored size at the first layout,
/// and after that only when the stored size changes (a drag elsewhere, a
/// layout reset). A drag records the size it left, so the model storing
/// that same size does not move the divider again, and a window resize,
/// which changes no stored size, never moves it.
public struct PaneKeeper: Equatable, Sendable {
    /// The size last placed or recorded from a drag.
    public private(set) var placed: Double?

    public init() {}

    /// The size to place now that the model stores `stored`, or nil when
    /// the divider is already there.
    public mutating func place(_ stored: Double) -> Double? {
        guard stored.isFinite, stored != placed else { return nil }
        placed = stored
        return stored
    }

    /// Records a user's drag to `size`.
    public mutating func dragged(to size: Double) {
        placed = size
    }

    /// Forgets the placed size, so the next `place` places again (the pane
    /// was collapsed and shown again).
    public mutating func reset() {
        placed = nil
    }
}

/// LogPaneHeight sizes the log pane along the bottom of the console window,
/// the lower pane of a split view whose top edge the user drags. It opens at
/// about a third of the window's height (`defaultFraction`) until the user
/// drags it; a dragged height is kept in the user defaults under `key` and
/// read back through `restore`, tolerant of any stored value. It runs from
/// `minimum` to what leaves the console above it `aboveMinimum` (`range`).
/// After the pane opens only a drag (or Reset Window Layout) moves it: a
/// window resize leaves it alone (`PaneKeeper`, keyed by `keeperValue`).
public enum LogPaneHeight {
    /// The shortest the pane goes.
    public static let minimum: Double = 120
    /// The share of the window's height the pane opens at until dragged.
    public static let defaultFraction: Double = 1.0 / 3.0
    /// The least the console above the pane keeps: the strip, a tab's
    /// header row and a few rows.
    public static let aboveMinimum: Double = 320
    /// The user-defaults key of the dragged height.
    public static let key = "consoleLogPaneHeight"

    /// The pane's height range in a split `total` points tall: from
    /// `minimum` to what the console above and the divider leave, never
    /// below `minimum`.
    public static func range(total: Double) -> ClosedRange<Double> {
        guard total.isFinite else { return minimum...minimum }
        return minimum...max(minimum, total - aboveMinimum - TabStripLayout.dividerWidth)
    }

    /// The height the pane is placed at in a split `total` points tall: the
    /// stored height, or a third of `total` while none is stored, within `range`.
    public static func shown(stored: Double?, total: Double) -> Double {
        let wanted = stored ?? total * defaultFraction
        return PanelLayout.clamp(wanted.isFinite ? wanted : minimum, to: range(total: total))
    }

    /// What a drag of the pane's top edge to `height` stores: the height,
    /// at least `minimum`; nil for a height that is not a finite number.
    public static func dragged(_ height: Double) -> Double? {
        guard height.isFinite else { return nil }
        return max(minimum, height)
    }

    /// A stored height, at least `minimum`; nil (a third of the window)
    /// when none is stored or the value is not a finite positive number.
    public static func restore(from stored: Any?) -> Double? {
        let value: Double
        if let d = stored as? Double {
            value = d
        } else if let i = stored as? Int {
            value = Double(i)
        } else {
            return nil
        }
        guard value.isFinite, value > 0 else { return nil }
        return max(minimum, value)
    }

    /// The value a `PaneKeeper` tracks for `stored`: the stored height, or 0
    /// while none is stored, so the default third is placed once when the
    /// pane opens and a window resize does not place it again.
    public static func keeperValue(stored: Double?) -> Double {
        stored ?? 0
    }
}
