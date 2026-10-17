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
/// its legend), and the live load rows. Every string in it is already clipped.
public struct PanelContent: Equatable, Sendable {
    public let tiles: [PanelTile]
    public let nodes: [ClusterNodeRow]
    public let lines: [NodeLine]
    public let pairs: [PanelPair]
    public let loads: [NodeLoad]

    public init(tiles: [PanelTile] = [], nodes: [ClusterNodeRow] = [], lines: [NodeLine] = [],
                pairs: [PanelPair] = [], loads: [NodeLoad] = []) {
        self.tiles = tiles
        self.nodes = nodes
        self.lines = lines
        self.pairs = pairs
        self.loads = loads
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
/// width at which nothing in either region compresses or clips: every tile
/// in one row at its natural width, the longest node row with its name,
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
/// The panel is auto-sized until the user drags its divider: an auto-sized
/// panel is drawn at the natural width and follows it as the content
/// changes; a dragged width is kept (narrower than natural, the tiles take
/// two columns and rows wrap) for the session only: a width narrower than
/// the natural width is never saved, and a saved one that has become narrower
/// than the content (`replacesWidth`) is cleared, so the panel opens
/// auto-sized. A drag back to the natural width, or Reset Window Layout,
/// returns it to auto. The stored width (none while auto) and
/// collapsed state are read back through `restoreWidth` and
/// `restoreCollapsed`, both tolerant of any stored value.
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
    /// The live load row's sparkline width, and the gap before it.
    public static let sparklineWidth: Double = 40

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

    /// The width the panel is drawn at: the natural width while auto-sized
    /// (`stored` is nil), the user's width within the range otherwise.
    public static func shownWidth(stored: Double?, regions: [PanelContent], measured: Double? = nil) -> Double {
        let range = widthRange(regions: regions, measured: measured)
        guard let stored else { return range.upperBound }
        return clamp(stored, to: range)
    }

    /// What a drag of the divider to `width` stores: the width, or nil (auto)
    /// once it reaches the natural width, so the panel follows its content again.
    /// `natural` is the range's upper bound the split view was given.
    public static func dragged(_ width: Double, natural: Double) -> Double? {
        guard width.isFinite else { return nil }
        return width >= natural - 1 ? nil : width
    }

    /// Whether a width kept for the panel (`width`) must be thrown away now the
    /// natural width is `natural`: it is narrower than the content needs.
    /// A saved width (read from the user defaults, `session` false) is
    /// replaced whenever it is narrower; a width dragged in this session
    /// (`session` true) is kept until the natural width grows past it
    /// (`previousNatural` is the natural width it was last judged against).
    public static func replacesWidth(_ width: Double, natural: Double, previousNatural: Double? = nil,
                                     session: Bool = false) -> Bool {
        guard width.isFinite else { return true }
        guard width < natural - 1 else { return false }
        guard session else { return true }
        return previousNatural.map { natural > $0 + 1 } ?? false
    }

    /// What to save of a panel `width`: the width when it is at or above
    /// `natural`, nil (nothing saved) when it is narrower, which lasts the session only.
    public static func persisted(_ width: Double?, natural: Double) -> Double? {
        guard let width, width.isFinite, width >= natural - 1 else { return nil }
        return width
    }

    /// One region's widest part.
    static func wantedWidth(_ content: PanelContent) -> Double {
        [gridWidth(content.tiles), content.nodes.map(nodeRowWidth).max() ?? 0,
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

    /// The width of tiles in one row, each as wide as the widest of
    /// `tileWidths` (every tile's whole width, its inner padding on both
    /// sides included), `tileSpacing` apart. The panel's tile row lays its
    /// tiles out by it, so a measured row and an estimated one agree.
    public static func tileRowWidth(_ tileWidths: [Double]) -> Double {
        guard let widest = tileWidths.max() else { return 0 }
        let count = Double(tileWidths.count)
        return count * widest + (count - 1) * tileSpacing
    }

    /// Whether tiles `tileWidths` wide fit in one row of a panel `width`
    /// wide, inside its two edges; when they do not, the tiles take two columns.
    public static func tileRowFits(width: Double, tileWidths: [Double]) -> Bool {
        tileWidths.count > 2 && tileRowWidth(tileWidths) <= width - padding
    }

    /// The gaps from the panel's two edges to a tile row `rowWidth` wide in a
    /// panel `width` wide: the leading edge always, and on the trailing side
    /// what the row leaves of the width. A row that fits stretches across the
    /// content, so both are `edge`; a row wider than the content runs into the
    /// trailing edge, which is what the natural width must never allow.
    public static func tileMargins(width: Double, rowWidth: Double) -> (leading: Double, trailing: Double) {
        (edge, width - edge - max(rowWidth, width - padding))
    }

    /// One tile's estimated natural width: its inner padding on both sides
    /// and the wider of the value with its "of" (and what is used) beside
    /// it, and the label.
    static func tileWidth(_ tile: PanelTile) -> Double {
        let figure = text(tile.value, size: 20) + (tile.detailLine.map { 4 + text($0, size: 11) } ?? 0)
        return 2 * tilePadding + max(figure, text(tile.label, size: 11))
    }

    /// Every tile in one row (`tileRowWidth`), with the panel's padding.
    static func gridWidth(_ tiles: [PanelTile]) -> Double {
        guard !tiles.isEmpty else { return 0 }
        return padding + tileRowWidth(tiles.map(tileWidth))
    }

    /// A Cluster view node row on one line: the dot, the name, the "this Mac"
    /// tag, the role, the pod count, then both meters.
    static func nodeRowWidth(_ node: ClusterNodeRow) -> Double {
        var width = 7 + 6 + text(node.name, size: 12) + 6 + text(node.role, size: 11)
        if node.thisMac { width += 6 + text("this Mac", size: 9) + 10 }
        if let running = node.running { width += 4 + text("\(running) pods", size: 11) }
        let meters = [node.cores, node.memory].map { usage in
            max(meterWidth, text(usage?.text ?? "", size: 10))
        }
        return padding + width + tileSpacing + meters.reduce(0, +) + tileSpacing
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

    /// A live load row: the CPU and memory bars, each as wide as the wider
    /// figure under it, then the sparkline.
    static func loadWidth(_ load: NodeLoad) -> Double {
        guard case .sampled(let cpu, let memory) = load else { return 0 }
        let bar = max(text("CPU " + cpu.text, size: 10), text("Memory " + memory.text, size: 10))
        return padding + 2 * bar + tileSpacing + tileSpacing + sparklineWidth
    }

    private static func text(_ s: String, size: Double) -> Double {
        Double(s.count) * size * advance
    }
}
