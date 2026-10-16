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
/// is widest across both regions, never past `ceiling`. Widths are estimated
/// from character counts at a conservative advance per point of font size,
/// so an estimate errs wide rather than truncating.
///
/// The panel is auto-sized until the user drags its divider: an auto-sized
/// panel is drawn at the natural width and follows it as the content
/// changes; a dragged width is kept (narrower than natural, the tiles take
/// two columns and rows wrap). A drag back to the natural width, or Reset
/// Window Layout, returns it to auto. The stored width (none while auto) and
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

    /// The panel's horizontal padding, both sides together.
    public static let padding: Double = 40
    /// The gap between tiles, and between a node row's parts.
    public static let tileSpacing: Double = 10
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

    /// The width `regions` need with nothing compressed or clipped: the
    /// widest of every region's content, at least `minimum`, never past
    /// `ceiling`.
    public static func naturalWidth(regions: [PanelContent]) -> Double {
        let wanted = regions.map(wantedWidth).max() ?? 0
        return min(ceiling, max(minimum, wanted))
    }

    /// The panel's width range for `regions`: from `minimum` to the natural width.
    public static func widthRange(regions: [PanelContent]) -> ClosedRange<Double> {
        minimum...naturalWidth(regions: regions)
    }

    /// The panel's width range for one region's `content`.
    public static func widthRange(content: PanelContent) -> ClosedRange<Double> {
        widthRange(regions: [content])
    }

    /// The width the panel is drawn at: the natural width while auto-sized
    /// (`stored` is nil), the user's width within the range otherwise.
    public static func shownWidth(stored: Double?, regions: [PanelContent]) -> Double {
        let range = widthRange(regions: regions)
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

    /// How many tile columns a panel `width` wide shows: every tile in one
    /// row once they all fit at their natural width, two otherwise.
    public static func columns(width: Double, tiles: [PanelTile]) -> Int {
        guard tiles.count > 2, width >= gridWidth(tiles) else { return 2 }
        return tiles.count
    }

    /// One tile's natural width: its padding and the wider of the value with
    /// its "of" (and what is used) beside it, and the label.
    static func tileWidth(_ tile: PanelTile) -> Double {
        let figure = text(tile.value, size: 20) + (tile.detailLine.map { 4 + text($0, size: 11) } ?? 0)
        return 20 + max(figure, text(tile.label, size: 11))
    }

    /// Every tile in one row, each as wide as the widest, with the padding.
    static func gridWidth(_ tiles: [PanelTile]) -> Double {
        guard let widest = tiles.map(tileWidth).max() else { return 0 }
        let count = Double(tiles.count)
        return padding + count * widest + (count - 1) * tileSpacing
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
