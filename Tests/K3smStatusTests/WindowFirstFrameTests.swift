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

@Suite("the console window's first frame when nothing is saved")
struct WindowFirstFrameTests {
    typealias Rect = WindowFrame.Rect
    typealias Size = WindowFrame.Size

    private static let screen = Rect(x: 0, y: 0, width: 1728, height: 1080)
    private static let minimum = Size(width: 1180, height: 700)

    @Test("the first launch opens at exactly the minimum, centred on the visible frame")
    func firstLaunchOpensAtItsMinimumCentred() {
        let got = WindowFrame.firstFrame(minimum: Self.minimum, visible: Self.screen)
        #expect(got == Rect(x: 274, y: 190, width: 1180, height: 700))
        #expect(got.x - Self.screen.x == Self.screen.maxX - got.maxX)
        #expect(got.y - Self.screen.y == Self.screen.maxY - got.maxY)
    }

    @Test("a minimum larger than the visible frame on one axis is pinned on that axis and centred on the other")
    func minimumLargerOnOneAxisOnly() {
        // Wider than the screen: pinned to the left edge, centred vertically.
        let narrow = Rect(x: 0, y: 0, width: 1024, height: 900)
        #expect(WindowFrame.firstFrame(minimum: Self.minimum, visible: narrow)
            == Rect(x: 0, y: 100, width: 1180, height: 700))

        // Taller than the screen: pinned to the top edge, centred horizontally.
        let short = Rect(x: 0, y: 0, width: 1440, height: 640)
        #expect(WindowFrame.firstFrame(minimum: Self.minimum, visible: short)
            == Rect(x: 130, y: -60, width: 1180, height: 700))
    }

    @Test("an offset visible frame centres on its own origin")
    func offsetVisibleFrame() {
        // A second screen to the left and above, with a menu bar and Dock taken out.
        let side = Rect(x: -1920, y: 1080, width: 1920, height: 1050)
        #expect(WindowFrame.firstFrame(minimum: Self.minimum, visible: side)
            == Rect(x: -1550, y: 1255, width: 1180, height: 700))

        // Larger than an offset screen on both axes: pinned to its left and top edges.
        let tiny = Rect(x: 200, y: 50, width: 1000, height: 600)
        #expect(WindowFrame.firstFrame(minimum: Self.minimum, visible: tiny)
            == Rect(x: 200, y: -50, width: 1180, height: 700))
    }

    @Test("the first frame is already at the minimum, so growing it to the same minimum leaves it alone",
          arguments: [
              Rect(x: 0, y: 0, width: 1728, height: 1080),
              Rect(x: -1920, y: 1080, width: 1920, height: 1050),
              Rect(x: 0, y: 0, width: 1024, height: 900),
              Rect(x: 200, y: 50, width: 1000, height: 600),
          ])
    func grownFirstFrameIsUnchanged(_ visible: Rect) {
        let first = WindowFrame.firstFrame(minimum: Self.minimum, visible: visible)
        #expect(WindowFrame.grown(first, minimum: Self.minimum, visible: visible) == first)
    }
}
