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
    @Test("the window is placed against the minimum the tabs will need, before the strip shows")
    func placementCountsTheInspectorBeforeTheStripShows() {
        let strip = TabStripLayout.minimumWidth(labels: ConsoleSection.allCases.map(\.title), buttonWidth: nil)
        let closed = TabStripLayout.windowMinimumWidth(strip: strip, inspectorShown: false, panelCollapsed: false)
        let open = TabStripLayout.windowMinimumWidth(strip: strip, inspectorShown: true, panelCollapsed: false)
        for shown in [true, false] {
            let placement = TabStripLayout.windowMinimumWidth(
                strip: strip, inspectorShown: WindowFrame.inspectorCountsAtPlacement(inspectorShown: shown),
                panelCollapsed: false)
            let live = TabStripLayout.windowMinimumWidth(
                strip: strip, inspectorShown: WindowFrame.inspectorDrawn(inspectorShown: shown, stripShown: false),
                panelCollapsed: false)
            #expect(placement == (shown ? open : closed))
            #expect(live == closed)
        }
    }

    @Test("the window grows only when its minimum rises on either axis")
    func windowGrowsOnlyWhenItsMinimumRises() {
        let low = WindowFrame.Size(width: 800, height: 700)
        #expect(WindowFrame.growsOnMinimumChange(from: low, to: WindowFrame.Size(width: 900, height: 700)))
        #expect(WindowFrame.growsOnMinimumChange(from: low, to: WindowFrame.Size(width: 800, height: 750)))
        #expect(!WindowFrame.growsOnMinimumChange(from: low, to: low))
        #expect(!WindowFrame.growsOnMinimumChange(from: low, to: WindowFrame.Size(width: 700, height: 700)))
        #expect(!WindowFrame.growsOnMinimumChange(from: low, to: WindowFrame.Size(width: 800, height: 600)))
    }

    @Test("the window grows when any input of its minimum raises it, and not for an equal or lower one")
    func windowGrowsWhenAnyMinimumInputRises() {
        let base = WindowFrame.ConsoleInputs(inspectorShown: false, stripShown: true, panelCollapsed: false,
                                             windowButtonsEdge: nil, developerBadge: false,
                                             labels: ConsoleSection.allCases.map(\.title))
        var badge = base
        badge.developerBadge = true
        // With the panel collapsed, a buttons edge measured past the fallback
        // widens the strip. Collapsing the panel itself drops the panel's
        // minimum, more than any believed edge adds, so it lowers the minimum.
        var collapsedBefore = base
        collapsedBefore.panelCollapsed = true
        var collapsed = collapsedBefore
        collapsed.windowButtonsEdge = 150
        var open = base
        open.windowButtonsEdge = TabStripLayout.windowButtonsCeiling
        var shut = open
        shut.panelCollapsed = true
        #expect(!WindowFrame.growsOnMinimumChange(from: WindowFrame.minimum(open), to: WindowFrame.minimum(shut)))
        var notDrawn = base
        notDrawn.inspectorShown = true
        notDrawn.stripShown = false
        var drawn = notDrawn
        drawn.stripShown = true
        let changes: [(WindowFrame.ConsoleInputs, WindowFrame.ConsoleInputs)] = [
            (base, badge), (collapsedBefore, collapsed), (base, drawn), (notDrawn, drawn),
            // Opening the collapsed panel brings its minimum back.
            (shut, open),
        ]
        for (before, after) in changes {
            let old = WindowFrame.minimum(before)
            let new = WindowFrame.minimum(after)
            #expect(new.width > old.width)
            #expect(WindowFrame.growsOnMinimumChange(from: old, to: new))
            let frame = WindowFrame.Rect(x: 100, y: 200, width: old.width, height: old.height)
            let grown = WindowFrame.grown(frame, minimum: new, visible: Self.screen)
            #expect(grown.width == new.width)
            #expect(grown.height == new.height)
        }

        // An equal minimum and a lower one (the badge going away) do not grow.
        let same = WindowFrame.minimum(base)
        #expect(!WindowFrame.growsOnMinimumChange(from: same, to: WindowFrame.minimum(base)))
        #expect(!WindowFrame.growsOnMinimumChange(from: WindowFrame.minimum(badge), to: same))

        // A rise in height alone grows the window, downward from its top edge.
        let taller = WindowFrame.Size(width: same.width, height: same.height + 40)
        #expect(WindowFrame.growsOnMinimumChange(from: same, to: taller))
        let frame = WindowFrame.Rect(x: 100, y: 200, width: same.width, height: same.height)
        let grown = WindowFrame.grown(frame, minimum: taller, visible: Self.screen)
        #expect(grown.width == taller.width && grown.height == taller.height)
    }

    @Test("the console's minimum is one function of its inputs, the inspector counted only when drawn or forced")
    func consoleMinimumIsOneFunctionOfItsInputs() {
        let labels = ConsoleSection.allCases.map(\.title)
        let base = WindowFrame.ConsoleInputs(inspectorShown: true, stripShown: true, panelCollapsed: false,
                                             windowButtonsEdge: nil, developerBadge: false, labels: labels)
        let strip = TabStripLayout.minimumWidth(labels: labels, buttonWidth: nil)

        // The same values give TabStripLayout's width, and the height is the floor.
        let drawn = WindowFrame.minimum(base)
        #expect(drawn == WindowFrame.Size(
            width: TabStripLayout.windowMinimumWidth(strip: strip, inspectorShown: true, panelCollapsed: false),
            height: WindowFrame.consoleMinimumHeight))
        #expect(drawn.height == 700)

        // The inspector adds width only while drawn: shown and the strip shown.
        var hidden = base
        hidden.stripShown = false
        let closed = TabStripLayout.windowMinimumWidth(strip: strip, inspectorShown: false, panelCollapsed: false)
        #expect(WindowFrame.minimum(hidden).width == closed)
        #expect(drawn.width > closed)
        var off = base
        off.inspectorShown = false
        #expect(WindowFrame.minimum(off).width == closed)

        // The override forces it either way.
        #expect(WindowFrame.minimum(hidden, inspectorOverride: true) == drawn)
        #expect(WindowFrame.minimum(base, inspectorOverride: false).width == closed)

        // The Developer mode badge adds its width to the strip.
        var badge = base
        badge.developerBadge = true
        let badged = TabStripLayout.minimumWidth(labels: labels, buttonWidth: nil, badgeWidth: TabStripLayout.badgeWidth())
        #expect(WindowFrame.minimum(badge).width
            == TabStripLayout.windowMinimumWidth(strip: badged, inspectorShown: true, panelCollapsed: false))
        #expect(WindowFrame.minimum(badge).width > drawn.width)

        // The collapsed panel with a measured buttons edge gives today's width.
        var collapsed = base
        collapsed.panelCollapsed = true
        collapsed.windowButtonsEdge = 78
        #expect(WindowFrame.minimum(collapsed).width == TabStripLayout.windowMinimumWidth(
            strip: strip, inspectorShown: true, panelCollapsed: true, windowButtonsEdge: 78))

        // The tab column's minimum follows the same inputs.
        #expect(WindowFrame.contentMinimumWidth(collapsed) == TabStripLayout.columnMinimumWidth(
            strip: TabStripLayout.stripMinimumWidth(strip: strip, panelCollapsed: true, windowButtonsEdge: 78)))
    }

    @Test("with the panel hidden the window's minimum rises with the buttons edge up to the ceiling, then takes the fallback")
    func consoleMinimumGrowsWithALargeButtonsEdge() {
        var inputs = WindowFrame.ConsoleInputs(inspectorShown: true, stripShown: true, panelCollapsed: true,
                                               windowButtonsEdge: nil, developerBadge: false,
                                               labels: ConsoleSection.allCases.map(\.title))
        func width(_ edge: Double?) -> Double {
            inputs.windowButtonsEdge = edge
            return WindowFrame.minimum(inputs).width
        }
        // The nine tabs decide the tab column, so each point the buttons
        // take is a point the window's minimum gains, up to the ceiling.
        #expect(TabStripLayout.windowButtonsFallback == 78)
        #expect(TabStripLayout.windowButtonsCeiling == 200)
        let fallback = width(TabStripLayout.windowButtonsFallback)
        let wider = width(120)
        let widest = width(TabStripLayout.windowButtonsCeiling)
        #expect(fallback < wider)
        #expect(wider < widest)
        #expect(wider - fallback == 120 - 78)
        #expect(widest - wider == 200 - 120)
        // Past the ceiling, unmeasured, not positive or not a number: the fallback.
        for edge in [201, nil, 0, .nan] as [Double?] {
            #expect(width(edge) == fallback)
        }
    }

    @Test("a full-screen or zoomed window is not grown, an ordinary one is")
    func growSkipsAFullScreenOrZoomedWindow() {
        #expect(WindowFrame.growRuns(fullScreen: false, zoomed: false))
        #expect(!WindowFrame.growRuns(fullScreen: true, zoomed: false))
        #expect(!WindowFrame.growRuns(fullScreen: false, zoomed: true))
        #expect(!WindowFrame.growRuns(fullScreen: true, zoomed: true))
    }
}
