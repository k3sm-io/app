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

import AppKit
import CoreGraphics
import K3smStatus
import SwiftUI
import Testing

@testable import K3smApp

/// These put the console's split (`ConsoleSplit`) in a real window, hosted
/// as `ConsoleView` hosts it, and drag its dividers the way a user does: a
/// mouse-down on the divider, then drags and a mouse-up from the event
/// queue, so AppKit runs its own divider tracking. A drag moves only the
/// panes on either side of the divider; the window keeps its frame. The
/// cases that need the window at its full width, wider than some screens
/// (`SplitWindow.screenHolds`), skip on a screen that cannot hold it, with
/// the reason, rather than fail on the cut the screen makes.
@MainActor
@Suite("the console's dividers", .serialized, .enabled(if: SplitWindow.windowServer))
struct ConsoleSplitDragTests {
    @Test("dragging the inspector's divider widens the inspector, not the window",
          .enabled(SplitWindow.needsRoom) { await SplitWindow.screenHolds() })
    func inspectorDividerKeepsTheWindow() throws {
        try SplitWindow.with { harness in
            let before = harness.window.frame
            let inspector = harness.inner.arrangedSubviews[2].frame.width
            let column = harness.inner.arrangedSubviews[1].frame.width
            harness.drag(harness.inner, divider: 1, by: -100)
            #expect(harness.window.frame == before)
            #expect(harness.inner.arrangedSubviews[2].frame.width == inspector + 100)
            #expect(harness.inner.arrangedSubviews[1].frame.width == column - 100)
            #expect(harness.app.inspectorWidth == Double(inspector + 100))
        }
    }

    @Test("dragging the inspector's divider squeezes the panel no further than its minimum, never to the rail",
          .enabled(SplitWindow.needsRoom) { await SplitWindow.screenHolds() })
    func inspectorDividerLeavesThePanelItsMinimum() throws {
        try SplitWindow.with { harness in
            harness.drag(harness.inner, divider: 1, by: -2000)
            #expect(harness.inner.arrangedSubviews[0].frame.width == CGFloat(PanelLayout.minimum))
            #expect(!harness.app.consolePanelCollapsed)
            #expect(abs(harness.inner.arrangedSubviews[1].frame.width - ConsoleView.contentMinWidth()) < 1)
        }
    }

    @Test("the inspector's divider stops where the tab column reaches its minimum")
    func inspectorDividerStopsAtTheColumnMinimum() throws {
        try SplitWindow.with { harness in
            let before = harness.window.frame
            harness.drag(harness.inner, divider: 1, by: -2000)
            #expect(harness.window.frame == before)
            #expect(abs(harness.inner.arrangedSubviews[1].frame.width - ConsoleView.contentMinWidth()) < 1)
            #expect(harness.inner.arrangedSubviews[2].frame.width <= CGFloat(InspectorWidth.ceiling))
        }
    }

    @Test("the inspector's divider stops at the inspector's ceiling in a wide window",
          .enabled(SplitWindow.needsRoom(1000)) { await SplitWindow.screenHolds(extraWidth: 1000) })
    func inspectorDividerStopsAtTheCeiling() throws {
        try SplitWindow.with(extraWidth: 1000) { harness in
            let before = harness.window.frame
            harness.drag(harness.inner, divider: 1, by: -2000)
            #expect(harness.window.frame == before)
            #expect(harness.inner.arrangedSubviews[2].frame.width == CGFloat(InspectorWidth.ceiling))
            #expect(harness.app.inspectorWidth == InspectorWidth.ceiling)
        }
    }

    @Test("the inspector's divider stops at the inspector's minimum")
    func inspectorDividerStopsAtTheInspectorMinimum() throws {
        try SplitWindow.with { harness in
            let before = harness.window.frame
            harness.drag(harness.inner, divider: 1, by: -100)
            let narrower = harness.inner.arrangedSubviews[2].frame.width - CGFloat(InspectorWidth.minimum)
            #expect(narrower >= 100)
            harness.drag(harness.inner, divider: 1, by: narrower + 20)
            #expect(harness.window.frame == before)
            #expect(harness.inner.arrangedSubviews[2].frame.width == CGFloat(InspectorWidth.minimum))
            #expect(harness.app.inspectorShown)
        }
    }

    @Test("dragging the panel's divider narrows the panel, not the window")
    func panelDividerKeepsTheWindow() throws {
        try SplitWindow.with { harness in
            let before = harness.window.frame
            let panel = harness.inner.arrangedSubviews[0].frame.width
            let inspector = harness.inner.arrangedSubviews[2].frame.width
            // The panel opens at its natural width, the top of its range.
            #expect(panel == CGFloat(SplitWindow.panelNatural))
            harness.drag(harness.inner, divider: 0, by: -80)
            #expect(harness.window.frame == before)
            #expect(harness.inner.arrangedSubviews[0].frame.width == panel - 80)
            #expect(harness.inner.arrangedSubviews[2].frame.width == inspector)
            #expect(harness.app.consolePanelWidth.dragged == Double(panel - 80))
        }
    }

    @Test("dragging the panel's divider past its minimum snaps it to the rail, never hides it")
    func panelDividerSnapsToTheRail() throws {
        try SplitWindow.with { harness in
            let before = harness.window.frame
            harness.drag(harness.inner, divider: 0, by: -2000)
            #expect(harness.window.frame == before)
            #expect(!harness.inner.isSubviewCollapsed(harness.inner.arrangedSubviews[0]))
            #expect(harness.inner.arrangedSubviews[0].frame.width == CGFloat(PanelLayout.railWidth))
            #expect(harness.app.consolePanelCollapsed)
        }
    }

    @Test("a drag in from the column rests at the pointer down to the minimum, and at the rail once inside it",
          arguments: [
              (PanelLayout.minimum - 1, PanelLayout.railWidth, true),
              (PanelLayout.openWidth, PanelLayout.railWidth, true),
              (PanelLayout.minimum, PanelLayout.minimum, false),
              (PanelLayout.minimum + 30, PanelLayout.minimum + 30, false),
          ])
    func panelDividerDropDecides(drop: Double, rests: Double, rail: Bool) throws {
        try SplitWindow.with { harness in
            let panel = harness.inner.arrangedSubviews[0].frame.width
            harness.drag(harness.inner, divider: 0, by: CGFloat(drop) - panel)
            #expect(harness.inner.arrangedSubviews[0].frame.width == CGFloat(rests))
            #expect(harness.app.consolePanelCollapsed == rail)
            // A snap to the rail leaves the panel's own width alone; a rest records its width.
            #expect(harness.app.consolePanelWidth.dragged == (rail ? nil : rests))
        }
    }

    @Test("while the divider is dragged it stays at the rail or from the minimum up, the panel turns with it, and the drag places nothing")
    func panelTurnsLiveWhileDragged() throws {
        try SplitWindow.with { harness in
            let panel = harness.inner.arrangedSubviews[0]
            let width = panel.frame.width
            // The model's live turn, as the split reports the drag.
            harness.app.panelDragged(PanelLayout.minimum - 1)
            #expect(harness.app.consolePanelCollapsed)
            harness.app.panelDragged(PanelLayout.minimum)
            #expect(!harness.app.consolePanelCollapsed)
            harness.settle()
            #expect(panel.frame.width == width)
            // Mid-drag, with the pointer inside the minimum, the divider is at the rail, not under the pointer.
            harness.drag(harness.inner, divider: 0, along: [CGFloat(PanelLayout.minimum) - 40 - width], release: false) {
                #expect(panel.frame.width == CGFloat(PanelLayout.railWidth))
                #expect(harness.app.consolePanelCollapsed)
            }
            #expect(panel.frame.width == CGFloat(PanelLayout.railWidth))
            // A drop that leaves the model as it was still places the panel: at the rail, a pull short of opening it.
            harness.drag(harness.inner, divider: 0, by: CGFloat(PanelLayout.openWidth - PanelLayout.railWidth) - 1)
            #expect(panel.frame.width == CGFloat(PanelLayout.railWidth))
            #expect(harness.app.consolePanelCollapsed)
        }
    }

    @Test("one drag turns once: in past the minimum and back out it is the column at the pointer again, out from the rail and back it is the rail again")
    func dragTurnsByWhereItBegan() throws {
        try SplitWindow.with { harness in
            let panel = harness.inner.arrangedSubviews[0]
            let width = panel.frame.width
            let minimum = CGFloat(PanelLayout.minimum)
            let rail = CGFloat(PanelLayout.railWidth)
            // From the column: inside the minimum (the rail), then back out to 30 past it, where it rests.
            harness.drag(harness.inner, divider: 0, along: [minimum - 20 - width, minimum + 30 - width])
            #expect(panel.frame.width == minimum + 30)
            #expect(!harness.app.consolePanelCollapsed)
            #expect(harness.app.consolePanelWidth.dragged == PanelLayout.minimum + 30)
            // From the rail: pulled open (the minimum), back inside the pull (the rail), out past the minimum.
            harness.app.consolePanelCollapsed = true
            harness.settle()
            let pull = CGFloat(PanelLayout.openWidth) - rail
            harness.drag(harness.inner, divider: 0, along: [pull, pull - 10, minimum + 40 - rail])
            #expect(panel.frame.width == minimum + 40)
            #expect(!harness.app.consolePanelCollapsed)
            #expect(harness.app.consolePanelWidth.dragged == PanelLayout.minimum + 40)
            // From the rail, between the pull and the minimum the panel is open at its minimum, not under the pointer.
            harness.app.consolePanelCollapsed = true
            harness.settle()
            harness.drag(harness.inner, divider: 0, along: [pull + 40], release: false) {
                #expect(panel.frame.width == minimum)
                #expect(!harness.app.consolePanelCollapsed)
            }
            #expect(panel.frame.width == minimum)
            #expect(harness.app.consolePanelWidth.dragged == PanelLayout.minimum)
        }
    }

    @Test("a double-click on the panel's divider does not change it")
    func panelDividerDoubleClickKeepsThePanel() throws {
        try SplitWindow.with { harness in
            let split = try #require(harness.inner.delegate as? ConsoleSplitController)
            let panel = harness.inner.arrangedSubviews[0]
            #expect(!split.splitView(harness.inner, shouldCollapseSubview: panel, forDoubleClickOnDividerAt: 0))
            #expect(!split.splitView(harness.inner, canCollapseSubview: panel))
        }
    }

    @Test("View > Hide Panel pins the panel at the rail and Show Panel restores its width")
    func menuPinsAndRestoresThePanel() throws {
        try SplitWindow.with { harness in
            let panel = harness.inner.arrangedSubviews[0]
            let width = panel.frame.width
            harness.app.consolePanelCollapsed = true
            harness.settle()
            #expect(!harness.inner.isSubviewCollapsed(panel))
            #expect(panel.frame.width == CGFloat(PanelLayout.railWidth))
            harness.app.consolePanelCollapsed = false
            harness.settle()
            #expect(!harness.inner.isSubviewCollapsed(panel))
            #expect(panel.frame.width == width)
            // Shown again, the panel still cannot be dragged away, only to the rail.
            harness.drag(harness.inner, divider: 0, by: -2000)
            #expect(!harness.inner.isSubviewCollapsed(panel))
            #expect(panel.frame.width == CGFloat(PanelLayout.railWidth))
            #expect(harness.app.consolePanelCollapsed)
        }
    }

    @Test("at the rail, a pull short of the disc's width falls back to the rail, the disc's width opens the panel at its minimum, and past the minimum it rests where it is dropped")
    func railDividerDragsOut() throws {
        try SplitWindow.with { harness in
            harness.app.consolePanelCollapsed = true
            harness.settle()
            let panel = harness.inner.arrangedSubviews[0]
            let rail = CGFloat(PanelLayout.railWidth)
            #expect(panel.frame.width == rail)
            harness.drag(harness.inner, divider: 0, by: CGFloat(PanelLayout.openWidth) - 1 - rail)
            #expect(panel.frame.width == rail)
            #expect(harness.app.consolePanelCollapsed)
            harness.drag(harness.inner, divider: 0, by: CGFloat(PanelLayout.openWidth) - rail)
            #expect(panel.frame.width == CGFloat(PanelLayout.minimum))
            #expect(!harness.app.consolePanelCollapsed)
            #expect(harness.app.consolePanelWidth.dragged == PanelLayout.minimum)
            harness.app.consolePanelCollapsed = true
            harness.settle()
            harness.drag(harness.inner, divider: 0, by: CGFloat(PanelLayout.minimum) + 50 - rail)
            #expect(panel.frame.width == CGFloat(PanelLayout.minimum) + 50)
            #expect(!harness.app.consolePanelCollapsed)
            #expect(harness.app.consolePanelWidth.dragged == PanelLayout.minimum + 50)
        }
    }

    @Test("a click on the seam disc pins the panel at the rail, and a click turns it back")
    func seamDiscClickTogglesTheRail() throws {
        try SplitWindow.with { harness in
            let seam = try harness.seam()
            let panel = harness.inner.arrangedSubviews[0]
            let width = panel.frame.width
            #expect(!seam.collapsed)
            harness.press(seam, by: 0)
            #expect(harness.app.consolePanelCollapsed)
            #expect(panel.frame.width == CGFloat(PanelLayout.railWidth))
            #expect(seam.collapsed)
            harness.press(seam, by: 0)
            #expect(!harness.app.consolePanelCollapsed)
            #expect(panel.frame.width == width)
            #expect(!seam.collapsed)
            // A press that moves less than the slop is still a click.
            harness.press(seam, by: SeamDiscView.dragSlop - 1)
            #expect(harness.app.consolePanelCollapsed)
        }
    }

    @Test("a press on the seam disc that moves drags the divider as the divider would, snapping to the rail and back out by the same rule")
    func seamDiscDragMovesTheDivider() throws {
        try SplitWindow.with { harness in
            let seam = try harness.seam()
            let panel = harness.inner.arrangedSubviews[0]
            let width = panel.frame.width
            harness.press(seam, by: -80)
            #expect(!harness.app.consolePanelCollapsed)
            #expect(panel.frame.width == width - 80)
            #expect(harness.app.consolePanelWidth.dragged == Double(width - 80))
            // Inside the minimum through the disc: the rail, as the divider itself would be.
            harness.press(seam, by: CGFloat(PanelLayout.minimum) - 1 - (width - 80))
            #expect(harness.app.consolePanelCollapsed)
            #expect(panel.frame.width == CGFloat(PanelLayout.railWidth))
            // Out from the rail a pull short of the disc's width: the rail still.
            harness.press(seam, by: CGFloat(PanelLayout.openWidth - PanelLayout.railWidth) - 1)
            #expect(harness.app.consolePanelCollapsed)
            #expect(panel.frame.width == CGFloat(PanelLayout.railWidth))
            // The disc's width out: the column again, at its minimum.
            harness.press(seam, by: CGFloat(PanelLayout.openWidth - PanelLayout.railWidth))
            #expect(!harness.app.consolePanelCollapsed)
            #expect(panel.frame.width == CGFloat(PanelLayout.minimum))
        }
    }

    @Test("the seam disc sits on the panel's divider at the split's vertical middle, follows it to the rail, and shows only while the seam is hovered")
    func seamDiscSitsOnTheDividerAndShowsOnHover() throws {
        try SplitWindow.with { harness in
            let split = try #require(harness.inner as? DividerSplitView)
            let seam = try harness.seam()
            let divider = harness.inner.arrangedSubviews[0].frame.maxX + harness.inner.dividerThickness / 2
            #expect(seam.alphaValue == 0)
            #expect(seam.frame.width == CGFloat(PanelLayout.seamDisc))
            #expect(abs(seam.frame.midX - divider) < 0.5)
            #expect(abs(seam.frame.midY - harness.inner.bounds.midY) < 0.5)
            // Above both panes, which the controller adds after the disc: drawn whole, not through the divider's gap.
            #expect(harness.inner.subviews.last === seam)
            // On the hairline's reach anywhere along it, on the disc beside it, and nowhere else.
            #expect(split.onSeam(NSPoint(x: divider + CGFloat(PanelLayout.seamReach) - 0.5, y: 10)))
            #expect(!split.onSeam(NSPoint(x: divider + CGFloat(PanelLayout.seamReach) + 1, y: 10)))
            #expect(split.onSeam(NSPoint(x: divider + CGFloat(PanelLayout.seamDisc) / 2 - 1, y: seam.frame.midY)))
            #expect(!split.onSeam(NSPoint(x: divider + CGFloat(PanelLayout.seamDisc) / 2 - 1, y: seam.frame.maxY + 2)))
            split.hover(true)
            #expect(seam.alphaValue == 1)
            #expect(split.seamHovered)
            split.hover(false)
            #expect(seam.alphaValue == 0)
            harness.app.consolePanelCollapsed = true
            harness.settle()
            #expect(abs(seam.frame.midX - (CGFloat(PanelLayout.railWidth) + harness.inner.dividerThickness / 2)) < 0.5)
            #expect(seam.toolTip == Help.Panel.seamShow.text)
            #expect(seam.accessibilityLabel() == "Show Panel")
        }
    }

    @Test("dragging the log pane's top edge raises the pane, not the window")
    func logPaneEdgeKeepsTheWindow() throws {
        try SplitWindow.with(logOpen: true) { harness in
            let before = harness.window.frame
            let logs = harness.outer.arrangedSubviews[1].frame.height
            harness.drag(harness.outer, divider: 0, by: -60)
            #expect(harness.window.frame == before)
            #expect(harness.outer.arrangedSubviews[1].frame.height == logs + 60)
        }
    }

    @Test("the inspector opens at its stored width and keeps it",
          .enabled(SplitWindow.needsRoom) { await SplitWindow.screenHolds() }, arguments: [nil, 400.0])
    func inspectorOpensAtTheStoredWidth(stored: Double?) throws {
        let wanted = stored ?? InspectorWidth.defaultWidth
        try SplitWindow.with(stored: stored.map { [InspectorWidth.key: $0] } ?? [:]) { harness in
            #expect(harness.app.inspectorWidth == wanted)
            #expect(harness.inner.arrangedSubviews[2].frame.width == CGFloat(wanted))
        }
    }

    @Test("the panel opens at its stored width and keeps it")
    func panelOpensAtTheStoredWidth() throws {
        let wanted = PanelLayout.minimum + 60
        try SplitWindow.with(stored: [PanelLayout.widthKey: wanted]) { harness in
            #expect(harness.app.consolePanelWidth.dragged == wanted)
            #expect(harness.inner.arrangedSubviews[0].frame.width == CGFloat(wanted))
        }
    }

    @Test("the log pane opens at its stored height and keeps it")
    func logPaneOpensAtTheStoredHeight() throws {
        let wanted = LogPaneHeight.minimum + 60
        try SplitWindow.with(logOpen: true, stored: [LogPaneHeight.key: wanted]) { harness in
            #expect(harness.app.logPaneHeight == wanted)
            #expect(harness.outer.arrangedSubviews[1].frame.height == CGFloat(wanted))
        }
    }

    @Test("resizing the window gives the change to the tab column",
          .enabled(SplitWindow.needsRoom) { await SplitWindow.screenHolds() })
    func windowResizeGoesToTheColumn() throws {
        try SplitWindow.with { harness in
            let panel = harness.inner.arrangedSubviews[0].frame.width
            let column = harness.inner.arrangedSubviews[1].frame.width
            let inspector = harness.inner.arrangedSubviews[2].frame.width
            var frame = harness.window.frame
            frame.size.width -= 150
            harness.window.setFrame(frame, display: true)
            harness.settle()
            #expect(harness.window.frame == frame)
            #expect(harness.inner.arrangedSubviews[0].frame.width == panel)
            #expect(harness.inner.arrangedSubviews[1].frame.width == column - 150)
            #expect(harness.inner.arrangedSubviews[2].frame.width == inspector)
            #expect(harness.app.inspectorWidth == InspectorWidth.defaultWidth)
            #expect(harness.app.consolePanelWidth.dragged == nil)
        }
    }
}

/// SplitRoot hosts the split as `ConsoleView` does, following the model, so
/// a drag that the model records renders again as it does in the app.
private struct SplitRoot: View {
    @ObservedObject var app: AppModel
    let logOpen: Bool

    var body: some View {
        let size = ConsoleView.minSize(inspectorShown: true, panelCollapsed: false)
        ConsoleSplit(
            app: app,
            range: app.consolePanelWidth.range(estimate: SplitWindow.panelNatural),
            width: app.consolePanelWidth.shown(estimate: SplitWindow.panelNatural),
            collapsed: app.consolePanelCollapsed,
            contentMinimum: Double(ConsoleView.contentMinWidth()),
            inspectorWidth: app.inspectorWidth,
            inspectorShown: true,
            panel: Color.blue.ignoresSafeArea(),
            content: Color.white.ignoresSafeArea(),
            inspector: Color.gray.ignoresSafeArea(),
            logHeight: app.logPaneHeight,
            logOpen: logOpen,
            logPane: Color.black.ignoresSafeArea())
        .frame(minWidth: size.width, minHeight: size.height)
        .ignoresSafeArea()
    }
}

/// SplitWindow is one console split in a transparent window, as the main
/// window controller builds it, with the layout defaults put back after.
@MainActor
struct SplitWindow {
    /// The panel's natural width in these tests.
    static let panelNatural: Double = PanelLayout.minimum + 150

    /// Whether this process can open a window at all: a gate run over SSH
    /// without a login session cannot.
    nonisolated static var windowServer: Bool { CGSessionCopyCurrentDictionary() != nil }

    /// Whether the primary screen holds the window `with(extraWidth:)`
    /// opens, by width: the console's minimum and `extraWidth` more. A
    /// window wider than its screen is cut to the screen, and the cut comes
    /// out of the tab column and the inspector: the inspector cannot open
    /// at its stored width, a drag of its divider stops short of the
    /// expected widths, and a window resize moves panes that should hold.
    /// The console's minimum plus the usual 400 pt is wider than a 14-inch
    /// MacBook Pro's built-in display (1512 pt); the cases that need that
    /// room skip there (`needsRoom`) and run where the screen holds them.
    /// The panel's own cases need no room past the minimum and run anywhere.
    static func screenHolds(extraWidth: CGFloat = 400) -> Bool {
        guard let screen = NSScreen.screens.first else { return false }
        return ConsoleView.minSize(inspectorShown: true, panelCollapsed: false).width + extraWidth <= screen.visibleFrame.width
    }

    /// The reason a case skips when `screenHolds(extraWidth:)` is false.
    nonisolated static var needsRoom: Comment { needsRoom(400) }
    nonisolated static func needsRoom(_ extraWidth: Int) -> Comment {
        "needs a screen that holds the console's minimum width plus \(extraWidth) pt"
    }

    /// The persistent domain the standard defaults write in this process.
    private static var runnerDomain: String {
        Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    }

    /// Marks the mouse events a drag posts, to tell them from any other.
    private static let eventTag = 0x6B33

    let app: AppModel
    let window: NSWindow
    let outer: NSSplitView
    let inner: NSSplitView

    /// Opens the split with `stored` in the user defaults (a layout key to
    /// its value), as a launch after an earlier drag finds them.
    ///
    /// The model reads the layout from the standard defaults, whose
    /// persistent domain every test process of this package shares (one
    /// name, the test runner's), so a gate running beside this one can
    /// change it between a write here and the model's read. The layout is
    /// therefore put in the argument domain, which belongs to this process
    /// alone and is read before the persistent one: every layout key is set,
    /// a key `stored` does not name to an empty string, which every
    /// layout `restore` reads as nothing stored.
    static func with(logOpen: Bool = false, extraWidth: CGFloat = 400, stored: [String: Any] = [:],
                     _ body: (SplitWindow) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        // A drag stores what it left through the model, into the persistent
        // domain; put back what was there, so a run leaves it as it found it.
        let kept = AppPreferences.layoutKeys.map { ($0, defaults.persistentDomain(forName: runnerDomain)?[$0]) }
        defer {
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for (key, value) in kept {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        var layout = arguments
        for key in AppPreferences.layoutKeys { layout[key] = stored[key] ?? "" }
        defaults.setVolatileDomain(layout, forName: UserDefaults.argumentDomain)

        _ = NSApplication.shared
        let app = AppModel(runner: AppleScriptPrivilegedRunner(), environment: [:])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentViewController = NSHostingController(rootView: SplitRoot(app: app, logOpen: logOpen))
        let minimum = ConsoleView.minSize(inspectorShown: true, panelCollapsed: false)
        // Ordering a titled window in fits it to its screen, so a frame set
        // before then shrinks to a laptop's width while a wider display keeps
        // it, and every pane's width would depend on the screen the run uses.
        // So the window is ordered in first and sized after: setFrame keeps
        // the frame as asked, on any screen.
        window.orderFront(nil)
        window.setFrame(NSRect(x: 40, y: 40, width: minimum.width + extraWidth, height: minimum.height + 60), display: true)
        defer { window.orderOut(nil) }
        let harness = try SplitWindow(app: app, window: window)
        harness.settle()
        try body(harness)
    }

    private init(app: AppModel, window: NSWindow) throws {
        self.app = app
        self.window = window
        let splits = Self.splits(in: try #require(window.contentView))
        outer = try #require(splits.first { !$0.isVertical })
        inner = try #require(splits.first { $0.isVertical })
    }

    private static func splits(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits)
    }

    /// Lets AppKit and SwiftUI finish the layout and any update a drag caused.
    func settle() {
        for _ in 0..<5 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        window.layoutIfNeeded()
    }

    /// Drags `split`'s divider `divider` by `delta` points along the split's
    /// axis (rightward or downward is positive), as a user's mouse does. The
    /// pointer stays on the split: a delta past its edge stops there, as a
    /// user's pointer stops at the screen's edge, and the edge is already past
    /// every divider's limit.
    ///
    /// The drag's events go through the app's event queue, which AppKit's
    /// divider tracking reads and nothing else in a test does (the runner
    /// never runs `NSApp`). So the queue is emptied before the drag, and
    /// after it the drag must have used every event it posted: an event left
    /// behind, ours or one the window server delivered, would otherwise be
    /// read by the next drag in the run as its own and move a divider there.
    func drag(_ split: NSSplitView, divider: Int, by delta: CGFloat,
              sourceLocation: SourceLocation = #_sourceLocation) {
        drag(split, divider: divider, along: (1...10).map { delta * CGFloat($0) / 10 }, sourceLocation: sourceLocation)
    }

    /// Drags `split`'s divider through `offsets`, each from where the drag
    /// began along the split's axis, one mouse event per offset, and lets
    /// go at the last. With `release` false the button stays down after
    /// the last offset: `held` runs then, mid-drag, and the release follows
    /// it. The pointer stays on the split as in `drag(_:divider:by:)`.
    func drag(_ split: NSSplitView, divider: Int, along offsets: [CGFloat], release: Bool = true,
              sourceLocation: SourceLocation = #_sourceLocation, held: @escaping @MainActor () -> Void = {}) {
        let before = split.arrangedSubviews[divider].frame
        let half = split.dividerThickness / 2
        let start = split.isVertical
            ? NSPoint(x: before.maxX + half, y: split.bounds.midY)
            : NSPoint(x: split.bounds.midX, y: before.maxY + half)
        let along = split.isVertical ? start.x : start.y
        let length = split.isVertical ? split.bounds.width : split.bounds.height
        let reaches = offsets.map { min(max(along + $0, 0), length) - along }
        let last = reaches.last ?? 0
        func event(_ type: NSEvent.EventType, _ offset: CGFloat) -> NSEvent {
            let point = split.isVertical ? NSPoint(x: start.x + offset, y: start.y) : NSPoint(x: start.x, y: start.y + offset)
            return NSEvent.mouseEvent(with: type, location: split.convert(point, to: nil), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: Self.eventTag, clickCount: 1, pressure: 1)!
        }
        Self.takeEvents()
        // Posting an event stops the innermost running run loop, to wake a
        // reader. Run directly, that is the test runner's own loop, which
        // then returns and ends the process; so the posts and the drag run
        // in a nested pass of the loop, and the post stops that one. AppKit
        // tracks the divider inside `mouseDown` until it reads a mouse-up,
        // so a held drag posts its release from a timer that fires once the
        // tracking has read every drag event, with `held` run before it.
        var dragged = false
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            for reach in reaches {
                NSApp.postEvent(event(.leftMouseDragged, reach), atStart: false)
            }
            if release {
                NSApp.postEvent(event(.leftMouseUp, last), atStart: false)
            } else {
                // The event is posted from the main thread, where it was made.
                nonisolated(unsafe) let up = event(.leftMouseUp, last)
                let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        held()
                        NSApp.postEvent(up, atStart: false)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
            split.mouseDown(with: event(.leftMouseDown, 0))
            dragged = true
        }
        while !dragged { _ = CFRunLoopRunInMode(.defaultMode, 1, false) }
        let left = Self.takeEvents().filter { $0.type == .leftMouseDragged || $0.type == .leftMouseUp }
        let ours = left.filter { $0.eventNumber == Self.eventTag }.count
        #expect(left.isEmpty, "the divider's tracking ended before the drag's own mouse-up: \(ours) of its events and \(left.count - ours) others were left in the queue",
                sourceLocation: sourceLocation)
        settle()
    }

    /// The seam disc on the console split's first divider.
    func seam(sourceLocation: SourceLocation = #_sourceLocation) throws -> SeamDiscView {
        try #require((inner as? DividerSplitView)?.seam, sourceLocation: sourceLocation)
    }

    /// Presses the seam disc at its centre and releases it `delta` points
    /// to the right (left when negative), as a user's mouse does: a press
    /// that moves less than the disc's slop is a click. The events go
    /// through the app's queue, as `drag`'s do, and must all be used.
    func press(_ seam: SeamDiscView, by delta: CGFloat, sourceLocation: SourceLocation = #_sourceLocation) {
        let start = seam.convert(NSPoint(x: seam.bounds.midX, y: seam.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ offset: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + offset, y: start.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: Self.eventTag, clickCount: 1, pressure: 1)!
        }
        Self.takeEvents()
        var pressed = false
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            if delta != 0 {
                for step in 1...10 {
                    NSApp.postEvent(event(.leftMouseDragged, delta * CGFloat(step) / 10), atStart: false)
                }
            }
            NSApp.postEvent(event(.leftMouseUp, delta), atStart: false)
            seam.mouseDown(with: event(.leftMouseDown, 0))
            pressed = true
        }
        while !pressed { _ = CFRunLoopRunInMode(.defaultMode, 1, false) }
        let left = Self.takeEvents().filter { $0.type == .leftMouseDragged || $0.type == .leftMouseUp }
        #expect(left.isEmpty, "the disc's press ended before its own mouse-up: \(left.count) events were left in the queue",
                sourceLocation: sourceLocation)
        settle()
    }

    /// Takes every event waiting in the app's queue and returns them.
    @discardableResult
    private static func takeEvents() -> [NSEvent] {
        var taken: [NSEvent] = []
        while let next = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
            taken.append(next)
        }
        return taken
    }
}
