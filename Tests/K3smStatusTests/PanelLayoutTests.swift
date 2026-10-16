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

import Testing

@testable import K3smStatus

@Suite("the console panel's width")
struct PanelLayoutTests {
    private static func node(_ name: String, thisMac: Bool = false) -> ClusterNodeRow {
        ClusterNodeRow(
            name: name, role: "server", ready: "Ready", isReady: true, version: nil, thisMac: thisMac,
            cores: ClusterUsage(requested: 3.5, allocatable: 19, text: "3.5 of 19"),
            memory: ClusterUsage(requested: 3.2e9, allocatable: 60e9, text: "3.2 GB of 60 GB"), running: 6)
    }

    private static let tiles = [
        PanelTile(label: "Macs", value: "2"),
        PanelTile(label: "pods running", value: "6"),
        PanelTile(label: "cores requested", value: "3.5", detail: "of 19"),
        PanelTile(label: "memory requested", value: "3.2 GB", detail: "of 60 GB"),
    ]

    @Test("a width is clamped to the content's range: up to the minimum, down to the content maximum")
    func panelWidthClampsToContentRange() {
        let range = PanelLayout.widthRange(content: PanelContent(tiles: Self.tiles, nodes: [Self.node("studio", thisMac: true)]))
        #expect(range.lowerBound == PanelLayout.minimum)
        #expect(range.upperBound > PanelLayout.minimum)
        #expect(range.upperBound <= PanelLayout.ceiling)
        #expect(PanelLayout.clamp(100, to: range) == PanelLayout.minimum)
        #expect(PanelLayout.clamp(0, to: range) == PanelLayout.minimum)
        #expect(PanelLayout.clamp(-50, to: range) == PanelLayout.minimum)
        #expect(PanelLayout.clamp(range.upperBound + 300, to: range) == range.upperBound)
        #expect(PanelLayout.clamp(.infinity, to: range) == PanelLayout.minimum)
        #expect(PanelLayout.clamp(.nan, to: range) == PanelLayout.minimum)
        let inside = (range.lowerBound + range.upperBound) / 2
        #expect(PanelLayout.clamp(inside, to: range) == inside)
    }

    @Test("wider content widens the maximum, up to the ceiling")
    func widerContentWidensMaximum() {
        let short = PanelLayout.widthRange(content: PanelContent(nodes: [Self.node("a")]))
        let long = PanelLayout.widthRange(content: PanelContent(nodes: [Self.node("a"), Self.node("build-mac-studio-2")]))
        #expect(long.upperBound > short.upperBound)
        let twoTiles = PanelLayout.widthRange(content: PanelContent(tiles: Array(Self.tiles.prefix(2))))
        let fourTiles = PanelLayout.widthRange(content: PanelContent(tiles: Self.tiles))
        #expect(fourTiles.upperBound > twoTiles.upperBound)
        let line = PanelLayout.widthRange(content: PanelContent(lines: [NodeLine(name: "a-much-longer-node-name", role: "agent", version: "0.1.7")]))
        #expect(line.upperBound > PanelLayout.minimum)
        let huge = PanelLayout.widthRange(content: PanelContent(nodes: [Self.node(String(repeating: "x", count: 160))]))
        #expect(huge.upperBound == PanelLayout.ceiling)
    }

    @Test("with no content the range is the minimum alone")
    func emptyContentIsMinimum() {
        let range = PanelLayout.widthRange(content: PanelContent())
        #expect(range == PanelLayout.minimum...PanelLayout.minimum)
        #expect(PanelLayout.clamp(500, to: range) == PanelLayout.minimum)
    }

    @Test("a stored width and collapsed flag read back clamped and tolerant")
    func restoreIsClampedAndTolerant() {
        #expect(PanelLayout.restoreWidth(from: nil) == PanelLayout.minimum)
        #expect(PanelLayout.restoreWidth(from: "wide") == PanelLayout.minimum)
        #expect(PanelLayout.restoreWidth(from: 10.0) == PanelLayout.minimum)
        #expect(PanelLayout.restoreWidth(from: 320.0) == 320)
        #expect(PanelLayout.restoreWidth(from: 330) == 330)
        #expect(PanelLayout.restoreWidth(from: 1e9) == PanelLayout.ceiling)
        #expect(PanelLayout.restoreWidth(from: Double.nan) == PanelLayout.minimum)
        #expect(PanelLayout.restoreCollapsed(from: nil) == false)
        #expect(PanelLayout.restoreCollapsed(from: "yes") == false)
        #expect(PanelLayout.restoreCollapsed(from: true) == true)
    }

    @Test("the tile grid uses every column once the tiles fit in one row")
    func columnsFollowWidth() {
        #expect(PanelLayout.columns(width: PanelLayout.minimum, tiles: Self.tiles) == 2)
        let row = PanelLayout.widthRange(content: PanelContent(tiles: Self.tiles)).upperBound
        #expect(PanelLayout.columns(width: row, tiles: Self.tiles) == 4)
        #expect(PanelLayout.columns(width: PanelLayout.ceiling, tiles: Array(Self.tiles.prefix(2))) == 2)
    }
}
