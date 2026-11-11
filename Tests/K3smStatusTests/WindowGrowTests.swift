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

@Suite("an open window grows to a raised minimum")
struct WindowGrowTests {
    private static let screen = WindowFrame.Rect(x: 0, y: 0, width: 1728, height: 1080)

    @Test("opening the inspector grows a narrower window to exactly its minimum and leaves a wider one alone")
    func inspectorOpeningGrowsANarrowWindowToItsMinimum() {
        let strip = TabStripLayout.minimumWidth(labels: ConsoleSection.allCases.map(\.title), buttonWidth: nil)
        let closed = TabStripLayout.windowMinimumWidth(strip: strip, inspectorShown: false, panelCollapsed: false)
        let open = TabStripLayout.windowMinimumWidth(strip: strip, inspectorShown: true, panelCollapsed: false)
        #expect(open >= closed + InspectorWidth.minimum)
        let minimum = WindowFrame.Size(width: open, height: 700)

        // A window at the closed minimum grows to exactly the open one, its left and top edges kept.
        let narrow = WindowFrame.Rect(x: 100, y: 200, width: closed, height: 800)
        let grown = WindowFrame.grown(narrow, minimum: minimum, visible: Self.screen)
        #expect(grown == WindowFrame.Rect(x: 100, y: 200, width: open, height: 800))

        // A window already wider than the minimum is unchanged, wherever it sits.
        let wide = WindowFrame.Rect(x: 3000, y: -40, width: open + 50, height: 800)
        #expect(WindowFrame.grown(wide, minimum: minimum, visible: Self.screen) == wide)
        #expect(WindowFrame.grown(narrow, minimum: WindowFrame.Size(width: closed, height: 700), visible: Self.screen) == narrow)

        // Growing at the screen's right edge moves the frame back on.
        let atEdge = WindowFrame.Rect(x: Self.screen.maxX - closed, y: 200, width: closed, height: 800)
        let moved = WindowFrame.grown(atEdge, minimum: minimum, visible: Self.screen)
        #expect(moved.width == open)
        #expect(moved.maxX == Self.screen.maxX)
        #expect(moved.y == 200)

        // A shorter window grows downward from its top edge; with no screen nothing moves it on.
        let short = WindowFrame.Rect(x: 0, y: 500, width: open, height: 600)
        let taller = WindowFrame.grown(short, minimum: minimum, visible: nil)
        #expect(taller == WindowFrame.Rect(x: 0, y: 400, width: open, height: 700))

        // A minimum wider than the screen pins the frame to the screen's left edge.
        let huge = WindowFrame.grown(narrow, minimum: WindowFrame.Size(width: Self.screen.width + 100, height: 700),
                                     visible: Self.screen)
        #expect(huge.x == Self.screen.x)
        #expect(huge.width == Self.screen.width + 100)
    }

    @Test("the inspector is drawn, and widens the window's minimum, only while the strip is shown")
    func inspectorGrowNeedsTheStripShown() {
        #expect(WindowFrame.inspectorDrawn(inspectorShown: true, stripShown: true))
        #expect(!WindowFrame.inspectorDrawn(inspectorShown: true, stripShown: false))
        #expect(!WindowFrame.inspectorDrawn(inspectorShown: false, stripShown: true))
        #expect(!WindowFrame.inspectorDrawn(inspectorShown: false, stripShown: false))

        let strip = TabStripLayout.minimumWidth(labels: ConsoleSection.allCases.map(\.title), buttonWidth: nil)
        let closed = TabStripLayout.windowMinimumWidth(strip: strip, inspectorShown: false, panelCollapsed: false)
        for (shown, stripShown) in [(true, true), (true, false), (false, true), (false, false)] {
            let drawn = WindowFrame.inspectorDrawn(inspectorShown: shown, stripShown: stripShown)
            let minimum = TabStripLayout.windowMinimumWidth(strip: strip, inspectorShown: drawn, panelCollapsed: false)
            if shown && stripShown {
                #expect(minimum >= closed + InspectorWidth.minimum)
            } else {
                #expect(minimum == closed)
            }
        }
    }
}
