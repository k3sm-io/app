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

/// PanelContent is what the console's navy panel shows that decides how wide
/// it could use: the tiles of the view shown, the Cluster view's node rows
/// and the nodes block's lines. Every string in it is already clipped.
public struct PanelContent: Equatable, Sendable {
    public let tiles: [PanelTile]
    public let nodes: [ClusterNodeRow]
    public let lines: [NodeLine]

    public init(tiles: [PanelTile] = [], nodes: [ClusterNodeRow] = [], lines: [NodeLine] = []) {
        self.tiles = tiles
        self.nodes = nodes
        self.lines = lines
    }
}

/// PanelLayout sizes the console's navy panel, the left pane of a split view
/// with a draggable divider. Its minimum is the panel's fixed width before
/// the split; its maximum is what the content could use: every tile in one
/// row at its natural width, or the longest node row with its name, role,
/// pod count and both meters on one line, whichever is wider, never past
/// `ceiling`. Widths are estimated from character counts at a conservative
/// advance per point of font size, so an estimate errs wide rather than
/// truncating. The stored width and collapsed state are read back through
/// `restoreWidth` and `restoreCollapsed`, both tolerant of any stored value.
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

    /// The panel's width range for `content`: from `minimum` to the width the
    /// content could use, clamped to `ceiling`.
    public static func widthRange(content: PanelContent) -> ClosedRange<Double> {
        let wanted = max(gridWidth(content.tiles), content.nodes.map(nodeRowWidth).max() ?? 0,
                         content.lines.map(lineWidth).max() ?? 0)
        return minimum...min(ceiling, max(minimum, wanted))
    }

    /// `width` within `range`; a width that is not finite is the minimum.
    public static func clamp(_ width: Double, to range: ClosedRange<Double>) -> Double {
        guard width.isFinite else { return range.lowerBound }
        return min(range.upperBound, max(range.lowerBound, width))
    }

    /// A stored width, clamped to `minimum...ceiling`; the minimum when none
    /// is stored or the value is not a number. The content's own range
    /// narrows it again when the panel is drawn.
    public static func restoreWidth(from stored: Any?) -> Double {
        let value: Double
        if let d = stored as? Double {
            value = d
        } else if let i = stored as? Int {
            value = Double(i)
        } else {
            return minimum
        }
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

    private static func text(_ s: String, size: Double) -> Double {
        Double(s.count) * size * advance
    }
}
