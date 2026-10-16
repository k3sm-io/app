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
        #expect(PanelLayout.restoreWidth(from: nil) == nil)
        #expect(PanelLayout.restoreWidth(from: "wide") == nil)
        #expect(PanelLayout.restoreWidth(from: 10.0) == PanelLayout.minimum)
        #expect(PanelLayout.restoreWidth(from: 320.0) == 320)
        #expect(PanelLayout.restoreWidth(from: 330) == 330)
        #expect(PanelLayout.restoreWidth(from: 1e9) == PanelLayout.ceiling)
        #expect(PanelLayout.restoreWidth(from: Double.nan) == nil)
        #expect(PanelLayout.restoreWidth(from: Double.infinity) == nil)
        #expect(PanelLayout.restoreCollapsed(from: nil) == false)
        #expect(PanelLayout.restoreCollapsed(from: "yes") == false)
        #expect(PanelLayout.restoreCollapsed(from: true) == true)
    }

    private static let memory = [
        PanelPair("Unified memory", "41.2 GB of 64 GB"),
        PanelPair("pods working set", "12.3 GB", swatch: true),
        PanelPair("rest of this Mac in use", "28.9 GB", swatch: true),
    ]

    @Test("the panel opens at its natural width, keeps a smaller drag, and resets to natural")
    func panelOpensAtNaturalWidth() {
        let cluster = PanelContent(tiles: Self.tiles, nodes: [Self.node("studio", thisMac: true), Self.node("laptop")])
        let mac = PanelContent(tiles: Array(Self.tiles.prefix(3)), pairs: Self.memory)
        let regions = [cluster, mac]
        // The natural width from the constants: the wider region's widest part.
        let natural = PanelLayout.naturalWidth(regions: regions)
        let expected = max(PanelLayout.gridWidth(Self.tiles), PanelLayout.nodeRowWidth(Self.node("studio", thisMac: true)),
                           PanelLayout.gridWidth(Array(Self.tiles.prefix(3))), Self.memory.map(PanelLayout.pairWidth).max()!)
        #expect(natural == min(PanelLayout.ceiling, max(PanelLayout.minimum, expected)))
        #expect(natural > PanelLayout.minimum)
        #expect(PanelLayout.widthRange(regions: regions) == PanelLayout.minimum...natural)
        // Nothing compresses at the natural width: every tile is in one row.
        #expect(PanelLayout.columns(width: natural, tiles: Self.tiles) == Self.tiles.count)
        // A memory heading that does not fit beside its label widens the region.
        let wideMemory = PanelContent(pairs: [PanelPair("Unified memory", "1234.5 GB of 2048.0 GB used now")])
        #expect(PanelLayout.naturalWidth(regions: [wideMemory]) > PanelLayout.naturalWidth(regions: [PanelContent()]))
        // The wider region decides, whichever it is.
        #expect(PanelLayout.naturalWidth(regions: [mac, cluster]) == natural)
        #expect(natural >= PanelLayout.naturalWidth(regions: [mac]))
        #expect(natural >= PanelLayout.naturalWidth(regions: [cluster]))

        // No width saved (or the earlier releases' default): open at natural.
        let fresh = PanelLayout.restoreWidth(from: nil)
        #expect(PanelLayout.shownWidth(stored: fresh, regions: regions) == natural)
        let legacy = PanelLayout.restoreWidth(from: PanelLayout.minimum)
        #expect(PanelLayout.shownWidth(stored: legacy, regions: regions) == natural)

        // A width the user dragged smaller is kept, across a relaunch too.
        let smaller = natural - 60
        let stored = PanelLayout.dragged(smaller, natural: natural)
        #expect(stored == smaller)
        #expect(PanelLayout.shownWidth(stored: PanelLayout.restoreWidth(from: stored), regions: regions) == smaller)
        // A user-sized panel does not follow wider content.
        let wider = [PanelContent(nodes: [Self.node("a-much-longer-build-mac-name-in-the-rack-room")]), mac]
        #expect(PanelLayout.naturalWidth(regions: wider) > natural)
        #expect(PanelLayout.shownWidth(stored: stored, regions: wider) == smaller)

        // A drag back to the natural width, and Reset (nil), return to auto.
        #expect(PanelLayout.dragged(natural, natural: natural) == nil)
        #expect(PanelLayout.dragged(.nan, natural: natural) == nil)
        #expect(PanelLayout.shownWidth(stored: nil, regions: regions) == natural)

        // An auto-sized panel follows its content, both wider and narrower.
        #expect(PanelLayout.shownWidth(stored: nil, regions: wider) == PanelLayout.naturalWidth(regions: wider))
        #expect(PanelLayout.shownWidth(stored: nil, regions: [mac]) == PanelLayout.naturalWidth(regions: [mac]))
        // The ceiling still holds.
        let huge = [PanelContent(pairs: [PanelPair(String(repeating: "x", count: 160), "1 GB")])]
        #expect(PanelLayout.shownWidth(stored: nil, regions: huge) == PanelLayout.ceiling)
    }

    @Test("a live load row needs room for both figures and the sparkline")
    func loadRowWidens() {
        let load = NodeLoad.sampled(cpu: LoadBar(fraction: 0.1, percent: 10, text: "1.43 of 19 cores · 8%"),
                                    memory: LoadBar(fraction: 0.4, percent: 40, text: "24.1 GB of 64 GB · 38%"))
        #expect(PanelLayout.loadWidth(load) > PanelLayout.minimum)
        #expect(PanelLayout.loadWidth(.noSample) == 0)
        #expect(PanelLayout.naturalWidth(regions: [PanelContent(loads: [load])]) == PanelLayout.loadWidth(load))
    }

    @Test("the tile grid uses every column once the tiles fit in one row")
    func columnsFollowWidth() {
        #expect(PanelLayout.columns(width: PanelLayout.minimum, tiles: Self.tiles) == 2)
        let row = PanelLayout.widthRange(content: PanelContent(tiles: Self.tiles)).upperBound
        #expect(PanelLayout.columns(width: row, tiles: Self.tiles) == 4)
        #expect(PanelLayout.columns(width: PanelLayout.ceiling, tiles: Array(Self.tiles.prefix(2))) == 2)
    }
}
