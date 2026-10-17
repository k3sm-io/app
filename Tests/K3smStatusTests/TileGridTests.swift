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

/// The This Mac view's 2 by 2 tile grid: what each tile reads, as the
/// panel draws it (the figure, its "of" beside it, the label under them).
@Suite("the This Mac tile grid")
struct TileGridTests {
    private static let gib: Int64 = 1 << 30

    /// A tile as one line of text: "3.20 of 8 cores · cores used".
    private static func text(_ tile: PanelTile) -> String {
        ([tile.value, tile.detail].compactMap { $0 }.joined(separator: " ")) + " · " + tile.label
    }

    @Test("each tile is its used figure of the whole, and none mentions requests")
    func usedOfCapacity() {
        let tiles = ClusterDisplay.macTiles(
            cores: 8, memoryBytes: 16 * Self.gib, dataRootUsed: 40 * Self.gib, dataRootSize: 460 * Self.gib,
            pods: 6, coresUsed: 3.2, memoryUsed: 5 * Self.gib + Self.gib / 10)
        #expect(tiles.count == 4)
        #expect(PanelLayout.tileColumns(count: tiles.count) == 2)
        #expect(tiles.map(Self.text) == [
            "3.20 of 8 cores · cores used",
            "5.1 GB of 16 GB · pod memory used",
            "40 GB of 460 GB · data root",
            "6 · pods on this Mac",
        ])
        for tile in tiles {
            #expect(!Self.text(tile).lowercased().contains("request"), "\(Self.text(tile))")
            #expect(!Help.Panel.tile(tile).text.lowercased().contains("request"), "\(tile.label)")
        }
    }

    @Test("without a sample a use tile has no figure, never zero, and keeps its whole")
    func unsampled() {
        let tiles = ClusterDisplay.macTiles(
            cores: 8, memoryBytes: 16 * Self.gib, dataRootUsed: 40 * Self.gib, dataRootSize: 460 * Self.gib,
            pods: 0, coresUsed: nil, memoryUsed: nil)
        #expect(Self.text(tiles[0]) == "\(ClusterDisplay.noFigure) of 8 cores · cores used")
        #expect(Self.text(tiles[1]) == "\(ClusterDisplay.noFigure) of 16 GB · pod memory used")
        #expect(tiles.allSatisfy { !Self.text($0).lowercased().contains("request") })
    }

    @Test("the natural width follows the tiles' new content")
    func widthFromContent() {
        let tiles = ClusterDisplay.macTiles(
            cores: 8, memoryBytes: 16 * Self.gib, dataRootUsed: 40 * Self.gib, dataRootSize: 460 * Self.gib,
            pods: 6, coresUsed: 3.2, memoryUsed: 5 * Self.gib)
        let grid = PanelLayout.tileGridWidth(tiles.map(PanelLayout.tileWidth))
        #expect(PanelLayout.naturalWidth(regions: [PanelContent(tiles: tiles)]) >= grid)
        #expect(PanelLayout.tileWidth(tiles[0]) == 2 * PanelLayout.tilePadding
            + max(Double("3.20".count) * 20 * PanelLayout.advance + 4 + Double("of 8 cores".count) * 11 * PanelLayout.advance,
                  Double("cores used".count) * 11 * PanelLayout.advance))
    }
}
